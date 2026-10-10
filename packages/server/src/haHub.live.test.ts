import assert from "node:assert/strict";
import { after, afterEach, test } from "node:test";
import { HaStateHub } from "./haHub.js";
import { connectHaWebSocket } from "./haHubConnection.js";
import { FakeHaServer } from "./testHaSocket.js";

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));
async function until(check: () => boolean, ms = 4000): Promise<void> {
  const start = Date.now();
  while (!check()) {
    if (Date.now() - start > ms) throw new Error("timed out waiting for the condition");
    await sleep(10);
  }
}

const server = new FakeHaServer("good-token");
server.states.set("light.a", { s: "off", a: { brightness: 10 }, lc: 1700000000 });
server.states.set("sensor.b", { s: "21.5", a: { unit: "C" }, lc: 1700000000 });
server.states.set("switch.c", { s: "on", a: {}, lc: 1700000000 });
const port = await server.listen();

let wanted = ["light.a", "sensor.b"];
const hubs: HaStateHub[] = [];
function makeHub(token: string | null = "good-token") {
  const hub = new HaStateHub({
    baseUrl: `http://127.0.0.1:${port}`,
    getToken: () => token,
    collectEntityIds: () => wanted,
    connect: (url) => connectHaWebSocket(url, 2000),
    idleMs: 120,
    maxMissed: 2,
    backoffInitialMs: 30,
    backoffMaxMs: 120,
    noTokenWaitMs: 50,
    emptyRecheckMs: 5000
  });
  hubs.push(hub);
  return hub;
}

// Each test gets a clean slate: its hub is stopped before the next one starts.
afterEach(async () => {
  await Promise.all(hubs.map((hub) => hub.stop()));
  hubs.length = 0;
});

after(async () => {
  await server.close();
});

test("one websocket carries the whole subscription: initial snapshot, then changes only", async () => {
  const hub = makeHub();
  hub.start();
  hub.start(); // a second start() must not open a second subscription
  await until(() => hub.read("light.a") !== null && hub.read("sensor.b") !== null);

  assert.equal(server.connections, 1);
  assert.deepEqual(server.subscriptions, [["light.a", "sensor.b"]]);
  assert.equal(hub.read("switch.c"), null, "an entity nobody may read is not subscribed");
  const light = JSON.parse(hub.read("light.a")!.body);
  assert.equal(light.state, "off");
  assert.deepEqual(light.attributes, { brightness: 10 });

  server.pushChange("light.a", { s: "on", a: { brightness: 200 } });
  await until(() => JSON.parse(hub.read("light.a")!.body).state === "on");
  assert.deepEqual(JSON.parse(hub.read("light.a")!.body).attributes, { brightness: 200 });
  assert.equal(hub.read("light.a")!.stale, false);

  server.pushRemoved("sensor.b");
  await until(() => JSON.parse(hub.read("sensor.b")!.body).state === "unavailable");
  assert.equal(server.connections, 1, "no reconnect was needed for any of this");
});

test("a dropped connection is re-established by itself and data is flagged stale in between", async () => {
  const hub = makeHub();
  hub.start();
  await until(() => hub.isConnected());
  const before = server.connections;
  server.dropConnections();
  await until(() => !hub.isConnected());
  assert.equal(hub.read("light.a")?.stale, true);
  await until(() => hub.isConnected() && server.connections > before);
  assert.equal(hub.read("light.a")?.stale, false);
  assert.ok(hub.status().reconnects >= 2);
});

test("a link that goes silent without closing is detected by the deadman and replaced", async () => {
  const hub = makeHub();
  hub.start();
  await until(() => hub.isConnected());
  const before = server.connections;
  server.silent = true; // half-open link: no pongs, no events, no close
  await until(() => !hub.isConnected(), 3000);
  server.silent = false;
  await until(() => hub.isConnected() && server.connections > before, 3000);
  server.pushChange("switch.c", { s: "off" }); // not subscribed: must not matter
});

test("changing the readable entities reconnects with the new list", async () => {
  const hub = makeHub();
  hub.start();
  await until(() => hub.isConnected());
  wanted = ["light.a", "switch.c"];
  hub.requestResubscribe();
  await until(() => server.subscriptions.some((ids) => ids.join() === "light.a,switch.c"), 3000);
  await until(() => hub.read("switch.c") !== null);
  assert.equal(hub.read("sensor.b"), null, "an entity no key may read any more is dropped");
  wanted = ["light.a", "sensor.b"];
});

test("quiet link: the only thing sent to Home Assistant is keepalive pings", async () => {
  const hub = makeHub();
  hub.start();
  await until(() => hub.isConnected());
  const seen: string[] = [];
  const original = server.subscriptions.length;
  await sleep(600);
  seen.push(String(server.subscriptions.length - original));
  assert.deepEqual(seen, ["0"], "no re-subscription while nothing changes");
});

test("a wrong token never connects and says why", async () => {
  const hub = makeHub("wrong-token");
  hub.start();
  await until(() => (hub.status().lastError ?? "").includes("rejected the token"), 3000);
  assert.equal(hub.isConnected(), false);
});

test("no token configured: it does not even try to connect", async () => {
  const before = server.connections;
  const hub = makeHub(null);
  hub.start();
  await sleep(200);
  assert.equal(server.connections, before);
});
