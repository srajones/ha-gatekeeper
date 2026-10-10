import assert from "node:assert/strict";
import http from "node:http";
import { after, test } from "node:test";
import Fastify from "fastify";
import { createTestDatabase } from "./testDb.js";

const haCalls: string[] = [];
const fakeHaServer = http.createServer((req, res) => {
  haCalls.push(`${req.method} ${req.url}`);

  if (req.method === "POST" && req.url === "/api/services/light/turn_on") {
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify([{ entity_id: "light.living_room", state: "on" }]));
    return;
  }

  if (req.method === "GET" && req.url === "/api/states/sensor.temperature") {
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({ entity_id: "sensor.temperature", state: "21.5" }));
    return;
  }

  res.writeHead(404, { "content-type": "application/json" });
  res.end(JSON.stringify({ message: "not_found" }));
});

await new Promise<void>((resolve) => fakeHaServer.listen(0, "127.0.0.1", resolve));
const haPort = (fakeHaServer.address() as { port: number }).port;

process.env.NODE_ENV = "test";
process.env.HA_BASE_URL = `http://127.0.0.1:${haPort}`;
process.env.HA_TOKEN = "fake-ha-token";
process.env.ADMIN_PASSWORD = "admin-password-1234";
process.env.ADMIN_SESSION_SECRET = "12345678901234567890123456789012";
process.env.API_KEY_HASH_SECRET = "12345678901234567890123456789012";

const testDb = createTestDatabase();
process.env.DATABASE_URL = testDb.databaseUrl;

const { prisma } = await import("./db.js");
const { createTokenAccess } = await import("./tokenAccess.js");
const { publicApiRoutes } = await import("./publicApi.js");

const app = Fastify({ logger: false });
await app.register(publicApiRoutes, { prefix: "/api" });

const active = await createTokenAccess(prisma, {
  name: "Active Test Client",
  status: "active",
  permissions: [
    {
      kind: "service",
      domain: "light",
      services: ["turn_on"],
      entityIds: ["light.living_room"],
      allowNoEntity: false
    },
    { kind: "state", entityIds: ["sensor.temperature"] }
  ]
});

const disabledSeed = await createTokenAccess(prisma, {
  name: "Disabled Test Client",
  permissions: [{ kind: "state", entityIds: ["sensor.temperature"] }]
});
await prisma.client.update({ where: { id: disabledSeed.client.id }, data: { status: "disabled" } });

const serviceOnlySeed = await createTokenAccess(prisma, {
  name: "Service Only Test Client",
  permissions: [
    {
      kind: "service",
      domain: "light",
      services: ["turn_on"],
      entityIds: ["light.living_room"],
      allowNoEntity: false
    }
  ]
});

after(async () => {
  await app.close();
  await prisma.$disconnect();
  await new Promise<void>((resolve) => fakeHaServer.close(() => resolve()));
  testDb.cleanup();
});

function auditCount() {
  return prisma.auditLog.count();
}

test("rejects a request with no Authorization header", async () => {
  const before = await auditCount();
  const response = await app.inject({ method: "GET", url: "/api/states/sensor.temperature" });

  assert.equal(response.statusCode, 401);
  assert.deepEqual(response.json(), { ok: false, error: "missing_bearer_token" });
  assert.equal(await auditCount(), before + 1);
});

test("rejects a malformed Authorization header", async () => {
  const response = await app.inject({
    method: "GET",
    url: "/api/states/sensor.temperature",
    headers: { authorization: "Basic dXNlcjpwYXNz" }
  });

  assert.equal(response.statusCode, 401);
  assert.deepEqual(response.json(), { ok: false, error: "missing_bearer_token" });
});

test("rejects an invalid API key", async () => {
  const response = await app.inject({
    method: "GET",
    url: "/api/states/sensor.temperature",
    headers: { authorization: "Bearer not-a-real-key" }
  });

  assert.equal(response.statusCode, 401);
  assert.deepEqual(response.json(), { ok: false, error: "invalid_api_key" });
});

test("rejects a disabled client", async () => {
  const response = await app.inject({
    method: "GET",
    url: "/api/states/sensor.temperature",
    headers: { authorization: `Bearer ${disabledSeed.apiKey}` }
  });

  assert.equal(response.statusCode, 403);
  assert.deepEqual(response.json(), { ok: false, error: "client_disabled" });
});

test("rejects unsupported target selectors before calling Home Assistant", async () => {
  const callsBefore = haCalls.length;
  const response = await app.inject({
    method: "POST",
    url: "/api/services/light/turn_on",
    headers: { authorization: `Bearer ${active.apiKey}` },
    payload: { area_id: "living_room" }
  });

  assert.equal(response.statusCode, 403);
  assert.deepEqual(response.json(), { ok: false, error: "unsupported_target" });
  assert.equal(haCalls.length, callsBefore, "Home Assistant should never be called for a rejected target");
});

test("rejects a service call outside the granted domain/service", async () => {
  const response = await app.inject({
    method: "POST",
    url: "/api/services/light/turn_off",
    headers: { authorization: `Bearer ${active.apiKey}` },
    payload: { entity_id: "light.living_room" }
  });

  assert.equal(response.statusCode, 403);
  assert.deepEqual(response.json(), { ok: false, error: "forbidden" });
});

test("rejects a service call for an entity outside the permission", async () => {
  const response = await app.inject({
    method: "POST",
    url: "/api/services/light/turn_on",
    headers: { authorization: `Bearer ${active.apiKey}` },
    payload: { entity_id: "light.bedroom" }
  });

  assert.equal(response.statusCode, 403);
  assert.deepEqual(response.json(), { ok: false, error: "entity_not_allowed" });
});

test("proxies a successful service call and passes through the Home Assistant response", async () => {
  const before = await auditCount();
  const response = await app.inject({
    method: "POST",
    url: "/api/services/light/turn_on",
    headers: { authorization: `Bearer ${active.apiKey}` },
    payload: { entity_id: "light.living_room" }
  });

  assert.equal(response.statusCode, 200);
  assert.match(String(response.headers["content-type"]), /^application\/json/);
  assert.deepEqual(response.json(), [{ entity_id: "light.living_room", state: "on" }]);

  const logs = await prisma.auditLog.findMany({
    where: { actionIdRaw: "light.turn_on", clientId: active.client.id },
    orderBy: { timestamp: "desc" },
    take: 1
  });
  assert.equal(await auditCount(), before + 1);
  assert.equal(logs.length, 1);
  assert.equal(logs[0].success, true);
  assert.equal(logs[0].error, null);
});

test("rejects a state read for an entity outside the permission", async () => {
  const response = await app.inject({
    method: "GET",
    url: "/api/states/sensor.humidity",
    headers: { authorization: `Bearer ${active.apiKey}` }
  });

  assert.equal(response.statusCode, 403);
  assert.deepEqual(response.json(), { ok: false, error: "entity_not_allowed" });
});

test("rejects a state read for a client with no state permission at all", async () => {
  const response = await app.inject({
    method: "GET",
    url: "/api/states/sensor.temperature",
    headers: { authorization: `Bearer ${serviceOnlySeed.apiKey}` }
  });

  assert.equal(response.statusCode, 403);
  assert.deepEqual(response.json(), { ok: false, error: "forbidden" });
});

test("proxies a successful state read and passes through the Home Assistant response", async () => {
  const before = await auditCount();
  const response = await app.inject({
    method: "GET",
    url: "/api/states/sensor.temperature",
    headers: { authorization: `Bearer ${active.apiKey}` }
  });

  assert.equal(response.statusCode, 200);
  assert.match(String(response.headers["content-type"]), /^application\/json/);
  assert.deepEqual(response.json(), { entity_id: "sensor.temperature", state: "21.5" });

  const logs = await prisma.auditLog.findMany({
    where: { actionIdRaw: "states.sensor.temperature", clientId: active.client.id },
    orderBy: { timestamp: "desc" },
    take: 1
  });
  assert.equal(await auditCount(), before + 1);
  assert.equal(logs.length, 1);
  assert.equal(logs[0].success, true);
});

test("serves an OpenAPI document describing the public routes", async () => {
  const response = await app.inject({ method: "GET", url: "/api/documentation/json" });

  assert.equal(response.statusCode, 200);
  const doc = response.json();
  assert.equal(doc.info.title, "HA Gatekeeper Public API");
  assert.deepEqual(Object.keys(doc.paths).sort(), [
    "/api/capabilities",
    "/api/services/{domain}/{service}",
    "/api/states/{entityId}"
  ]);
});

test("serves the Swagger UI page", async () => {
  const response = await app.inject({ method: "GET", url: "/api/documentation/" });

  assert.equal(response.statusCode, 200);
  assert.match(String(response.headers["content-type"]), /^text\/html/);
});

test("many simultaneous state reads cost Home Assistant one request, and a service call refreshes the state", async () => {
  const headers = { authorization: `Bearer ${active.apiKey}` };
  const stateReads = () => haCalls.filter((call) => call === "GET /api/states/sensor.temperature").length;

  // Another test may have filled the cache already; a service call empties it.
  await app.inject({
    method: "POST",
    url: "/api/services/light/turn_on",
    headers,
    payload: { entity_id: "light.living_room" }
  });

  const before = stateReads();
  const responses = await Promise.all(
    Array.from({ length: 30 }, () => app.inject({ method: "GET", url: "/api/states/sensor.temperature", headers }))
  );
  assert.ok(responses.every((response) => response.statusCode === 200));
  assert.equal(stateReads() - before, 1);

  // Within the cache window the next read is served without asking Home Assistant again.
  await app.inject({ method: "GET", url: "/api/states/sensor.temperature", headers });
  assert.equal(stateReads() - before, 1);

  // After a service call the next read goes to Home Assistant again (read-your-writes).
  await app.inject({
    method: "POST",
    url: "/api/services/light/turn_on",
    headers,
    payload: { entity_id: "light.living_room" }
  });
  await app.inject({ method: "GET", url: "/api/states/sensor.temperature", headers });
  assert.equal(stateReads() - before, 2);
});
