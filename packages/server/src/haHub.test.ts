import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { HaStateHub, RECV_TIMEOUT, isValidEntityId, type HubConnection, type HubOptions } from "./haHub.js";

type Step = string | typeof RECV_TIMEOUT | Error | (() => string | typeof RECV_TIMEOUT);

class ScriptedConnection implements HubConnection {
  sent: string[] = [];
  closed = false;
  constructor(private readonly script: Step[]) {}
  async recv(): Promise<string | typeof RECV_TIMEOUT> {
    const next = this.script.shift();
    if (next === undefined) throw new Error("link closed");
    if (next instanceof Error) throw next;
    return typeof next === "function" ? next() : next;
  }
  send(data: string): void {
    this.sent.push(data);
  }
  close(): void {
    this.closed = true;
  }
}

const handshake = [JSON.stringify({ type: "auth_required" }), JSON.stringify({ type: "auth_ok" })];
const event = (value: unknown) => JSON.stringify({ id: 1, type: "event", event: value });
const pong = (id: number) => JSON.stringify({ id, type: "pong" });

function makeHub(script: Step[], overrides: Partial<HubOptions> = {}) {
  const connection = new ScriptedConnection(script);
  const hub = new HaStateHub({
    baseUrl: "http://ha.local:8123",
    idleMs: 1000, // one scripted timeout = one full silence window
    getToken: () => "token",
    collectEntityIds: () => ["light.a", "sensor.b"],
    connect: async () => connection,
    ...overrides
  });
  return { hub, connection };
}
const run = (hub: HaStateHub) => (hub as unknown as { runOnce(token: string): Promise<void> }).runOnce("token");
const cacheOf = (hub: HaStateHub) => (hub as unknown as { cache: Map<string, Record<string, unknown>> }).cache;

test("three silent windows in a row drop the socket (the deadman) and the link is marked down", async () => {
  const { hub, connection } = makeHub([...handshake, RECV_TIMEOUT, RECV_TIMEOUT, RECV_TIMEOUT]);
  await assert.rejects(() => run(hub), /unresponsive/);
  assert.equal(hub.isConnected(), false);
  assert.equal(connection.closed, true);
  const pings = connection.sent.filter((m) => JSON.parse(m).type === "ping");
  assert.equal(pings.length, 2, "it pings after the first and second silent window");
});

test("any frame resets the silence counter: two timeouts then a pong, repeated, never trips the deadman", async () => {
  let hubRef: HaStateHub;
  const { hub } = makeHub([
    ...handshake,
    RECV_TIMEOUT, RECV_TIMEOUT, pong(2),
    RECV_TIMEOUT, RECV_TIMEOUT, pong(4),
    () => { hubRef.requestResubscribe(); return "{}"; }
  ]);
  hubRef = hub;
  await run(hub); // ends cleanly through the resubscribe request
  assert.equal(hub.isConnected(), false);
});

test("a resubscribe request ends the connection cleanly, without an error", async () => {
  let hubRef: HaStateHub;
  const { hub, connection } = makeHub([
    ...handshake,
    event({ a: { "light.a": { s: "on", a: {}, lc: 1700000000 } } }),
    () => { hubRef.requestResubscribe(); return "{}"; }
  ]);
  hubRef = hub;
  await run(hub);
  assert.equal(connection.closed, true);
  assert.equal(hub.read("light.a")?.stale, true, "data stays readable, but is marked stale while the link is down");
});

test("the subscription asks only for valid, de-duplicated entity ids, in order", async () => {
  let hubRef: HaStateHub;
  const { hub, connection } = makeHub(
    [...handshake, () => { hubRef.requestResubscribe(); return "{}"; }],
    { collectEntityIds: () => ["light.a", "bad id", "LIGHT.B", "sensor.x", "light.a", "../etc.passwd", ""] }
  );
  hubRef = hub;
  await run(hub);
  const subscribe = connection.sent.map((m) => JSON.parse(m)).find((m) => m.type === "subscribe_entities");
  assert.deepEqual(subscribe.entity_ids, ["light.a", "sensor.x"]);
  assert.equal(isValidEntityId("light.kitchen_1"), true);
  assert.equal(isValidEntityId("light"), false);
});

test("the first event is a full snapshot; a change is a NEW object and earlier references are untouched", async () => {
  let hubRef: HaStateHub;
  const { hub } = makeHub([
    ...handshake,
    event({ a: { "light.a": { s: "off", a: { brightness: 10, color: "red" }, lc: 1700000000, lu: 1700000001 } } }),
    () => { hubRef.requestResubscribe(); return "{}"; }
  ]);
  hubRef = hub;
  await run(hub);
  const before = cacheOf(hub).get("light.a")!;
  hub.applyEvent({ c: { "light.a": { "+": { s: "on", a: { brightness: 200 }, lc: 1700000100 }, "-": { a: ["color"] } } } });
  const after = cacheOf(hub).get("light.a")!;

  assert.notEqual(before, after);
  assert.equal(before.state, "off");
  assert.deepEqual(before.attributes, { brightness: 10, color: "red" });
  assert.equal(after.state, "on");
  assert.deepEqual(after.attributes, { brightness: 200 });
  assert.equal(after.last_changed, new Date(1700000100 * 1000).toISOString());
  assert.equal(after.last_updated, new Date(1700000001 * 1000).toISOString(), "an untouched field keeps its value");
});

test("a change for an entity that was never added is ignored", () => {
  const { hub } = makeHub([]);
  hub.applyEvent({ c: { "light.ghost": { "+": { s: "on" } } } });
  assert.equal(cacheOf(hub).size, 0);
});

test("removed entities are marked unavailable and keep their key", async () => {
  let hubRef: HaStateHub;
  const { hub } = makeHub([
    ...handshake,
    event({ a: { "light.a": { s: "on", a: {}, lc: 1 } } }),
    () => { hubRef.requestResubscribe(); return "{}"; }
  ]);
  hubRef = hub;
  await run(hub);
  hub.applyEvent({ r: ["light.a", "light.never_seen", 7] });
  assert.equal(cacheOf(hub).get("light.a")?.state, "unavailable");
  assert.equal(cacheOf(hub).has("light.never_seen"), false);
});

test("the serialized body is built once per change and rebuilt after a change", async () => {
  let hubRef: HaStateHub;
  let firstBody = "";
  const { hub } = makeHub([
    ...handshake,
    event({ a: { "light.a": { s: "off", a: {}, lc: 1 } } }),
    () => {
      firstBody = hub.read("light.a")!.body;
      assert.strictEqual(hub.read("light.a")!.body, firstBody, "same string object between changes");
      return event({ c: { "light.a": { "+": { s: "on" } } } });
    },
    () => { hubRef.requestResubscribe(); return "{}"; }
  ]);
  hubRef = hub;
  await run(hub);
  const secondBody = hub.read("light.a")!.body;
  assert.notEqual(secondBody, firstBody);
  assert.equal(JSON.parse(secondBody).state, "on");
  assert.equal(JSON.parse(secondBody).entity_id, "light.a");
});

test("while connected the data is fresh; while the link is down it is flagged stale", async () => {
  let hubRef: HaStateHub;
  const seen: boolean[] = [];
  const { hub } = makeHub([
    ...handshake,
    event({ a: { "light.a": { s: "on", a: {}, lc: 1 } } }),
    () => { seen.push(hub.read("light.a")!.stale); hubRef.requestResubscribe(); return "{}"; }
  ]);
  hubRef = hub;
  await run(hub);
  assert.deepEqual(seen, [false]);
  assert.equal(hub.read("light.a")!.stale, true);
  assert.equal(hub.read("sensor.not_subscribed"), null);
});

test("a corrupt or non-object frame is skipped and the socket stays up", async () => {
  let hubRef: HaStateHub;
  const { hub, connection } = makeHub([
    ...handshake,
    "not json at all",
    "[1,2,3]",
    "42",
    event({ a: { "light.a": { s: "on", a: {}, lc: 1 } } }),
    () => { hubRef.requestResubscribe(); return "{}"; }
  ]);
  hubRef = hub;
  await run(hub);
  assert.equal(cacheOf(hub).get("light.a")?.state, "on");
  assert.equal(connection.closed, true);
});

test("Home Assistant refusing the subscription, or the token, is an error the supervisor retries", async () => {
  const refused = makeHub([...handshake, JSON.stringify({ id: 1, type: "result", success: false, error: { message: "nope" } })]);
  await assert.rejects(() => run(refused.hub), /refused the subscription: nope/);

  const badToken = makeHub([handshake[0]!, JSON.stringify({ type: "auth_invalid" })]);
  await assert.rejects(() => run(badToken.hub), /rejected the token/);
});

test("if the entity list cannot be built, nothing is pruned and the error surfaces", async () => {
  let hubRef: HaStateHub;
  let calls = 0;
  const { hub } = makeHub(
    [
      ...handshake,
      event({ a: { "light.a": { s: "on", a: {}, lc: 1 } } }),
      () => { hubRef.requestResubscribe(); return "{}"; }
    ],
    {
      collectEntityIds: () => {
        calls += 1;
        if (calls > 1) throw new Error("database busy");
        return ["light.a"];
      }
    }
  );
  hubRef = hub;
  await run(hub);
  const again = new ScriptedConnection([...handshake]);
  (hub as unknown as { options: HubOptions }).options.connect = async () => again;
  await assert.rejects(() => run(hub), /database busy/);
  assert.equal(cacheOf(hub).get("light.a")?.state, "on", "last known data is not evicted by a failed refresh");
});

test("with nothing to watch there is no subscription: the socket is closed and it waits for a change", async () => {
  const { hub, connection } = makeHub([...handshake], { collectEntityIds: () => [], emptyRecheckMs: 5000 });
  const running = run(hub);
  await new Promise((resolve) => setTimeout(resolve, 50));
  assert.equal(connection.closed, true, "no idle socket is kept open");
  assert.ok(!connection.sent.some((m) => JSON.parse(m).type === "subscribe_entities"));
  hub.requestResubscribe();
  await running;
});

test("too many entities means no subscription at all (requests use the ordinary path)", async () => {
  const many = Array.from({ length: 50 }, (_, i) => `sensor.s${i}`);
  const { hub, connection } = makeHub([...handshake], { collectEntityIds: () => many, maxEntities: 10, emptyRecheckMs: 5000 });
  const running = run(hub);
  await new Promise((resolve) => setTimeout(resolve, 50));
  assert.ok(!connection.sent.some((m) => JSON.parse(m).type === "subscribe_entities"));
  hub.requestResubscribe();
  await running;
});

test("the status report says what is going on without contacting Home Assistant", async () => {
  const { hub } = makeHub([]);
  assert.equal(hub.status().connected, false);
  hub.applyEvent({ a: { "light.a": { s: "on", a: {}, lc: Math.floor(Date.now() / 1000) - 30 } } });
  assert.equal(hub.status().cached, 1);
  assert.ok((hub.status().newestChangeAgeSeconds ?? 0) >= 29);
});

test("only the gateway files talk to Home Assistant: no other module opens its own connection", () => {
  const dir = path.dirname(fileURLToPath(import.meta.url));
  const allowed = new Set(["ha.ts", "haHubConnection.ts", "hubRuntime.ts", "haToken.ts"]);
  const offenders: string[] = [];
  for (const file of fs.readdirSync(dir)) {
    if (!file.endsWith(".ts") || file.endsWith(".test.ts") || allowed.has(file)) continue;
    const text = fs.readFileSync(path.join(dir, file), "utf8");
    if (/from "undici"|env\.HA_BASE_URL|env\.HA_TOKEN|new WebSocket\(/.test(text) && !/^test/.test(file) && file !== "env.ts" && file !== "runtimeConfig.ts") {
      offenders.push(file);
    }
  }
  assert.deepEqual(offenders, []);
});
