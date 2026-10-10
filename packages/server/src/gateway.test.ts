import assert from "node:assert/strict";
import crypto from "node:crypto";
import type http from "node:http";
import { after, test } from "node:test";
import cookie from "@fastify/cookie";
import secureSession from "@fastify/secure-session";
import Fastify from "fastify";
import { FakeHaServer } from "./testHaSocket.js";
import { createTestDatabase } from "./testDb.js";

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));
async function until(check: () => boolean | Promise<boolean>, ms = 5000): Promise<void> {
  const start = Date.now();
  while (!(await check())) {
    if (Date.now() - start > ms) throw new Error("timed out waiting for the condition");
    await sleep(15);
  }
}

// Home Assistant look-alike: REST for the fallback path (counted), websocket for the live path.
let restReads = 0;
let restDown = false;
const onRequest: http.RequestListener = (req, res) => {
  const match = /^\/api\/states\/(.+)$/.exec(req.url ?? "");
  if (req.method === "GET" && match) {
    restReads += 1;
    if (restDown) {
      res.writeHead(503);
      res.end("down");
      return;
    }
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({ entity_id: match[1], state: "from-rest", attributes: {} }));
    return;
  }
  if (req.method === "POST" && req.url?.startsWith("/api/services/")) {
    res.writeHead(200, { "content-type": "application/json" });
    res.end("[]");
    return;
  }
  res.writeHead(404);
  res.end();
};
const ha = new FakeHaServer("fake-ha-token", onRequest);
ha.states.set("light.a", { s: "off", a: { brightness: 1 }, lc: 1700000000 });
ha.states.set("sensor.b", { s: "21", a: {}, lc: 1700000000 });
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
const { startGateway, stopGateway, proxyHaState } = await import("./ha.js");
const { haHub } = await import("./hubRuntime.js");
const { loadSettings, saveSettings, resetSettings, getSettings, defaultSettings } = await import("./settings.js");

const app = Fastify({ logger: false });
await app.register(cookie);
await app.register(secureSession, {
  key: crypto.createHash("sha256").update(process.env.ADMIN_SESSION_SECRET!).digest(),
  cookieName: "hgk_admin",
  cookie: { path: "/", httpOnly: true, sameSite: "lax", secure: false }
});
await app.register(publicApiRoutes, { prefix: "/api" });
await app.register(adminRoutes, { prefix: "/admin" });

after(async () => {
  await stopGateway();
  await app.close();
  await prisma.$disconnect();
  await ha.close();
  testDb.cleanup();
});

const key = await createTokenAccess(prisma, {
  name: "reader",
  status: "active",
  permissions: [
    { kind: "state", entityIds: ["light.a"] },
    { kind: "service", domain: "light", services: ["turn_on"], entityIds: ["light.a"], allowNoEntity: false }
  ]
});
const headers = { authorization: `Bearer ${key.apiKey}` };
const getState = (entity = "light.a") => app.inject({ method: "GET", url: `/api/states/${entity}`, headers });

async function adminCookie(): Promise<string> {
  const login = await app.inject({ method: "POST", url: "/admin/login", payload: { password: process.env.ADMIN_PASSWORD } });
  assert.equal(login.statusCode, 200);
  const raw = login.headers["set-cookie"];
  return String(Array.isArray(raw) ? raw[0] : raw).split(";")[0]!;
}

test("settings start at the safe defaults and survive a save/load round trip", async () => {
  await loadSettings(prisma);
  assert.deepEqual(getSettings(), defaultSettings());
  assert.equal(getSettings().stateSource, "subscription");
  await saveSettings(prisma, { cacheMs: 5000, onLinkDown: "last-known" });
  assert.equal(getSettings().cacheMs, 5000);
  const rows = await prisma.setting.findMany({ orderBy: { key: "asc" } });
  assert.deepEqual(rows.map((r) => r.key), ["cacheMs", "onLinkDown"], "only what was changed is stored");
  await resetSettings(prisma);
  assert.deepEqual(getSettings(), defaultSettings());
  assert.equal(await prisma.setting.count(), 0);
});

test("live subscription: reads are answered from memory and never reach Home Assistant", async () => {
  startGateway();
  await until(() => haHub.read("light.a") !== null);
  const before = restReads;

  const responses = await Promise.all(Array.from({ length: 40 }, () => getState()));
  assert.ok(responses.every((r) => r.statusCode === 200));
  assert.equal(JSON.parse(responses[0]!.body).state, "off");
  assert.equal(responses[0]!.headers["x-ha-stale"], undefined);
  assert.equal(restReads - before, 0, "40 reads, no request to Home Assistant");

  ha.pushChange("light.a", { s: "on" });
  await until(async () => JSON.parse((await getState()).body).state === "on");
  assert.equal(restReads - before, 0);
});

test("an entity the key may not read is still refused before anything is looked up", async () => {
  const response = await getState("sensor.b");
  assert.equal(response.statusCode, 403);
});

test("a service call is followed by reads that see its effect (read-your-writes)", async () => {
  const before = restReads;
  const call = await app.inject({ method: "POST", url: "/api/services/light/turn_on", headers, payload: { entity_id: "light.a" } });
  assert.equal(call.statusCode, 200);
  const read = await getState();
  assert.equal(JSON.parse(read.body).state, "from-rest", "right after a call the read asks Home Assistant");
  assert.equal(restReads - before, 1);
  await sleep(1600);
  assert.equal(JSON.parse((await getState()).body).state, "on", "afterwards it is served from the live copy again");
});

test("link down, default policy: ask Home Assistant, and fall back to last known (flagged) if that fails too", async () => {
  ha.refuse = true;
  ha.dropConnections();
  await until(() => !haHub.isConnected());
  await sleep(1600);

  const live = await getState();
  assert.equal(live.statusCode, 200);
  assert.equal(JSON.parse(live.body).state, "from-rest");
  assert.equal(live.headers["x-ha-stale"], undefined);

  restDown = true;
  await sleep(2100); // let the shared answer expire
  const fallback = await getState();
  assert.equal(fallback.statusCode, 200);
  assert.equal(fallback.headers["x-ha-stale"], "1");
  assert.equal(JSON.parse(fallback.body).state, "on");
});

test("link down, 'last known' policy never asks Home Assistant; 'error' policy says 503", async () => {
  await saveSettings(prisma, { onLinkDown: "last-known" });
  restDown = false;
  const before = restReads;
  const stale = await getState();
  assert.equal(stale.headers["x-ha-stale"], "1");
  assert.equal(restReads - before, 0);

  await saveSettings(prisma, { onLinkDown: "error" });
  const refused = await getState();
  assert.equal(refused.statusCode, 503);
  assert.deepEqual(refused.json(), { ok: false, error: "ha_unavailable" });
  await saveSettings(prisma, { onLinkDown: "live-then-last-known" });
});

test("the link comes back by itself and fresh data resumes", async () => {
  ha.refuse = false;
  await until(() => haHub.isConnected(), 8000);
  const read = await getState();
  assert.equal(read.headers["x-ha-stale"], undefined);
  assert.equal(JSON.parse(read.body).state, "on");
});

test("creating a key for another entity reconnects with the new list, without a restart", async () => {
  const before = ha.subscriptions.length;
  const cookieValue = await adminCookie();
  const created = await app.inject({
    method: "POST",
    url: "/admin/clients",
    headers: { cookie: cookieValue },
    payload: { name: "second", permissions: [{ kind: "state", entityIds: ["sensor.b"] }] }
  });
  assert.equal(created.statusCode, 200);
  await until(() => ha.subscriptions.length > before, 8000);
  assert.deepEqual([...ha.subscriptions.at(-1)!].sort(), ["light.a", "sensor.b"]);
  await until(() => haHub.read("sensor.b") !== null);
});

test("the dashboard settings API: read, change (applies at once), validate, reset", async () => {
  const cookieValue = await adminCookie();
  const get = await app.inject({ method: "GET", url: "/admin/settings", headers: { cookie: cookieValue } });
  assert.equal(get.statusCode, 200);
  const body = get.json();
  assert.equal(body.settings.stateSource, "subscription");
  assert.ok(body.help.length >= 5 && body.help.every((h: { label: string; summary: string }) => h.label && h.summary));

  const unauth = await app.inject({ method: "GET", url: "/admin/settings" });
  assert.equal(unauth.statusCode, 401);

  const bad = await app.inject({ method: "PUT", url: "/admin/settings", headers: { cookie: cookieValue }, payload: { maxConcurrency: 0, bogus: 1 } });
  assert.equal(bad.statusCode, 400);

  const put = await app.inject({ method: "PUT", url: "/admin/settings", headers: { cookie: cookieValue }, payload: { stateSource: "cache" } });
  assert.equal(put.statusCode, 200);
  await until(() => !haHub.status().running, 3000);
  const before = restReads;
  await getState();
  await getState();
  assert.equal(restReads - before, 1, "cache mode: asks Home Assistant once, shares the answer");

  const audit = await prisma.auditLog.findFirst({ where: { actionIdRaw: "admin.settings.update" }, orderBy: { timestamp: "desc" } });
  assert.equal(audit?.error, "changed:stateSource");

  const reset = await app.inject({ method: "POST", url: "/admin/settings/reset", headers: { cookie: cookieValue } });
  assert.equal(reset.json().settings.stateSource, "subscription");
  await until(() => haHub.status().running, 3000);

  const status = await app.inject({ method: "GET", url: "/admin/connection", headers: { cookie: cookieValue } });
  assert.equal(status.statusCode, 200);
  assert.equal(typeof status.json().live.connected, "boolean");
});

test("proxyHaState without the live link started behaves as the plain, shared REST path", async () => {
  await stopGateway();
  await sleep(2100); // let any earlier shared answer expire
  const before = restReads;
  await Promise.all([proxyHaState("light.a"), proxyHaState("light.a"), proxyHaState("light.a")]);
  assert.equal(restReads - before, 1);
});

test("the per-key rate limit is an option that applies at once", async () => {
  const limited = await createTokenAccess(prisma, {
    name: "limited",
    status: "active",
    permissions: [{ kind: "state", entityIds: ["light.a"] }]
  });
  const limitedHeaders = { authorization: `Bearer ${limited.apiKey}` };
  await saveSettings(prisma, { rateLimitPerMinute: 3 });
  const codes: number[] = [];
  for (let i = 0; i < 5; i += 1) {
    codes.push((await app.inject({ method: "GET", url: "/api/states/light.a", headers: limitedHeaders })).statusCode);
  }
  assert.deepEqual(codes.slice(0, 3), [200, 200, 200]);
  assert.deepEqual(codes.slice(3), [429, 429]);
  await resetSettings(prisma);
});
