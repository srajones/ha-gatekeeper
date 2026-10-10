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
