import { fetch } from "undici";
import { env } from "./env.js";
import { CoalescingCache, ConcurrencyLimiter } from "./haGateway.js";
import { getHaToken } from "./haToken.js";
import { haHub } from "./hubRuntime.js";
import { getSettings, onSettingsChange, type GatewaySettings } from "./settings.js";

export type HaServiceProxyResult = {
  ok: boolean;
  status: number;
  contentType?: string;
  body: string;
  // True when the body is the last known state because the live link to Home Assistant is down.
  stale?: boolean;
};

const baseUrl = env.HA_BASE_URL.replace(/\/$/, "");

export type HaServiceCatalog = {
  domain: string;
  services: string[];
};

export type HaEntity = {
  entityId: string;
  domain: string;
  name: string;
};

// Every request to Home Assistant goes through one limiter, and state reads through the live
// connection or one shared cache, so the number of API keys in front of this server never turns
// into load on Home Assistant (see haHub.ts, haGateway.ts and docs/HOME_ASSISTANT_CONNECTION.md).
const REQUEST_TIMEOUT_MS = 15_000;
const limiter = new ConcurrencyLimiter(env.HA_MAX_CONCURRENCY, env.HA_MAX_CONCURRENCY * 8, 10_000);
const stateCache = new CoalescingCache<HaServiceProxyResult>(env.HA_STATE_CACHE_MS);

export class HaUnavailableError extends Error {
  constructor() {
    super("ha_unavailable");
    this.name = "HaUnavailableError";
  }
}

let gatewayStarted = false;

function applySettings(settings: GatewaySettings): void {
  limiter.setLimits(settings.maxConcurrency, settings.maxConcurrency * 8);
  stateCache.setTtl(settings.stateSource === "direct" ? 0 : settings.cacheMs);
  if (!gatewayStarted) {
    return;
  }
  if (settings.stateSource === "subscription") {
    haHub.start();
  } else {
    void haHub.stop();
  }
}
onSettingsChange(applySettings);

// Starts the live connection (when the settings ask for it). Called once by the server at startup,
// never at import time, so tests and tools that import this file open no websocket.
export function startGateway(): void {
  gatewayStarted = true;
  applySettings(getSettings());
}

export async function stopGateway(): Promise<void> {
  gatewayStarted = false;
  await haHub.stop();
}

export function gatewayStatus() {
  return {
    settings: getSettings(),
    live: haHub.status(),
    requests: { inFlight: limiter.inFlight, waiting: limiter.waiting }
  };
}

async function haRequest(
  url: string,
  init: { method: "GET" | "POST"; body?: string }
): Promise<HaServiceProxyResult> {
  return limiter.run(async () => {
    const res = await fetch(url, {
      method: init.method,
      headers: {
        Authorization: `Bearer ${getHaToken()}`,
        "Content-Type": "application/json"
      },
      body: init.body,
      signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS)
    });
    return {
      ok: res.ok,
      status: res.status,
      contentType: res.headers.get("content-type") ?? undefined,
      body: await res.text()
    };
  });
}

// After a service call, Home Assistant's change event is still on its way for a moment; reads in
// that window ask Home Assistant directly so the caller sees the effect of its own call.
const READ_YOUR_WRITES_MS = 1500;
let liveReadsUntil = 0;

export async function proxyHaServiceCall(
  domain: string,
  service: string,
  body: Record<string, unknown>,
  queryString = ""
): Promise<HaServiceProxyResult> {
  const url = `${baseUrl}/api/services/${encodeURIComponent(domain)}/${encodeURIComponent(
    service
  )}${queryString}`;
  try {
    return await haRequest(url, { method: "POST", body: JSON.stringify(body) });
  } finally {
    // Whatever the outcome, the next state read must reflect what this call may have changed.
    stateCache.invalidate();
    liveReadsUntil = Date.now() + READ_YOUR_WRITES_MS;
  }
}

function liveState(entityId: string): Promise<HaServiceProxyResult> {
  const url = `${baseUrl}/api/states/${encodeURIComponent(entityId)}`;
  return stateCache.get(
    entityId,
    () => haRequest(url, { method: "GET" }),
    (result) => result.ok
  );
}

export async function proxyHaState(entityId: string): Promise<HaServiceProxyResult> {
  const settings = getSettings();

  if (settings.stateSource === "subscription" && Date.now() >= liveReadsUntil) {
    const known = haHub.read(entityId);
    if (known && !known.stale) {
      return { ok: true, status: 200, contentType: "application/json", body: known.body };
    }
    if (known) {
      // The live link is down: apply the administrator's choice.
      if (settings.onLinkDown === "error") {
        throw new HaUnavailableError();
      }
      const lastKnown: HaServiceProxyResult = {
        ok: true,
        status: 200,
        contentType: "application/json",
        body: known.body,
        stale: true
      };
      if (settings.onLinkDown === "last-known") {
        return lastKnown;
      }
      try {
        const live = await liveState(entityId);
        if (live.ok) {
          return live;
        }
      } catch {
        // Home Assistant cannot be reached either: fall through to the last known value
      }
      return lastKnown;
    }
  }

  return liveState(entityId);
}

async function haJson<T>(path: string, failure: string): Promise<T> {
  const res = await haRequest(`${baseUrl}${path}`, { method: "GET" });
  if (!res.ok) {
    throw new Error(`${failure}:${res.status}`);
  }
  return JSON.parse(res.body) as T;
}

export async function fetchHaServices(): Promise<HaServiceCatalog[]> {
  const data = await haJson<Array<{ domain: string; services: Record<string, unknown> }>>(
    "/api/services",
    "ha_services_failed"
  );
  return data.map((entry) => ({
    domain: entry.domain,
    services: Object.keys(entry.services ?? {})
  }));
}

export async function fetchHaEntities(): Promise<HaEntity[]> {
  const data = await haJson<
    Array<{
      entity_id: string;
      attributes?: { friendly_name?: string };
    }>
  >("/api/states", "ha_entities_failed");

  return data.map((entry) => {
    const entityId = entry.entity_id;
    const domain = entityId.split(".")[0] ?? "unknown";
    const name = entry.attributes?.friendly_name ?? entityId;
    return { entityId, domain, name };
  });
}
