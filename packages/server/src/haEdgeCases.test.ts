import assert from "node:assert/strict";
import { after, afterEach, test } from "node:test";
import { HaStateHub } from "./haHub.js";
import { connectHaWebSocket } from "./haHubConnection.js";
import { FakeHaServer } from "./testHaSocket.js";

// Awkward behaviour of Home Assistant, played back by a fake one against the real websocket client
// and the real hub: nothing in here may crash the loop, lose data, or serve something made up.

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));
async function until(check: () => boolean, ms = 5000): Promise<void> {
  const start = Date.now();
  while (!check()) {
    if (Date.now() - start > ms) throw new Error("timed out waiting for the condition");
    await sleep(10);
  }
}

const server = new FakeHaServer("good-token");
const port = await server.listen();
let token: string | null = "good-token";
let wanted: string[] = [];
const hubs: HaStateHub[] = [];
const logs: string[] = [];

function reset(): void {
  server.states.clear();
  server.silent = false;
  server.rejectAuth = false;
  server.hangAuth = false;
  server.failSubscribe = false;
  server.refuse = false;
  server.subscriptions = [];
  server.connections = 0;
  token = "good-token";
  wanted = [];
  logs.length = 0;
}

function makeHub(options: { idleMs?: number; maxEntities?: number } = {}): HaStateHub {
  const hub = new HaStateHub({
    baseUrl: `http://127.0.0.1:${port}`,
    getToken: () => token,
    collectEntityIds: () => wanted,
    connect: (url) => connectHaWebSocket(url, 500),
    log: { info: (m) => logs.push(m), warn: (m) => logs.push(m) },
    idleMs: options.idleMs ?? 150,
    maxMissed: 2,
    maxEntities: options.maxEntities,
    backoffInitialMs: 25,
    backoffMaxMs: 100,
    noTokenWaitMs: 40,
    emptyRecheckMs: 4000,
    handshakeMs: 400
  });
  hubs.push(hub);
  return hub;
}

afterEach(async () => {
  await Promise.all(hubs.map((h) => h.stop()));
  hubs.length = 0;
  server.dropConnections();
  reset();
});
after(async () => {
  await server.close();
});

const body = (hub: HaStateHub, id: string) => JSON.parse(hub.read(id)!.body) as { state: string; attributes: Record<string, unknown>; entity_id: string };

test("an entity Home Assistant does not know is not invented: it stays unread so the request goes the ordinary way", async () => {
  server.states.set("light.real", { s: "on" });
  wanted = ["light.real", "light.ghost"];
  const hub = makeHub();
  hub.start();
  await until(() => hub.read("light.real") !== null);
  assert.equal(hub.read("light.ghost"), null);
  assert.equal(hub.isConnected(), true);
});

test("an entity that appears later (added in Home Assistant after we subscribed) starts being served", async () => {
  server.states.set("light.real", { s: "on" });
  wanted = ["light.real", "light.late"];
  const hub = makeHub();
  hub.start();
  await until(() => hub.read("light.real") !== null);
  assert.equal(hub.read("light.late"), null);
  server.states.set("light.late", { s: "off" });
  // Home Assistant announces a new entity as an "a" (added) event
  server.pushRaw(JSON.stringify({ id: 1, type: "event", event: { a: { "light.late": { s: "off", a: {}, lc: 1700000000 } } } }));
  await until(() => hub.read("light.late") !== null);
  assert.equal(body(hub, "light.late").state, "off");
});

test("unavailable, then back: both are passed on as Home Assistant states them", async () => {
  server.states.set("sensor.t", { s: "21.5", a: { unit_of_measurement: "C" } });
  wanted = ["sensor.t"];
  const hub = makeHub();
  hub.start();
  await until(() => hub.read("sensor.t") !== null);
  server.pushChange("sensor.t", { s: "unavailable" });
  await until(() => body(hub, "sensor.t").state === "unavailable");
  assert.deepEqual(body(hub, "sensor.t").attributes, { unit_of_measurement: "C" }, "attributes survive the state change");
  server.pushChange("sensor.t", { s: "22.0" });
  await until(() => body(hub, "sensor.t").state === "22.0");
});

test("an entity removed in Home Assistant is served as unavailable, then recovers when it is re-added", async () => {
  server.states.set("light.x", { s: "on" });
  wanted = ["light.x"];
  const hub = makeHub();
  hub.start();
  await until(() => hub.read("light.x") !== null);
  server.pushRemoved("light.x");
  await until(() => body(hub, "light.x").state === "unavailable");
  server.pushRaw(JSON.stringify({ id: 1, type: "event", event: { a: { "light.x": { s: "off", a: {}, lc: 1700000100 } } } }));
  await until(() => body(hub, "light.x").state === "off");
});

test("an attribute that Home Assistant stops sending disappears; the others stay", async () => {
  server.states.set("light.x", { s: "on", a: { brightness: 100, color_temp: 300, friendly_name: "X" } });
  wanted = ["light.x"];
  const hub = makeHub();
  hub.start();
  await until(() => hub.read("light.x") !== null);
  server.pushChange("light.x", { s: "off" }, { a: ["brightness", "color_temp"] });
  await until(() => body(hub, "light.x").state === "off");
  assert.deepEqual(body(hub, "light.x").attributes, { friendly_name: "X" });
});

test("awkward attribute values pass through byte for byte (unicode, nesting, big numbers, nulls)", async () => {
  const attrs = { friendly_name: "Küche 🍳 ライト", nested: { list: [1, 2, { deep: null }], flag: false }, big: 12345678901234, tiny: 1e-9, empty: "", none: null };
  server.states.set("light.x", { s: "on", a: attrs });
  wanted = ["light.x"];
  const hub = makeHub();
  hub.start();
  await until(() => hub.read("light.x") !== null);
  assert.deepEqual(body(hub, "light.x").attributes, attrs);
});

test("garbage, binary and unknown frames are skipped; the socket and the data stay good", async () => {
  server.states.set("light.x", { s: "on" });
  wanted = ["light.x"];
  const hub = makeHub();
  hub.start();
  await until(() => hub.read("light.x") !== null);
  const connections = server.connections;
  for (const text of ["", "null", "[]", "42", "\"str\"", "{", "{\"type\":\"event\"}", "{\"type\":\"event\",\"event\":null}", "{\"type\":\"event\",\"event\":{\"c\":{\"light.x\":null}}}", "{\"type\":\"event\",\"event\":{\"c\":{\"light.x\":{\"+\":\"bad\"}}}}", "{\"type\":\"event\",\"event\":{\"a\":[1,2]}}", "{\"type\":\"who_knows\",\"id\":9}"]) {
    server.pushRaw(text);
  }
  server.pushBinary(Buffer.from([1, 2, 3, 4]));
  server.pushChange("light.x", { s: "off" });
  await until(() => body(hub, "light.x").state === "off");
  assert.equal(server.connections, connections, "no reconnect was needed");
  assert.equal(hub.isConnected(), true);
});

test("a 300 KB frame (a huge attribute) is handled without dropping the link", async () => {
  server.states.set("light.x", { s: "on" });
  wanted = ["light.x"];
  const hub = makeHub();
  hub.start();
  await until(() => hub.read("light.x") !== null);
  const connections = server.connections;
  server.pushChange("light.x", { s: "off", a: { blob: "x".repeat(300_000) } });
  await until(() => body(hub, "light.x").state === "off");
  assert.equal((body(hub, "light.x").attributes.blob as string).length, 300_000);
  assert.equal(server.connections, connections);
});

test("events for entities nobody subscribed to are ignored (no memory growth)", async () => {
  server.states.set("light.x", { s: "on" });
  wanted = ["light.x"];
  const hub = makeHub();
  hub.start();
  await until(() => hub.read("light.x") !== null);
  server.pushRaw(JSON.stringify({ id: 1, type: "event", event: { a: { "light.intruder": { s: "on", a: {} } } } }));
  server.pushRaw(JSON.stringify({ id: 1, type: "event", event: { c: { "light.intruder": { "+": { s: "off" } } } } }));
  server.pushChange("light.x", { s: "off" });
  await until(() => body(hub, "light.x").state === "off");
  assert.equal(hub.read("light.intruder"), null);
  assert.equal(hub.status().cached, 1);
});

test("Home Assistant restarting: stale while down, back to fresh by itself, with the new state, and no restart storm", async () => {
  server.states.set("light.x", { s: "on" });
  wanted = ["light.x"];
  const hub = makeHub();
  hub.start();
  await until(() => hub.isConnected());
  server.refuse = true;
  server.dropConnections();
  await until(() => !hub.isConnected());
  assert.equal(hub.read("light.x")?.stale, true);
  assert.equal(body(hub, "light.x").state, "on", "last known data is still there");
  await sleep(600); // many retry cycles at a 25-100 ms backoff
  assert.equal(server.connections, 1, "refused attempts never reach the fake: the one connection is the original");
  server.states.set("light.x", { s: "off" }); // changed while we were away
  server.refuse = false;
  await until(() => hub.isConnected());
  await until(() => body(hub, "light.x").state === "off", 3000);
  assert.equal(hub.read("light.x")?.stale, false);
});

test("Home Assistant stuck while starting (accepts the socket, never answers auth): the loop is not blocked and recovers", async () => {
  server.states.set("light.x", { s: "on" });
  wanted = ["light.x"];
  server.hangAuth = true;
  const hub = makeHub();
  hub.start();
  await sleep(1300); // three handshake timeouts
  assert.equal(hub.isConnected(), false);
  assert.ok(server.connections >= 2, `it kept trying (${server.connections} attempts)`);
  server.hangAuth = false;
  await until(() => hub.isConnected(), 4000);
  assert.equal(body(hub, "light.x").state, "on");
});

test("the token is revoked while connected: the link goes down, says why, and recovers when a good token is back", async () => {
  server.states.set("light.x", { s: "on" });
  wanted = ["light.x"];
  const hub = makeHub();
  hub.start();
  await until(() => hub.isConnected());
  server.rejectAuth = true;
  server.dropConnections();
  await until(() => (hub.status().lastError ?? "").includes("rejected the token"), 3000);
  assert.equal(hub.isConnected(), false);
  assert.equal(hub.read("light.x")?.stale, true);
  server.rejectAuth = false;
  await until(() => hub.isConnected(), 3000);
});

test("the token changes on disk (rotated): the next connection uses it without a restart", async () => {
  server.states.set("light.x", { s: "on" });
  wanted = ["light.x"];
  token = "bad-token";
  const hub = makeHub();
  hub.start();
  await until(() => (hub.status().lastError ?? "").includes("rejected the token"), 3000);
  token = "good-token";
  await until(() => hub.isConnected(), 3000);
});

test("Home Assistant refuses the subscription: reported, retried, and works once it accepts", async () => {
  server.states.set("light.x", { s: "on" });
  wanted = ["light.x"];
  server.failSubscribe = true;
  const hub = makeHub();
  hub.start();
  await until(() => (hub.status().lastError ?? "") !== "", 3000);
  assert.equal(hub.read("light.x"), null);
  server.failSubscribe = false;
  await until(() => hub.read("light.x") !== null, 3000);
});

test("1500 entities in one subscription: one socket, one snapshot, every entity served", async () => {
  wanted = [];
  for (let i = 0; i < 1500; i += 1) {
    const id = `sensor.s${i}`;
    server.states.set(id, { s: String(i), a: { n: i } });
    wanted.push(id);
  }
  const hub = makeHub();
  hub.start();
  await until(() => hub.status().cached === 1500, 6000);
  assert.equal(server.connections, 1);
  assert.equal(server.subscriptions.length, 1);
  assert.equal(body(hub, "sensor.s1499").state, "1499");
});

test("a burst of resubscribe requests collapses into a few reconnects, ending with the final list", async () => {
  server.states.set("light.a", { s: "on" });
  server.states.set("light.b", { s: "on" });
  wanted = ["light.a"];
  const hub = makeHub();
  hub.start();
  await until(() => hub.isConnected());
  const before = server.connections;
  for (let i = 0; i < 50; i += 1) {
    wanted = i % 2 === 0 ? ["light.a", "light.b"] : ["light.a"];
    hub.requestResubscribe();
  }
  wanted = ["light.a", "light.b"];
  hub.requestResubscribe();
  await until(() => hub.read("light.b") !== null, 3000);
  await sleep(200);
  assert.ok(server.connections - before <= 12, `50 requests caused ${server.connections - before} reconnects`);
  assert.deepEqual([...server.subscriptions.at(-1)!].sort(), ["light.a", "light.b"]);
});

test("stop() while connecting, while connected and while backing off always finishes quickly and cleanly", async () => {
  server.states.set("light.x", { s: "on" });
  wanted = ["light.x"];
  for (const scenario of ["hang", "connected", "backoff"] as const) {
    if (scenario === "hang") server.hangAuth = true;
    if (scenario === "backoff") { server.hangAuth = false; server.refuse = true; }
    if (scenario === "connected") { server.hangAuth = false; server.refuse = false; }
    const hub = makeHub();
    hub.start();
    if (scenario === "connected") await until(() => hub.isConnected());
    else await sleep(120);
    const started = Date.now();
    await hub.stop();
    assert.ok(Date.now() - started < 1500, `${scenario}: stop took ${Date.now() - started} ms`);
    assert.equal(hub.status().running, false);
    server.dropConnections();
  }
});

test("a deadman drop in the middle of a burst of events loses nothing that arrives after the reconnect", async () => {
  server.states.set("counter.n", { s: "0" });
  wanted = ["counter.n"];
  const hub = makeHub();
  hub.start();
  await until(() => hub.isConnected());
  for (let i = 1; i <= 20; i += 1) server.pushChange("counter.n", { s: String(i) });
  server.dropConnections();
  await until(() => !hub.isConnected());
  await until(() => hub.isConnected(), 3000);
  server.pushChange("counter.n", { s: "99" });
  await until(() => body(hub, "counter.n").state === "99");
});
