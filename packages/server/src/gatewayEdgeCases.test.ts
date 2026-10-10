import assert from "node:assert/strict";
import crypto from "node:crypto";
import type http from "node:http";
import { after, test } from "node:test";
import cookie from "@fastify/cookie";
import secureSession from "@fastify/secure-session";
import Fastify from "fastify";
import { FakeHaServer } from "./testHaSocket.js";
import { createTestDatabase } from "./testDb.js";

// The whole path (API key -> permission check -> gateway -> fake Home Assistant) under awkward
// conditions: errors from Home Assistant, a slow Home Assistant, lots of keys, hostile input.

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));
async function until(check: () => boolean | Promise<boolean>, ms = 6000): Promise<void> {
  const start = Date.now();
  while (!(await check())) {
    if (Date.now() - start > ms) throw new Error("timed out waiting for the condition");
    await sleep(15);
  }
}

// What the fake Home Assistant does on its REST side, switched per test.
const rest = {
  reads: 0,
  inFlight: 0,
  peak: 0,
  delayMs: 0,
  mode: "ok" as "ok" | "http500" | "badjson" | "http401" | "notfound",
  serviceMode: "ok" as "ok" | "http500" | "http401",
  entities: new Set<string>()
};
const onRequest: http.RequestListener = (req, res) => {
  const state = /^\/api\/states\/(.+)$/.exec(req.url ?? "");
  if (req.method === "GET" && state) {
    rest.reads += 1;
    rest.inFlight += 1;
    rest.peak = Math.max(rest.peak, rest.inFlight);
    const id = decodeURIComponent(state[1]!);
    setTimeout(() => {
      rest.inFlight -= 1;
      if (rest.mode === "http500") {
        res.writeHead(500, { "content-type": "text/html" });
        res.end("<html>Internal Server Error</html>");
      } else if (rest.mode === "http401") {
        res.writeHead(401, { "content-type": "application/json" });
        res.end(JSON.stringify({ message: "401: Unauthorized" }));
      } else if (rest.mode === "badjson") {
        res.writeHead(200, { "content-type": "application/json" });
        res.end("{not json at all");
      } else if (rest.mode === "notfound" || !rest.entities.has(id)) {
        res.writeHead(404, { "content-type": "application/json" });
        res.end(JSON.stringify({ message: "Entity not found." }));
      } else {
        res.writeHead(200, { "content-type": "application/json" });
        res.end(JSON.stringify({ entity_id: id, state: "from-rest", attributes: {} }));
      }
    }, rest.delayMs);
    return;
  }
  if (req.method === "POST" && req.url?.startsWith("/api/services/")) {
    if (rest.serviceMode === "http500") {
      res.writeHead(500, { "content-type": "application/json" });
      res.end(JSON.stringify({ message: "boom" }));
    } else if (rest.serviceMode === "http401") {
      res.writeHead(401, { "content-type": "application/json" });
      res.end(JSON.stringify({ message: "401: Unauthorized" }));
    } else {
      res.writeHead(200, { "content-type": "application/json" });
      res.end("[]");
    }
    return;
  }
  if (req.method === "GET" && req.url === "/api/states") {
    res.writeHead(500);
    res.end("down");
    return;
  }
  res.writeHead(404);
  res.end();
};
const ha = new FakeHaServer("fake-ha-token", onRequest);
const haPort = await ha.listen();

process.env.NODE_ENV = "test";
process.env.HA_BASE_URL = `http://127.0.0.1:${haPort}`;
process.env.HA_TOKEN = "fake-ha-token";
process.env.ADMIN_PASSWORD = "correct-horse-battery-staple";
process.env.ADMIN_SESSION_SECRET = "12345678901234567890123456789012";
process.env.API_KEY_HASH_SECRET = "12345678901234567890123456789012";
const testDb = createTestDatabase();
process.env.DATABASE_URL = testDb.databaseUrl;

const { prisma } = await import("./db.js");
const { createTokenAccess } = await import("./tokenAccess.js");
const { publicApiRoutes } = await import("./publicApi.js");
const { adminRoutes } = await import("./admin.js");
const { startGateway, stopGateway } = await import("./ha.js");
const { haHub } = await import("./hubRuntime.js");
const { saveSettings, resetSettings, loadSettings } = await import("./settings.js");
const { startHaMonitor, stopHaMonitor, alertManager } = await import("./haMonitor.js");

const app = Fastify({ logger: false });
await app.register(cookie);
await app.register(secureSession, {
  key: crypto.createHash("sha256").update(process.env.ADMIN_SESSION_SECRET!).digest(),
  cookieName: "hgk_admin",
  cookie: { path: "/", httpOnly: true, sameSite: "lax", secure: false }
});
await app.register(publicApiRoutes, { prefix: "/api" });
await app.register(adminRoutes, { prefix: "/admin" });
await loadSettings(prisma);

after(async () => {
  stopHaMonitor();
  await stopGateway();
  await app.close();
  await prisma.$disconnect();
  await ha.close();
  testDb.cleanup();
});

async function makeKey(name: string, entityIds: string[], services = false) {
  return createTokenAccess(prisma, {
    name,
    status: "active",
    permissions: [
      { kind: "state", entityIds },
      ...(services ? [{ kind: "service" as const, domain: "light", services: ["turn_on"], entityIds, allowNoEntity: false }] : [])
    ]
  });
}
const auth = (apiKey: string) => ({ authorization: `Bearer ${apiKey}` });
async function adminCookie(): Promise<string> {
  const login = await app.inject({ method: "POST", url: "/admin/login", payload: { password: process.env.ADMIN_PASSWORD } });
  const raw = login.headers["set-cookie"];
  return String(Array.isArray(raw) ? raw[0] : raw).split(";")[0]!;
}
function resetRest(): void {
  rest.reads = 0;
  rest.peak = 0;
  rest.delayMs = 0;
  rest.mode = "ok";
  rest.serviceMode = "ok";
}

test("a key for an entity Home Assistant does not have: Home Assistant's 404 is passed on, nothing crashes", async () => {
  resetRest();
  await saveSettings(prisma, { stateSource: "direct" });
  const key = await makeKey("ghost", ["light.ghost"]);
  const res = await app.inject({ method: "GET", url: "/api/states/light.ghost", headers: auth(key.apiKey) });
  assert.equal(res.statusCode, 404);
  assert.match(res.body, /not found/i);
  await resetSettings(prisma);
});

test("Home Assistant answers an error page (500, HTML): status and body are passed on, and it is audited as a failure", async () => {
  resetRest();
  await saveSettings(prisma, { stateSource: "direct", cacheMs: 0 });
  rest.entities.add("light.e1");
  rest.mode = "http500";
  const key = await makeKey("err500", ["light.e1"]);
  const res = await app.inject({ method: "GET", url: "/api/states/light.e1", headers: auth(key.apiKey) });
  assert.equal(res.statusCode, 500);
  assert.match(res.body, /Internal Server Error/);
  const row = await prisma.auditLog.findFirst({ where: { actionIdRaw: "states.light.e1" }, orderBy: { timestamp: "desc" } });
  assert.equal(row?.success, false);
  assert.equal(row?.error, "ha_request_failed:500");
  rest.mode = "ok";
  const recovered = await app.inject({ method: "GET", url: "/api/states/light.e1", headers: auth(key.apiKey) });
  assert.equal(recovered.statusCode, 200, "a failure is never cached");
  await resetSettings(prisma);
});

test("Home Assistant rejects the gateway's own token (401): the caller gets 502 ha_unauthorized, never a misleading 401", async () => {
  resetRest();
  await saveSettings(prisma, { stateSource: "direct", cacheMs: 0 });
  rest.entities.add("light.e2");
  rest.mode = "http401";
  const key = await makeKey("err401", ["light.e2"]);
  const res = await app.inject({ method: "GET", url: "/api/states/light.e2", headers: auth(key.apiKey) });
  assert.equal(res.statusCode, 502);
  assert.deepEqual(res.json(), { ok: false, error: "ha_unauthorized" });
  const row = await prisma.auditLog.findFirst({ where: { actionIdRaw: "states.light.e2" }, orderBy: { timestamp: "desc" } });
  assert.equal(row?.error, "ha_unauthorized");
  await resetSettings(prisma);
});

test("a malformed 200 reply is passed through untouched (the gateway does not parse it)", async () => {
  resetRest();
  await saveSettings(prisma, { stateSource: "direct", cacheMs: 0 });
  rest.entities.add("light.e3");
  rest.mode = "badjson";
  const key = await makeKey("badjson", ["light.e3"]);
  const res = await app.inject({ method: "GET", url: "/api/states/light.e3", headers: auth(key.apiKey) });
  assert.equal(res.statusCode, 200);
  assert.equal(res.body, "{not json at all");
  await resetSettings(prisma);
});

test("service calls: errors from Home Assistant are passed on and the next read still sees fresh data", async () => {
  resetRest();
  await saveSettings(prisma, { stateSource: "direct", cacheMs: 0 });
  rest.entities.add("light.s1");
  const key = await makeKey("svc", ["light.s1"], true);
  rest.serviceMode = "http500";
  const failed = await app.inject({ method: "POST", url: "/api/services/light/turn_on", headers: auth(key.apiKey), payload: { entity_id: "light.s1" } });
  assert.equal(failed.statusCode, 500);
  rest.serviceMode = "http401";
  const unauthorised = await app.inject({ method: "POST", url: "/api/services/light/turn_on", headers: auth(key.apiKey), payload: { entity_id: "light.s1" } });
  assert.equal(unauthorised.statusCode, 502);
  assert.equal(unauthorised.json().error, "ha_unauthorized");
  rest.serviceMode = "ok";
  const ok = await app.inject({ method: "POST", url: "/api/services/light/turn_on", headers: auth(key.apiKey), payload: { entity_id: "light.s1" } });
  assert.equal(ok.statusCode, 200);
  await resetSettings(prisma);
});

test("a slow Home Assistant never sees more than the allowed number of requests at once; the overflow gets 503 ha_busy", async () => {
  resetRest();
  await saveSettings(prisma, { stateSource: "direct", cacheMs: 0, maxConcurrency: 2 });
  rest.delayMs = 120;
  const ids = Array.from({ length: 60 }, (_, i) => `sensor.slow${i}`);
  ids.forEach((id) => rest.entities.add(id));
  const key = await makeKey("slow", ids);
  const responses = await Promise.all(ids.map((id) => app.inject({ method: "GET", url: `/api/states/${id}`, headers: auth(key.apiKey) })));
  const codes = responses.map((r) => r.statusCode);
  assert.ok(rest.peak <= 2, `peak in flight at Home Assistant was ${rest.peak}`);
  assert.ok(codes.filter((c) => c === 200).length >= 10, "a good share is still served");
  const busy = responses.filter((r) => r.statusCode === 503);
  assert.ok(busy.length > 0, "the overflow is refused instead of piling up");
  assert.ok(busy.every((r) => r.headers["retry-after"] === "1" && r.json().error === "ha_busy"));
  assert.ok(codes.every((c) => c === 200 || c === 503), `unexpected codes: ${[...new Set(codes)]}`);
  await resetSettings(prisma);
});

test("100 keys for 100 different entities: one websocket, one subscription, 500 reads, zero requests to Home Assistant", async () => {
  resetRest();
  await resetSettings(prisma);
  ha.subscriptions = [];
  ha.connections = 0;
  const keys: Array<{ apiKey: string; entity: string }> = [];
  for (let i = 0; i < 100; i += 1) {
    const entity = `sensor.many${i}`;
    ha.states.set(entity, { s: String(i), a: { i }, lc: 1700000000 });
    keys.push({ apiKey: (await makeKey(`many${i}`, [entity])).apiKey, entity });
  }
  startGateway();
  await until(() => haHub.status().cached >= 100, 10_000);
  assert.equal(ha.connections, 1, "one websocket");
  assert.ok(ha.subscriptions.some((ids) => ids.length >= 100), "the subscription covers every readable entity");
  const subscriptionsBefore = ha.subscriptions.length;
  const before = rest.reads;
  const reads = await Promise.all(
    Array.from({ length: 500 }, (_, i) => {
      const k = keys[i % 100]!;
      return app.inject({ method: "GET", url: `/api/states/${k.entity}`, headers: auth(k.apiKey) });
    })
  );
  assert.ok(reads.every((r) => r.statusCode === 200));
  assert.equal(rest.reads - before, 0, "Home Assistant saw none of them");
  assert.equal(ha.subscriptions.length, subscriptionsBefore, "reads never resubscribe");
  assert.equal(JSON.parse(reads[37]!.body).state, "37");
});

test("disabling and deleting keys shrinks the subscription to what active keys still need", async () => {
  const cookieValue = await adminCookie();
  const list = (await app.inject({ method: "GET", url: "/admin/clients", headers: { cookie: cookieValue } })).json().clients as Array<{ id: string; name: string }>;
  const many5 = list.find((c) => c.name === "many5")!;
  const many6 = list.find((c) => c.name === "many6")!;
  const before = ha.subscriptions.length;
  const disabled = await app.inject({ method: "PATCH", url: `/admin/clients/${many5.id}`, headers: { cookie: cookieValue }, payload: { status: "disabled" } });
  assert.equal(disabled.statusCode, 200);
  await until(() => ha.subscriptions.length > before, 8000);
  assert.ok(!ha.subscriptions.at(-1)!.includes("sensor.many5"), "disabled key: entity dropped");
  assert.ok(ha.subscriptions.at(-1)!.includes("sensor.many6"));
  const mid = ha.subscriptions.length;
  const deleted = await app.inject({ method: "DELETE", url: `/admin/clients/${many6.id}`, headers: { cookie: cookieValue } });
  assert.equal(deleted.statusCode, 200);
  await until(() => ha.subscriptions.length > mid, 8000);
  assert.ok(!ha.subscriptions.at(-1)!.includes("sensor.many6"), "deleted key: entity dropped");
  // and the deleted key is refused at once
});

test("a revoked key is refused on its very next request", async () => {
  const key = await makeKey("revoke-me", ["light.zz"]);
  const cookieValue = await adminCookie();
  const list = (await app.inject({ method: "GET", url: "/admin/clients", headers: { cookie: cookieValue } })).json().clients as Array<{ id: string; name: string }>;
  const id = list.find((c) => c.name === "revoke-me")!.id;
  const first = await app.inject({ method: "GET", url: "/api/states/light.zz", headers: auth(key.apiKey) });
  assert.notEqual(first.statusCode, 401);
  await app.inject({ method: "DELETE", url: `/admin/clients/${id}`, headers: { cookie: cookieValue } });
  const second = await app.inject({ method: "GET", url: "/api/states/light.zz", headers: auth(key.apiKey) });
  assert.equal(second.statusCode, 401);
});

test("hostile or odd input is refused cleanly and never reaches Home Assistant", async () => {
  resetRest();
  const key = await makeKey("hostile", ["light.ok"]);
  const before = rest.reads;
  const paths = [
    "/api/states/light.ok%2F..%2F..%2Fapi%2Fconfig",
    "/api/states/LIGHT.OK",
    "/api/states/light.ok%00",
    "/api/states/" + "a".repeat(5000),
    "/api/states/%E2%9C%93.%F0%9F%A4%96",
    "/api/states/light.ok/extra",
    "/api/states/.."
  ];
  for (const url of paths) {
    const res = await app.inject({ method: "GET", url, headers: auth(key.apiKey) });
    assert.ok([400, 403, 404, 414].includes(res.statusCode), `${url.slice(0, 40)} -> ${res.statusCode}`);
  }
  assert.equal(rest.reads - before, 0, "none of it was forwarded");
  const weird = [
    "Bearer",
    "Bearer ",
    "bearer " + key.apiKey,
    "Bearer " + "x".repeat(20_000),
    "Bearer a b",
    "Basic " + Buffer.from("a:b").toString("base64"),
    "Bearer \u0000"
  ];
  for (const value of weird) {
    let status = 0;
    try {
      status = (await app.inject({ method: "GET", url: "/api/states/light.ok", headers: { authorization: value } })).statusCode;
    } catch {
      status = -1; // the HTTP layer itself refused the header: also fine
    }
    assert.ok(status === 401 || status === 400 || status === 431 || status === -1 || status === 200 || status === 404, `${JSON.stringify(value.slice(0, 20))} -> ${status}`);
    assert.notEqual(status, 500);
  }
});

test("an oversized request body is refused (413), not buffered", async () => {
  const key = await makeKey("big", ["light.big"], true);
  const res = await app.inject({
    method: "POST",
    url: "/api/services/light/turn_on",
    headers: { ...auth(key.apiKey), "content-type": "application/json" },
    payload: JSON.stringify({ entity_id: "light.big", pad: "x".repeat(3_000_000) })
  });
  assert.equal(res.statusCode, 413);
});

test("the dashboard survives Home Assistant being broken: status and settings still answer, the entity list says 502", async () => {
  const cookieValue = await adminCookie();
  const status = await app.inject({ method: "GET", url: "/admin/connection", headers: { cookie: cookieValue } });
  assert.equal(status.statusCode, 200);
  const settings = await app.inject({ method: "GET", url: "/admin/settings", headers: { cookie: cookieValue } });
  assert.equal(settings.statusCode, 200);
  const entities = await app.inject({ method: "GET", url: "/admin/ha/entities", headers: { cookie: cookieValue } });
  assert.equal(entities.statusCode, 502);
  assert.equal(entities.json().error, "ha_entities_failed");
});

test("one key hitting its rate limit does not slow another key down", async () => {
  await saveSettings(prisma, { rateLimitPerMinute: 4 });
  rest.entities.add("light.rl");
  await saveSettings(prisma, { stateSource: "direct" });
  const a = await makeKey("rl-a", ["light.rl"]);
  const b = await makeKey("rl-b", ["light.rl"]);
  const codesA: number[] = [];
  for (let i = 0; i < 8; i += 1) {
    codesA.push((await app.inject({ method: "GET", url: "/api/states/light.rl", headers: auth(a.apiKey) })).statusCode);
  }
  assert.equal(codesA.filter((c) => c === 429).length, 4);
  const codesB: number[] = [];
  for (let i = 0; i < 4; i += 1) {
    codesB.push((await app.inject({ method: "GET", url: "/api/states/light.rl", headers: auth(b.apiKey) })).statusCode);
  }
  assert.deepEqual(codesB, [200, 200, 200, 200]);
  await resetSettings(prisma);
});

test("the alert monitor follows the live link: down when Home Assistant goes away, up again when it is back", async () => {
  await resetSettings(prisma);
  startGateway();
  await until(() => haHub.isConnected(), 10_000);
  startHaMonitor();
  await until(() => !alertManager.status().haDown, 8000);
  ha.refuse = true;
  ha.dropConnections();
  await until(() => alertManager.status().haDown, 15_000);
  assert.equal(alertManager.status().alerted, false, "the delay (120 s by default) has not passed");
  ha.refuse = false;
  await until(() => !alertManager.status().haDown, 20_000);
});
