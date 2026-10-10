// ONE websocket to Home Assistant, ONE in-memory copy of the states the API keys may read.
//
//   Home Assistant ==(one websocket, subscribe_entities, changes only)==> cache in this process
//   cache in this process ==(in-memory read)==> every API key / every request
//
// Idle traffic to Home Assistant is keepalive pings only; Home Assistant pushes a message only when
// a subscribed entity changes. API requests never reach Home Assistant, so ten keys cost the same as
// one. The design follows a pipeline that has run a 24/7 wall display over flaky WiFi for months, and
// the odd-looking parts each fix a real failure:
//
//   * deadman: three silent 20 s windows in a row drop the socket (half-open links never send a RST)
//   * any inbound frame (event, result, pong) resets the silence counter
//   * copy-on-write: a delta builds a NEW object, readers holding the old one never see a half-applied delta
//   * removed entities are marked "unavailable", never deleted
//   * a bad frame is skipped, it never drops the socket
//   * the supervisor re-reads the token every cycle, backs off 5 s -> 60 s and resets the backoff when
//     the last connection lived for more than a minute
//   * the entity set can't be amended on a live subscription: any change => resubscribe (new socket)
//
// Home Assistant's compressed event format (subscribe_entities):
//   a = added   { id: { s: state, a: attributes, lc: last_changed, lu: last_updated } }  (first event = everything)
//   c = changed { id: { "+": { s?, a?, lc?, lu? }, "-": { a: [removed attribute names] } } }
//   r = removed [ids]

export type HaState = {
  entity_id: string;
  state: string | null;
  attributes: Record<string, unknown>;
  last_changed: string | null;
  last_updated: string | null;
};

export const RECV_TIMEOUT: unique symbol = Symbol("recv-timeout");

// The little bit of a websocket this module needs. The real one is in haHubConnection.ts; tests
// provide scripted fakes.
export interface HubConnection {
  // The next text frame, or RECV_TIMEOUT after `timeoutMs` of silence. Rejects when the link is closed.
  recv(timeoutMs: number): Promise<string | typeof RECV_TIMEOUT>;
  // Throws when the link is broken.
  send(data: string): void;
  close(): void;
}

export type HubLogger = {
  info(message: string): void;
  warn(message: string): void;
};

export type HubOptions = {
  baseUrl: string;
  // "/api/websocket" for Home Assistant itself, "/websocket" through the add-on Supervisor proxy.
  websocketPath?: string;
  getToken: () => string | null;
  // Exact entity ids to subscribe to (deduped, order preserved). Called on every (re)connect.
  collectEntityIds: () => Promise<string[]> | string[];
  connect: (url: string) => Promise<HubConnection>;
  log?: HubLogger;
  now?: () => number;
  idleMs?: number;
  maxMissed?: number;
  maxEntities?: number;
  backoffInitialMs?: number;
  backoffMaxMs?: number;
  noTokenWaitMs?: number;
  emptyRecheckMs?: number;
};

export type HubStatus = {
  running: boolean;
  connected: boolean;
  subscribed: number;
  cached: number;
  newestChangeAgeSeconds: number | null;
  lastEventAt: string | null;
  connectedSince: string | null;
  reconnects: number;
  lastError: string | null;
};

export type HubRead = { body: string; stale: boolean };

const ENTITY_ID = /^[a-z0-9_]+\.[a-z0-9_]+$/;

export function isValidEntityId(value: string): boolean {
  return ENTITY_ID.test(value);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function tsIso(value: unknown): string | null {
  if (typeof value !== "number" && typeof value !== "string") {
    return null;
  }
  const seconds = Number(value);
  if (!Number.isFinite(seconds)) {
    return null;
  }
  const date = new Date(seconds * 1000);
  return Number.isNaN(date.getTime()) ? null : date.toISOString();
}

function sameList(a: string[], b: string[]): boolean {
  return a.length === b.length && a.every((item, index) => item === b[index]);
}

export class HaStateHub {
  private cache = new Map<string, HaState>();
  private bodies = new Map<string, string>();
  private subscribed = new Set<string>();
  private connected = false;
  private running = false;
  private desired = false;
  private reconciling: Promise<void> | null = null;
  private stopRequested = false;
  private resubscribeRequested = false;
  private wake: (() => void) | null = null;
  private loopDone: Promise<void> | null = null;
  private reconnects = 0;
  private lastEventAt = 0;
  private connectedSince = 0;
  private lastError: string | null = null;
  private activeConnection: HubConnection | null = null;

  private readonly now: () => number;
  private readonly idleMs: number;
  private readonly maxMissed: number;
  private readonly maxEntities: number;
  private readonly backoffInitialMs: number;
  private readonly backoffMaxMs: number;
  private readonly noTokenWaitMs: number;
  private readonly emptyRecheckMs: number;

  constructor(private readonly options: HubOptions) {
    this.now = options.now ?? Date.now;
    this.idleMs = options.idleMs ?? 20_000;
    this.maxMissed = options.maxMissed ?? 2;
    this.maxEntities = options.maxEntities ?? 2000;
    this.backoffInitialMs = options.backoffInitialMs ?? 5000;
    this.backoffMaxMs = options.backoffMaxMs ?? 60_000;
    this.noTokenWaitMs = options.noTokenWaitMs ?? 60_000;
    this.emptyRecheckMs = options.emptyRecheckMs ?? 60_000;
  }

  // ---- reading -------------------------------------------------------------------------------

  // The current state of an entity, serialized once per change. Null when this entity is not part
  // of the subscription or nothing has arrived for it yet (the caller then asks Home Assistant the
  // ordinary way). `stale` is true while the link is down: the data is the last known one.
  read(entityId: string): HubRead | null {
    if (!this.subscribed.has(entityId)) {
      return null;
    }
    const state = this.cache.get(entityId);
    if (!state) {
      return null;
    }
    let body = this.bodies.get(entityId);
    if (body === undefined) {
      body = JSON.stringify(state);
      this.bodies.set(entityId, body);
    }
    return { body, stale: !this.connected };
  }

  isConnected(): boolean {
    return this.connected;
  }

  status(): HubStatus {
    let newest = 0;
    for (const state of this.cache.values()) {
      const t = state.last_changed ? Date.parse(state.last_changed) : NaN;
      if (Number.isFinite(t) && t > newest) {
        newest = t;
      }
    }
    return {
      running: this.running,
      connected: this.connected,
      subscribed: this.subscribed.size,
      cached: this.cache.size,
      newestChangeAgeSeconds: newest > 0 ? Math.max(0, Math.round((this.now() - newest) / 1000)) : null,
      lastEventAt: this.lastEventAt ? new Date(this.lastEventAt).toISOString() : null,
      connectedSince: this.connected && this.connectedSince ? new Date(this.connectedSince).toISOString() : null,
      reconnects: this.reconnects,
      lastError: this.lastError
    };
  }

  // ---- lifecycle -----------------------------------------------------------------------------

  // Starts the supervisor once. A second call (double import, reload) does nothing, so there is
  // never more than one Home Assistant subscription in this process. start() and stop() only state
  // what is wanted; reconcile() makes it so, one transition at a time, so a quick off-then-on
  // (the dashboard setting) always ends in the state asked for last.
  start(): void {
    this.desired = true;
    void this.reconcile();
  }

  async stop(): Promise<void> {
    this.desired = false;
    await this.reconcile();
  }

  private reconcile(): Promise<void> {
    if (this.reconciling) {
      // A pass is running: let it finish, then look again (what is wanted may have changed meanwhile).
      return this.reconciling.then(() => this.reconcile());
    }
    const pass = (async () => {
      while (this.running !== this.desired) {
        if (this.desired) {
          this.stopRequested = false;
          this.running = true;
          this.loopDone = this.supervise();
        } else {
          this.stopRequested = true;
          this.wakeUp();
          try {
            this.activeConnection?.close();
          } catch {
            // already closed
          }
          await this.loopDone;
          this.loopDone = null;
          this.running = false;
          this.connected = false;
        }
      }
    })();
    this.reconciling = pass;
    void pass.finally(() => {
      if (this.reconciling === pass) {
        this.reconciling = null;
      }
    });
    return pass;
  }

  // The set of entities changed (a key was created, edited, disabled or deleted, or the Home
  // Assistant address changed): reconnect with the new list. Takes effect within one idle window.
  requestResubscribe(): void {
    this.resubscribeRequested = true;
    this.wakeUp();
  }

  // ---- events --------------------------------------------------------------------------------

  applyEvent(event: unknown): void {
    if (!isRecord(event)) {
      return;
    }
    const touched: string[] = [];

    if (isRecord(event.a)) {
      for (const [entityId, raw] of Object.entries(event.a)) {
        if (!isRecord(raw)) {
          continue;
        }
        const lastChanged = tsIso(raw.lc);
        this.cache.set(entityId, {
          entity_id: entityId,
          state: typeof raw.s === "string" ? raw.s : raw.s == null ? null : String(raw.s),
          attributes: isRecord(raw.a) ? { ...raw.a } : {},
          last_changed: lastChanged,
          last_updated: tsIso(raw.lu) ?? lastChanged
        });
        touched.push(entityId);
      }
    }

    if (isRecord(event.c)) {
      for (const [entityId, rawDelta] of Object.entries(event.c)) {
        const current = this.cache.get(entityId);
        if (!current || !isRecord(rawDelta)) {
          continue;
        }
        const plus = isRecord(rawDelta["+"]) ? rawDelta["+"] : {};
        const minus = isRecord(rawDelta["-"]) ? rawDelta["-"] : {};
        // Copy-on-write: build a new object, never edit the one readers may hold.
        const next: HaState = { ...current };
        if ("s" in plus) {
          next.state = plus.s == null ? null : String(plus.s);
        }
        if ("lc" in plus) {
          next.last_changed = tsIso(plus.lc);
        }
        if ("lu" in plus) {
          next.last_updated = tsIso(plus.lu);
        }
        if (isRecord(plus.a)) {
          next.attributes = { ...current.attributes, ...plus.a };
        }
        const gone = Array.isArray(minus.a) ? minus.a.filter((key): key is string => typeof key === "string") : [];
        if (gone.length > 0) {
          const removed = new Set(gone);
          next.attributes = Object.fromEntries(Object.entries(next.attributes).filter(([key]) => !removed.has(key)));
        }
        this.cache.set(entityId, next);
        touched.push(entityId);
      }
    }

    if (Array.isArray(event.r)) {
      // Removed from Home Assistant: keep the key and mark it unavailable.
      for (const entityId of event.r) {
        if (typeof entityId !== "string") {
          continue;
        }
        const current = this.cache.get(entityId);
        if (current && current.state !== "unavailable") {
          this.cache.set(entityId, { ...current, state: "unavailable" });
          touched.push(entityId);
        }
      }
    }

    for (const entityId of touched) {
      this.bodies.delete(entityId);
    }
    if (touched.length > 0 || isRecord(event.a) || isRecord(event.c)) {
      this.lastEventAt = this.now();
    }
  }

  // ---- connection ----------------------------------------------------------------------------

  private wakeUp(): void {
    const wake = this.wake;
    this.wake = null;
    wake?.();
  }

  // Sleeps up to `ms`, ends early when stop/resubscribe is requested. Returns true if woken early.
  private sleep(ms: number): Promise<boolean> {
    return new Promise<boolean>((resolve) => {
      const timer = setTimeout(() => {
        this.wake = null;
        resolve(false);
      }, ms);
      this.wake = () => {
        clearTimeout(timer);
        resolve(true);
      };
    });
  }

  private async supervise(): Promise<void> {
    // The sync loop must never die silently: anything that escapes is logged and the loop restarts.
    while (!this.stopRequested) {
      try {
        await this.loop();
      } catch (error) {
        this.lastError = error instanceof Error ? error.message : String(error);
        this.options.log?.warn(`Home Assistant sync loop crashed (${this.lastError}); restarting in 10 s`);
        await this.sleep(10_000);
      }
    }
  }

  private async loop(): Promise<void> {
    let backoff = this.backoffInitialMs;
    while (!this.stopRequested) {
      const token = this.options.getToken();
      if (!token) {
        await this.sleep(this.noTokenWaitMs);
        continue;
      }
      const started = this.now();
      try {
        this.resubscribeRequested = false;
        await this.runOnce(token);
        backoff = this.backoffInitialMs; // clean exit (resubscribe/stop): reconnect right away
      } catch (error) {
        if (this.stopRequested) {
          break;
        }
        this.lastError = error instanceof Error ? error.message : String(error);
        if (this.now() - started > 60_000) {
          backoff = this.backoffInitialMs; // it lived a while: it was healthy
        }
        this.options.log?.warn(`Home Assistant connection lost (${this.lastError}); retrying in ${Math.round(backoff / 1000)} s`);
        await this.sleep(backoff);
        backoff = Math.min(backoff * 2, this.backoffMaxMs);
      }
    }
  }

  private async resolveIds(): Promise<string[]> {
    const wanted = await this.options.collectEntityIds();
    const seen = new Set<string>();
    const ids: string[] = [];
    for (const id of wanted) {
      if (!isValidEntityId(id) || seen.has(id)) {
        continue;
      }
      seen.add(id);
      ids.push(id);
    }
    if (ids.length > this.maxEntities) {
      this.options.log?.warn(`More than ${this.maxEntities} entities are readable by API keys; not subscribing (requests fall back to the ordinary path)`);
      return [];
    }
    return ids;
  }

  private async expectType(ws: HubConnection, type: string): Promise<Record<string, unknown>> {
    const raw = await ws.recv(10_000);
    if (raw === RECV_TIMEOUT) {
      throw new Error(`no ${type} from Home Assistant`);
    }
    let parsed: unknown;
    try {
      parsed = JSON.parse(raw);
    } catch {
      throw new Error(`unreadable ${type} from Home Assistant`);
    }
    if (!isRecord(parsed) || parsed.type !== type) {
      throw new Error(isRecord(parsed) && parsed.type === "auth_invalid" ? "Home Assistant rejected the token" : `expected ${type} from Home Assistant`);
    }
    return parsed;
  }

  private async runOnce(token: string): Promise<void> {
    const url = `${this.options.baseUrl.replace(/\/$/, "").replace(/^http/, "ws")}${this.options.websocketPath ?? "/api/websocket"}`;
    const ws = await this.options.connect(url);
    this.activeConnection = ws;
    try {
      await this.expectType(ws, "auth_required");
      ws.send(JSON.stringify({ type: "auth", access_token: token }));
      await this.expectType(ws, "auth_ok");

      const ids = await this.resolveIds();

      if (ids.length === 0) {
        // Nothing to watch: no subscription, and no traffic. Wake up when the set changes, and
        // re-read the LOCAL list now and then (no contact with Home Assistant).
        this.subscribed = new Set();
        this.cache.clear();
        this.bodies.clear();
        ws.close();
        while (!this.stopRequested && !this.resubscribeRequested) {
          const woken = await this.sleep(this.emptyRecheckMs);
          if (woken) {
            break;
          }
          if (!sameList(await this.resolveIds(), ids)) {
            break;
          }
        }
        return;
      }

      // Entities that are no longer subscribed must not linger as "current" data.
      const keep = new Set(ids);
      for (const key of [...this.cache.keys()]) {
        if (!keep.has(key)) {
          this.cache.delete(key);
          this.bodies.delete(key);
        }
      }
      this.subscribed = keep;

      ws.send(JSON.stringify({ id: 1, type: "subscribe_entities", entity_ids: ids }));
      this.connected = true;
      this.connectedSince = this.now();
      this.reconnects += 1;
      this.options.log?.info(`Subscribed to ${ids.length} Home Assistant entities over one websocket`);

      // The silence window is `idleMs`, but the wait is cut into slices of at most one second so a
      // resubscribe or stop request is noticed within a second instead of after a whole window.
      const slice = Math.min(this.idleMs, 1000);
      let silent = 0;
      let missed = 0;
      let messageId = 1;
      while (!this.resubscribeRequested && !this.stopRequested) {
        const raw = await ws.recv(slice);
        if (raw === RECV_TIMEOUT) {
          silent += slice;
          if (silent < this.idleMs) {
            continue;
          }
          silent = 0;
          missed += 1;
          if (missed > this.maxMissed) {
            throw new Error("unresponsive");
          }
          messageId += 1;
          ws.send(JSON.stringify({ id: messageId, type: "ping" }));
          continue;
        }
        silent = 0;
        missed = 0; // any frame at all proves the link is alive
        let frame: unknown;
        try {
          frame = JSON.parse(raw);
        } catch {
          continue;
        }
        if (!isRecord(frame)) {
          continue;
        }
        if (frame.type === "event" && frame.event) {
          this.applyEvent(frame.event);
        } else if (frame.type === "result" && frame.success === false) {
          const detail = isRecord(frame.error) && typeof frame.error.message === "string" ? `: ${frame.error.message}` : "";
          throw new Error(`Home Assistant refused the subscription${detail}`);
        }
      }
    } finally {
      this.connected = false;
      this.activeConnection = null;
      try {
        ws.close();
      } catch {
        // already closed
      }
    }
  }
}
