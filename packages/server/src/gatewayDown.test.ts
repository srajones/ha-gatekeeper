import assert from "node:assert/strict";
import crypto from "node:crypto";
import net from "node:net";
import { after, test } from "node:test";
import cookie from "@fastify/cookie";
import secureSession from "@fastify/secure-session";
import Fastify from "fastify";
import { createTestDatabase } from "./testDb.js";

// Home Assistant is not there at all (nothing listens on its port): the gateway must stay up, say so
// clearly to callers and to the dashboard, and never hang.

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

// A port that is certainly closed: bind, note the number, release.
const closedPort: number = await new Promise((resolve) => {
  const probe = net.createServer().listen(0, "127.0.0.1", () => {
    const port = (probe.address() as net.AddressInfo).port;
    probe.close(() => resolve(port));
  });
});

process.env.NODE_ENV = "test";
process.env.HA_BASE_URL = `http://127.0.0.1:${closedPort}`;
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
const { startHaMonitor, stopHaMonitor, alertManager, probeHomeAssistant } = await import("./haMonitor.js");
const { resolveAlertConfig, setAlertConfigForTests } = await import("./alertConfig.js");
import http from "node:http";

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
  testDb.cleanup();
});

const key = await createTokenAccess(prisma, {
  name: "down",
  status: "active",
  permissions: [
    { kind: "state", entityIds: ["light.a"] },
    { kind: "service", domain: "light", services: ["turn_on"], entityIds: ["light.a"], allowNoEntity: false }
  ]
});
const headers = { authorization: `Bearer ${key.apiKey}` };

async function adminCookie(): Promise<string> {
  const login = await app.inject({ method: "POST", url: "/admin/login", payload: { password: process.env.ADMIN_PASSWORD } });
  const raw = login.headers["set-cookie"];
  return String(Array.isArray(raw) ? raw[0] : raw).split(";")[0]!;
}

test("Home Assistant unreachable, live link on: reads fail fast with 502, never hang, and the server stays up", async () => {
  startGateway();
  await sleep(300);
  assert.equal(haHub.isConnected(), false);
  const started = Date.now();
  const res = await app.inject({ method: "GET", url: "/api/states/light.a", headers });
  assert.equal(res.statusCode, 502);
  assert.equal(res.json().error, "ha_state_proxy_failed");
  assert.ok(Date.now() - started < 3000, `took ${Date.now() - started} ms`);
});

test("every read policy gives a clear answer when there is no data at all", async () => {
  for (const onLinkDown of ["live-then-last-known", "last-known", "error"] as const) {
    await saveSettings(prisma, { onLinkDown });
    const res = await app.inject({ method: "GET", url: "/api/states/light.a", headers });
    assert.ok([502, 503].includes(res.statusCode), `${onLinkDown} -> ${res.statusCode}`);
    assert.equal(res.json().ok, false);
  }
  await resetSettings(prisma);
});

test("the other state sources behave the same way: a clear 502", async () => {
  for (const stateSource of ["cache", "direct"] as const) {
    await saveSettings(prisma, { stateSource });
    const res = await app.inject({ method: "GET", url: "/api/states/light.a", headers });
    assert.equal(res.statusCode, 502, stateSource);
  }
  await resetSettings(prisma);
});

test("a service call to an unreachable Home Assistant is a 502, audited as a failure", async () => {
  const res = await app.inject({ method: "POST", url: "/api/services/light/turn_on", headers, payload: { entity_id: "light.a" } });
  assert.equal(res.statusCode, 502);
  const row = await prisma.auditLog.findFirst({ where: { actionIdRaw: "light.turn_on" }, orderBy: { timestamp: "desc" } });
  assert.equal(row?.success, false);
});

test("the dashboard says what is wrong: the connection report has the reason, the entity list 502s, and logging in still works", async () => {
  const cookieValue = await adminCookie();
  const status = (await app.inject({ method: "GET", url: "/admin/connection", headers: { cookie: cookieValue } })).json();
  assert.equal(status.live.connected, false);
  assert.ok(typeof status.live.lastError === "string" && status.live.lastError.length > 0, "a reason is given");
  assert.equal(status.live.running, true);
  const entities = await app.inject({ method: "GET", url: "/admin/ha/entities", headers: { cookie: cookieValue } });
  assert.equal(entities.statusCode, 502);
});

test("the live link keeps retrying quietly (backoff), it does not spin", async () => {
  const before = haHub.status().reconnects;
  await sleep(1500);
  assert.equal(haHub.status().reconnects, before, "no successful connection, and no busy loop either");
  assert.equal(haHub.status().running, true);
});

test("probe: every kind of failure is described in plain words", async () => {
  const reply = (status: number) => async () => new Response("x", { status });
  assert.deepEqual(await probeHomeAssistant(reply(200)), { up: true });
  assert.match((await probeHomeAssistant(reply(401))).reason!, /rejected the access token \(HTTP 401\)/);
  assert.match((await probeHomeAssistant(reply(403))).reason!, /rejected the access token/);
  assert.match((await probeHomeAssistant(reply(502))).reason!, /HTTP 502/);
  const refused = async () => { throw Object.assign(new TypeError("fetch failed"), { cause: { code: "ECONNREFUSED" } }); };
  assert.match((await probeHomeAssistant(refused)).reason!, /cannot connect to Home Assistant \(ECONNREFUSED\)/);
  const timeout = async () => { throw Object.assign(new Error("timed out"), { name: "TimeoutError" }); };
  assert.match((await probeHomeAssistant(timeout)).reason!, /no answer from Home Assistant within 8 s/);
  const real = await probeHomeAssistant();
  assert.equal(real.up, false);
  assert.match(real.reason!, /cannot connect/);
});

test("the monitor notices the outage by itself and the dashboard shows it, with no channel set up yet", async () => {
  setAlertConfigForTests(resolveAlertConfig({}));
  startHaMonitor();
  const start = Date.now();
  while (!alertManager.status().haDown) {
    if (Date.now() - start > 5000) throw new Error("the monitor did not notice");
    await sleep(50);
  }
  const cookieValue = await adminCookie();
  const view = (await app.inject({ method: "GET", url: "/admin/alerts", headers: { cookie: cookieValue } })).json();
  assert.equal(view.ok, true);
  assert.equal(view.state.haDown, true);
  assert.equal(view.state.alerted, false, "not yet: the delay has not passed");
  assert.deepEqual(view.channels.map((c: { configured: boolean }) => c.configured), [false, false, false, false]);
  const test = await app.inject({ method: "POST", url: "/admin/alerts/test", headers: { cookie: cookieValue } });
  assert.equal(test.statusCode, 409);
  assert.equal(test.json().error, "no_channels");
  const anonymous = await app.inject({ method: "GET", url: "/admin/alerts" });
  assert.equal(anonymous.statusCode, 401);
  assert.equal((await app.inject({ method: "POST", url: "/admin/alerts/test" })).statusCode, 401);
});

test("the test button sends through every configured channel and reports each result", async () => {
  const got: string[] = [];
  const web = http.createServer((req, res) => {
    let body = "";
    req.on("data", (c) => (body += c));
    req.on("end", () => { got.push(body); res.writeHead(req.url === "/bad" ? 500 : 200); res.end(); });
  });
  await new Promise<void>((resolve) => web.listen(0, "127.0.0.1", resolve));
  const port = (web.address() as { port: number }).port;
  setAlertConfigForTests(resolveAlertConfig({ ALERT_WEBHOOK_URL: `http://127.0.0.1:${port}/hook`, ALERT_NTFY_URL: `http://127.0.0.1:${port}/bad` }));
  const cookieValue = await adminCookie();
  const res = await app.inject({ method: "POST", url: "/admin/alerts/test", headers: { cookie: cookieValue } });
  web.close();
  assert.equal(res.statusCode, 200);
  const results = res.json().results as Array<{ channel: string; ok: boolean; error?: string }>;
  assert.deepEqual(results.map((r) => [r.channel, r.ok]).sort(), [["ntfy", false], ["webhook", true]]);
  assert.ok(got.some((b) => b.includes("Test alert")));
  const row = await prisma.auditLog.findFirst({ where: { actionIdRaw: "admin.alerts.test" }, orderBy: { timestamp: "desc" } });
  assert.equal(row?.success, false);
  assert.equal(row?.error, "ntfy");
  setAlertConfigForTests(null);
});
