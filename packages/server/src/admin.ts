import type { FastifyPluginAsync, FastifyReply, FastifyRequest } from "fastify";
import rateLimit from "@fastify/rate-limit";
import { prisma } from "./db.js";
import { env } from "./env.js";
import { fetchHaEntities, fetchHaServices, gatewayStatus } from "./ha.js";
import { requestHubResubscribe } from "./hubRuntime.js";
import { SETTINGS_HELP, defaultSettings, getSettings, parseSettingsPatch, resetSettings, saveSettings } from "./settings.js";
import {
  auditQuerySchema,
  createClientSchema,
  loginSchema,
  quickSetupSchema,
  updateClientPermissionsSchema,
  updateClientSchema
} from "./schemas.js";
import { parsePermission } from "./permissions.js";
import { createTokenAccess, replaceTokenPermissions } from "./tokenAccess.js";
import { generateApiKey, timingSafeEqual } from "./security.js";
import { isAdminAuthenticated, isAdminLoginAllowed, isTrustedIngressRequest } from "./adminAuth.js";
import { logAudit } from "./audit.js";
import { rateLimitErrorResponseBuilder } from "./rateLimit.js";

function sendUnauthorized(reply: FastifyReply) {
  return reply.status(401).send({ ok: false, error: "unauthorized" });
}

function ensureAdmin(request: FastifyRequest, reply: FastifyReply) {
  const isAuthed = getAdminAuthenticated(request);
  if (!isAuthed) {
    sendUnauthorized(reply);
    return false;
  }
  return true;
}

function getAdminAuthenticated(request: FastifyRequest): boolean {
  return isAdminAuthenticated({
    addonMode: env.HA_GATEKEEPER_ADDON,
    sessionAdmin: request.session.get("admin") === true,
    ip: request.ip,
    headers: request.headers
  });
}

function normalizePermission(permission: any) {
  return parsePermission(permission);
}

function normalizeClient(client: any) {
  return {
    id: client.id,
    name: client.name,
    status: client.status,
    apiKeyPrefix: client.apiKeyPrefix,
    createdAt: client.createdAt,
    permissions: (client.permissions ?? []).map(normalizePermission).filter(Boolean)
  };
}

export const adminRoutes: FastifyPluginAsync = async (app) => {
  let haServiceCache: { data: Awaited<ReturnType<typeof fetchHaServices>>; expiresAt: number } | null =
    null;
  let haEntityCache: { data: Awaited<ReturnType<typeof fetchHaEntities>>; expiresAt: number } | null =
    null;

  // Scoped to this plugin (not global) so only routes that opt in via `config.rateLimit`
  // are limited. Trusted-ingress requests are allow-listed: in add-on mode every browser
  // request arrives via HA Supervisor's fixed proxy IP, so without this carve-out unrelated
  // users on the same Home Assistant instance would share one rate-limit bucket.
  await app.register(rateLimit, {
    global: false,
    allowList: (request) =>
      isTrustedIngressRequest({
        addonMode: env.HA_GATEKEEPER_ADDON,
        ip: request.ip,
        headers: request.headers
      }),
    errorResponseBuilder: rateLimitErrorResponseBuilder
  });

  app.post(
    "/login",
    { config: { rateLimit: { max: 10, timeWindow: "1 minute" } } },
    async (request, reply) => {
      const ip = request.ip ?? null;
      const loginAllowed = isAdminLoginAllowed({
        addonMode: env.HA_GATEKEEPER_ADDON,
        sessionAdmin: request.session.get("admin") === true,
        ip: request.ip,
        headers: request.headers
      });
      if (!loginAllowed) {
        await logAudit(request.log, {
          clientId: null,
          permissionId: null,
          actionIdRaw: "admin.login",
          ip,
          success: false,
          error: "unauthorized"
        });
        return sendUnauthorized(reply);
      }

      if (env.HA_GATEKEEPER_ADDON) {
        request.session.set("admin", true);
        await logAudit(request.log, {
          clientId: null,
          permissionId: null,
          actionIdRaw: "admin.login",
          ip,
          success: true
        });
        return reply.send({ ok: true });
      }

      const parsed = loginSchema.safeParse(request.body ?? {});
      if (!parsed.success) {
        await logAudit(request.log, {
          clientId: null,
          permissionId: null,
          actionIdRaw: "admin.login",
          ip,
          success: false,
          error: "invalid_body"
        });
        return reply.status(400).send({ ok: false, error: "invalid_body" });
      }

      if (!timingSafeEqual(parsed.data.password, env.ADMIN_PASSWORD)) {
        await logAudit(request.log, {
          clientId: null,
          permissionId: null,
          actionIdRaw: "admin.login",
          ip,
          success: false,
          error: "invalid_credentials"
        });
        return reply.status(401).send({ ok: false, error: "invalid_credentials" });
      }

      request.session.set("admin", true);
      await logAudit(request.log, {
        clientId: null,
        permissionId: null,
        actionIdRaw: "admin.login",
        ip,
        success: true
      });
      return reply.send({ ok: true });
    }
  );

  app.post("/logout", async (request, reply) => {
    request.session.delete();
    await logAudit(request.log, {
      clientId: null,
      permissionId: null,
      actionIdRaw: "admin.logout",
      ip: request.ip ?? null,
      success: true
    });
    return reply.send({ ok: true });
  });

  app.get("/me", async (request) => ({
    authenticated: getAdminAuthenticated(request),
    addonMode: env.HA_GATEKEEPER_ADDON
  }));

  app.get("/ha/services", async (request, reply) => {
    if (!ensureAdmin(request, reply)) {
      return;
    }

    const now = Date.now();
    if (haServiceCache && haServiceCache.expiresAt > now) {
      return reply.send({ ok: true, services: haServiceCache.data, cached: true });
    }

    try {
      const services = await fetchHaServices();
      haServiceCache = { data: services, expiresAt: now + 60_000 };
      return reply.send({ ok: true, services, cached: false });
    } catch (err) {
      request.log.error({ err }, "ha_services_failed");
      return reply.status(502).send({ ok: false, error: "ha_services_failed" });
    }
  });

  app.get("/ha/entities", async (request, reply) => {
    if (!ensureAdmin(request, reply)) {
      return;
    }

    const now = Date.now();
    if (!haEntityCache || haEntityCache.expiresAt <= now) {
      try {
        const entities = await fetchHaEntities();
        haEntityCache = { data: entities, expiresAt: now + 60_000 };
      } catch (err) {
        request.log.error({ err }, "ha_entities_failed");
        return reply.status(502).send({ ok: false, error: "ha_entities_failed" });
      }
    }

    const domain =
      typeof request.query === "object" ? (request.query as { domain?: string }).domain : undefined;
    const payload = domain
      ? haEntityCache.data.filter((entity) => entity.domain === domain)
      : haEntityCache.data;

    return reply.send({ ok: true, entities: payload, cached: true });
  });

  app.get("/clients", async (request, reply) => {
    if (!ensureAdmin(request, reply)) {
      return;
    }

    const clients = await prisma.client.findMany({
      include: { permissions: true },
      orderBy: { createdAt: "desc" }
    });

    return reply.send({ ok: true, clients: clients.map(normalizeClient) });
  });

  app.post("/clients", async (request, reply) => {
    if (!ensureAdmin(request, reply)) {
      return;
    }

    const parsed = createClientSchema.safeParse(request.body ?? {});
    if (!parsed.success) {
      return reply.status(400).send({ ok: false, error: "invalid_body" });
    }

    const result = await createTokenAccess(prisma, parsed.data);

    await logAudit(request.log, {
      clientId: result.client.id,
      permissionId: null,
      actionIdRaw: "admin.client.create",
      ip: request.ip ?? null,
      success: true
    });

    return reply.send({
      ok: true,
      client: normalizeClient(result.client),
      apiKey: result.apiKey
    });
  });

  app.post("/quick-setup", async (request, reply) => {
    if (!ensureAdmin(request, reply)) {
      return;
    }

    const parsed = quickSetupSchema.safeParse(request.body ?? {});
    if (!parsed.success) {
      return reply.status(400).send({ ok: false, error: "invalid_body" });
    }

    const result = await createTokenAccess(prisma, {
      name: parsed.data.name,
      permissions: parsed.data.permissions
    });

    await logAudit(request.log, {
      clientId: result.client.id,
      permissionId: null,
      actionIdRaw: "admin.client.quick_setup",
      ip: request.ip ?? null,
      success: true
    });

    return reply.send({
      ok: true,
      client: normalizeClient(result.client),
      apiKey: result.apiKey
    });
  });

  app.patch("/clients/:id", async (request, reply) => {
    if (!ensureAdmin(request, reply)) {
      return;
    }

    const parsed = updateClientSchema.safeParse(request.body ?? {});
    if (!parsed.success) {
      return reply.status(400).send({ ok: false, error: "invalid_body" });
    }

    const clientId = (request.params as { id: string }).id;
    const client = await prisma.client.update({
      where: { id: clientId },
      data: {
        name: parsed.data.name,
        status: parsed.data.status
      },
      include: { permissions: true }
    });

    await logAudit(request.log, {
      clientId: client.id,
      permissionId: null,
      actionIdRaw: "admin.client.update",
      ip: request.ip ?? null,
      success: true
    });

    return reply.send({ ok: true, client: normalizeClient(client) });
  });

  app.patch("/clients/:id/permissions", async (request, reply) => {
    if (!ensureAdmin(request, reply)) {
      return;
    }

    const parsed = updateClientPermissionsSchema.safeParse(request.body ?? {});
    if (!parsed.success) {
      return reply.status(400).send({ ok: false, error: "invalid_body" });
    }

    const clientId = (request.params as { id: string }).id;
    const client = await replaceTokenPermissions(prisma, clientId, parsed.data.permissions);
    if (!client) {
      return reply.status(404).send({ ok: false, error: "client_not_found" });
    }

    await logAudit(request.log, {
      clientId: client.id,
      permissionId: null,
      actionIdRaw: "admin.client.permissions.update",
      ip: request.ip ?? null,
      success: true
    });

    return reply.send({ ok: true, client: normalizeClient(client) });
  });

  app.post("/clients/:id/rotate-key", async (request, reply) => {
    if (!ensureAdmin(request, reply)) {
      return;
    }

    const clientId = (request.params as { id: string }).id;
    const { apiKey, apiKeyHash, apiKeyPrefix } = generateApiKey();

    const client = await prisma.client.update({
      where: { id: clientId },
      data: { apiKeyHash, apiKeyPrefix },
      include: { permissions: true }
    });

    await logAudit(request.log, {
      clientId: client.id,
      permissionId: null,
      actionIdRaw: "admin.client.rotate_key",
      ip: request.ip ?? null,
      success: true
    });

    return reply.send({ ok: true, client: normalizeClient(client), apiKey });
  });

  // The live Home Assistant connection watches exactly the entities that active keys may read.
  // Anything that can change that set triggers a reconnect with the new list.
  app.addHook("onResponse", async (request, reply) => {
    const changesKeys =
      request.method !== "GET" &&
      reply.statusCode < 400 &&
      (request.url.startsWith("/admin/clients") || request.url.startsWith("/admin/quick-setup"));
    if (changesKeys) {
      requestHubResubscribe();
    }
  });

  app.get("/settings", async (request, reply) => {
    if (!ensureAdmin(request, reply)) {
      return;
    }
    return reply.send({ ok: true, settings: getSettings(), defaults: defaultSettings(), help: SETTINGS_HELP });
  });

  app.put("/settings", async (request, reply) => {
    if (!ensureAdmin(request, reply)) {
      return;
    }
    const parsed = parseSettingsPatch(request.body ?? {});
    if (!parsed.ok) {
      return reply.status(400).send({ ok: false, error: "invalid_settings", details: parsed.errors });
    }
    const before = getSettings();
    const settings = await saveSettings(prisma, parsed.patch);
    const changed = (Object.keys(parsed.patch) as Array<keyof typeof settings>).filter((key) => before[key] !== settings[key]);
    await logAudit(request.log, {
      clientId: null,
      permissionId: null,
      actionIdRaw: "admin.settings.update",
      ip: request.ip ?? null,
      success: true,
      error: changed.length > 0 ? `changed:${changed.join(",")}` : null
    });
    return reply.send({ ok: true, settings });
  });

  app.post("/settings/reset", async (request, reply) => {
    if (!ensureAdmin(request, reply)) {
      return;
    }
    const settings = await resetSettings(prisma);
    await logAudit(request.log, {
      clientId: null,
      permissionId: null,
      actionIdRaw: "admin.settings.reset",
      ip: request.ip ?? null,
      success: true
    });
    return reply.send({ ok: true, settings });
  });

  app.get("/connection", async (request, reply) => {
    if (!ensureAdmin(request, reply)) {
      return;
    }
    return reply.send({ ok: true, ...gatewayStatus() });
  });

  app.delete("/clients/:id", async (request, reply) => {
    if (!ensureAdmin(request, reply)) {
      return;
    }

    const clientId = (request.params as { id: string }).id;

    try {
      await prisma.$transaction([
        prisma.auditLog.updateMany({
          where: { clientId },
          data: { clientId: null }
        }),
        prisma.client.delete({ where: { id: clientId } })
      ]);
    } catch (err) {
      request.log.error({ err }, "client_delete_failed");
      return reply.status(400).send({ ok: false, error: "client_delete_failed" });
    }

    // clientId is intentionally null here: the client row no longer exists, and AuditLog.clientId
    // has a foreign key to Client.id, so logging with the deleted id would violate the constraint.
    // The deleted id is preserved in `error` instead so it's still recoverable in the trail.
    await logAudit(request.log, {
      clientId: null,
      permissionId: null,
      actionIdRaw: "admin.client.delete",
      ip: request.ip ?? null,
      success: true,
      error: `deleted_client:${clientId}`
    });

    return reply.send({ ok: true });
  });

  app.get("/audit-logs", async (request, reply) => {
    if (!ensureAdmin(request, reply)) {
      return;
    }

    const parsed = auditQuerySchema.safeParse(request.query ?? {});
    if (!parsed.success) {
      return reply.status(400).send({ ok: false, error: "invalid_query" });
    }

    const logs = await prisma.auditLog.findMany({
      include: { client: true, permission: true },
      orderBy: { timestamp: "desc" },
      take: parsed.data.limit,
      skip: parsed.data.offset
    });

    const payload = logs.map((log: any) => ({
      id: log.id,
      timestamp: log.timestamp,
      success: log.success,
      error: log.error,
      ip: log.ip,
      clientId: log.clientId,
      clientName: log.client?.name ?? null,
      permissionId: log.permissionId,
      permission: log.permission ? normalizePermission(log.permission) : null,
      actionIdRaw: log.actionIdRaw
    }));

    return reply.send({ ok: true, logs: payload });
  });
};
