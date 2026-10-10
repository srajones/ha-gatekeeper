import Fastify from "fastify";
import cors from "@fastify/cors";
import helmet from "@fastify/helmet";
import cookie from "@fastify/cookie";
import secureSession from "@fastify/secure-session";
import staticPlugin from "@fastify/static";
import path from "node:path";
import fs from "node:fs";
import crypto from "node:crypto";
import { fileURLToPath } from "node:url";
import { env, isProd } from "./env.js";
import { prisma } from "./db.js";
import { adminRoutes } from "./admin.js";
import { publicApiRoutes } from "./publicApi.js";
import { startGateway, stopGateway } from "./ha.js";
import { startHaMonitor, stopHaMonitor } from "./haMonitor.js";
import { setHubLogger } from "./hubRuntime.js";
import { loadSettings } from "./settings.js";
import { DatabaseHealth } from "./health.js";

// Fastify 5 no longer takes a hop count directly; trust the first N addresses from the socket.
const trustProxy =
  typeof env.TRUST_PROXY === "number" ? (_address: string, hop: number) => hop < Number(env.TRUST_PROXY) : env.TRUST_PROXY;

const app = Fastify({ logger: true, trustProxy });
setHubLogger({ info: (message) => app.log.info(message), warn: (message) => app.log.warn(message) });
await loadSettings(prisma);
app.addHook("onClose", async () => {
  stopHaMonitor();
  await stopGateway();
});

await app.register(cors, {
  origin: env.CORS_ORIGIN,
  credentials: true
});

// HSTS is disabled: many self-hosted Home Assistant instances are reached over plain HTTP
// or self-signed TLS, and pinning the host to HTTPS-only for a year is a bad footgun for a
// LAN gateway. Every other helmet default (CSP, frame-ancestors, etc.) is safe as-is here.
await app.register(helmet, { hsts: false });

await app.register(cookie);

let sessionKey = Buffer.from(env.ADMIN_SESSION_SECRET, "base64");
if (sessionKey.length !== 32) {
  sessionKey = Buffer.from(env.ADMIN_SESSION_SECRET, "utf8");
}
if (sessionKey.length !== 32) {
  sessionKey = crypto.createHash("sha256").update(env.ADMIN_SESSION_SECRET).digest();
  app.log.warn("ADMIN_SESSION_SECRET was not 32 bytes; derived key via sha256");
}

await app.register(secureSession, {
  key: sessionKey,
  cookieName: "hgk_admin",
  cookie: {
    path: "/",
    httpOnly: true,
    sameSite: "lax",
    secure: isProd
  }
});

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const webDist = path.join(__dirname, "../../web/dist");

if (fs.existsSync(webDist)) {
  await app.register(staticPlugin, {
    root: webDist,
    prefix: "/"
  });
}

// Health for Docker and the watchdog. It must NOT depend on Home Assistant (a Home Assistant outage is not a
// reason to restart this server) but it does check what this server cannot work without: its database (see health.ts).
app.get("/healthz", async (_request, reply) => {
  const db = await dbHealth.quick();
  if (db.ok) {
    return { ok: true };
  }
  return reply.status(503).send({ ok: false, error: "database" });
});

await app.register(publicApiRoutes, { prefix: "/api" });
await app.register(adminRoutes, { prefix: "/admin" });

app.setNotFoundHandler((request, reply) => {
  if (
    request.raw.url?.startsWith("/api/") ||
    request.raw.url?.startsWith("/v1/") ||
    request.raw.url?.startsWith("/admin/")
  ) {
    return reply.status(404).send({ ok: false, error: "not_found" });
  }

  if (fs.existsSync(webDist)) {
    return reply.sendFile("index.html");
  }

  return reply.status(404).send({ ok: false, error: "not_found" });
});

async function pruneAuditLogs() {
  if (env.AUDIT_LOG_RETENTION_DAYS <= 0) {
    return;
  }

  const cutoff = new Date(Date.now() - env.AUDIT_LOG_RETENTION_DAYS * 86_400_000);
  try {
    await prisma.auditLog.deleteMany({ where: { timestamp: { lt: cutoff } } });
  } catch (err) {
    app.log.error({ err }, "audit_log_prune_failed");
  }
}

const dbHealth = new DatabaseHealth({
  read: () => prisma.setting.count(),
  write: () =>
    prisma.setting.upsert({
      where: { key: "health.ping" },
      create: { key: "health.ping", value: String(Date.now()) },
      update: { value: String(Date.now()), updatedAt: new Date() }
    })
});

// Self-healing: if the database fails its read/write check three times in a row (about 90 s), exit so Docker
// (restart policy) starts a fresh process right away, without waiting for the host watchdog.
setInterval(async () => {
  const result = await dbHealth.full();
  if (result.ok) {
    return;
  }
  app.log.error({ failures: dbHealth.consecutiveFailures, error: result.error }, "database_check_failed");
  if (dbHealth.consecutiveFailures >= 3) {
    app.log.fatal("database failing for about 90 s: exiting so Docker restarts the process");
    process.exit(1);
  }
}, 30_000).unref();

// `docker stop` / restart: finish in-flight requests and close the database cleanly, but never hang.
let shuttingDown = false;
for (const signal of ["SIGTERM", "SIGINT"] as const) {
  process.on(signal, () => {
    if (shuttingDown) return;
    shuttingDown = true;
    app.log.info({ signal }, "shutting_down");
    setTimeout(() => process.exit(0), 8000).unref();
    app.close().then(() => prisma.$disconnect()).finally(() => process.exit(0));
  });
}

process.on("uncaughtException", (err) => {
  app.log.fatal({ err }, "uncaught_exception: exiting so Docker restarts the process");
  process.exit(1);
});
process.on("unhandledRejection", (err) => {
  app.log.fatal({ err }, "unhandled_rejection: exiting so Docker restarts the process");
  process.exit(1);
});

const start = async () => {
  try {
    await pruneAuditLogs();
    await app.listen({ port: env.PORT, host: "0.0.0.0" });
    startGateway();
    startHaMonitor();
  } catch (err) {
    app.log.error(err);
    process.exit(1);
  }
};

start();
