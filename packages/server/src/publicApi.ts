import type { FastifyPluginAsync } from "fastify";
import rateLimit from "@fastify/rate-limit";
import swagger from "@fastify/swagger";
import swaggerUi from "@fastify/swagger-ui";
import { prisma } from "./db.js";
import { env } from "./env.js";
import { HaUnavailableError, proxyHaServiceCall, proxyHaState } from "./ha.js";
import { getSettings } from "./settings.js";
import { HaBusyError } from "./haGateway.js";
import { asServiceRequestBody, extractRequestedEntityIds } from "./policy.js";
import { findAllowedServicePermission, findAllowedStatePermission } from "./permissions.js";
import { getApiKeyPrefix, hashApiKey, timingSafeEqual } from "./security.js";
import { buildCapabilitiesResponse } from "./capabilities.js";
import { resolvePublicApiClient, readBearerToken, type PublicApiClient } from "./publicAuth.js";
import { isPublicApiAllowed } from "./adminAuth.js";
import { logAudit } from "./audit.js";
import { rateLimitErrorResponseBuilder } from "./rateLimit.js";

// The per-key limit is an option in the dashboard (Settings), read on every request.
const publicApiRateLimit = { max: () => getSettings().rateLimitPerMinute, timeWindow: "1 minute" };

async function findClientByApiKey(apiKey: string): Promise<PublicApiClient | null> {
  const prefix = getApiKeyPrefix(apiKey);
  const candidates = await prisma.client.findMany({
    where: { apiKeyPrefix: prefix },
    include: { permissions: true }
  });
  const computedHash = hashApiKey(apiKey);

  return candidates.find((candidate: any) => timingSafeEqual(computedHash, candidate.apiKeyHash)) ?? null;
}

function getAuthorizationHeader(headers: Record<string, string | string[] | undefined>): string | undefined {
  const authorization = headers.authorization;
  return Array.isArray(authorization) ? authorization[0] : authorization;
}

export const publicApiRoutes: FastifyPluginAsync = async (app) => {
  app.addHook("onRequest", async (request, reply) => {
    if (isPublicApiAllowed({ addonMode: env.HA_GATEKEEPER_ADDON, exposeApi: env.ADDON_EXPOSE_API })) {
      return;
    }

    return reply.status(403).send({ ok: false, error: "api_not_exposed" });
  });

  // Registered after the gate above so the docs UI and spec are only reachable under the
  // same conditions as the API itself (addon mode with expose_api on, or standalone mode).
  await app.register(swagger, {
    openapi: {
      info: {
        title: "HA Gatekeeper Public API",
        description: "Scoped Home Assistant service calls and state reads for trusted LAN agents.",
        version: "1.0.0"
      },
      components: {
        securitySchemes: {
          bearerAuth: {
            type: "http",
            scheme: "bearer",
            description: "Gatekeeper token issued from the admin UI."
          }
        }
      },
      security: [{ bearerAuth: [] }]
    }
  });

  await app.register(swaggerUi, {
    routePrefix: "/documentation"
  });

  app.addSchema({
    $id: "publicApiError",
    type: "object",
    properties: {
      ok: { type: "boolean", const: false },
      error: { type: "string" }
    }
  });

  // Keyed by bearer-token prefix (not raw IP) so distinct API clients behind the same
  // NAT/router get independent buckets. Falls back to IP only when no token is present at all.
  await app.register(rateLimit, {
    global: false,
    keyGenerator: (request) => {
      const authorization = getAuthorizationHeader(request.headers);
      const token = readBearerToken(authorization);
      return token ? `token:${getApiKeyPrefix(token)}` : `ip:${request.ip}`;
    },
    errorResponseBuilder: rateLimitErrorResponseBuilder
  });

  app.get(
    "/capabilities",
    {
      config: { rateLimit: publicApiRateLimit },
      schema: {
        tags: ["Gatekeeper API"],
        summary: "List the service calls and state reads this token is allowed to perform",
        security: [{ bearerAuth: [] }],
        response: {
          200: {
            type: "object",
            properties: {
              ok: { type: "boolean" },
              client: {
                type: "object",
                properties: {
                  id: { type: "string" },
                  name: { type: "string" },
                  status: { type: "string" }
                }
              },
              capabilities: {
                type: "object",
                properties: {
                  serviceActions: {
                    type: "array",
                    items: {
                      type: "object",
                      properties: {
                        domain: { type: "string" },
                        service: { type: "string" },
                        entityIds: { type: "array", items: { type: "string" } },
                        allowNoEntity: { type: "boolean" }
                      }
                    }
                  },
                  stateReads: { type: "array", items: { type: "string" } },
                  unsupportedTargets: { type: "array", items: { type: "string" } }
                }
              }
            }
          },
          401: { $ref: "publicApiError#" },
          403: { $ref: "publicApiError#" }
        }
      }
    },
    async (request, reply) => {
    const authorization = getAuthorizationHeader(request.headers);
    const auth = await resolvePublicApiClient(authorization, findClientByApiKey);
    const ip = request.ip ?? null;

    if (!auth.ok) {
      await logAudit(request.log, {
        clientId: auth.clientId,
        permissionId: null,
        actionIdRaw: "capabilities.read",
        ip,
        success: false,
        error: auth.error
      });
      return reply.status(auth.status).send({ ok: false, error: auth.error });
    }

    await logAudit(request.log, {
      clientId: auth.client.id,
      permissionId: null,
      actionIdRaw: "capabilities.read",
      ip,
      success: true
    });

    return buildCapabilitiesResponse(auth.client);
  });

  app.post(
    "/services/:domain/:service",
    {
      config: { rateLimit: publicApiRateLimit },
      schema: {
        tags: ["Gatekeeper API"],
        summary: "Call a Home Assistant service, scoped to this token's allowed entities",
        security: [{ bearerAuth: [] }],
        params: {
          type: "object",
          required: ["domain", "service"],
          properties: {
            domain: { type: "string", description: "Home Assistant domain, e.g. light" },
            service: { type: "string", description: "Service name, e.g. turn_on" }
          }
        },
        body: {
          type: "object",
          description:
            "Same shape as Home Assistant's own service-call body. entity_id (string or array) " +
            "or target.entity_id must be within the token's allowed entities; area/device/floor/label " +
            "targets are rejected. Additional service-specific fields (brightness, color, etc.) are " +
            "forwarded as-is.",
          properties: {
            entity_id: {
              anyOf: [{ type: "string" }, { type: "array", items: { type: "string" } }]
            },
            target: {
              type: "object",
              properties: {
                entity_id: {
                  anyOf: [{ type: "string" }, { type: "array", items: { type: "string" } }]
                }
              }
            }
          },
          additionalProperties: true
        },
        response: {
          400: { $ref: "publicApiError#" },
          401: { $ref: "publicApiError#" },
          403: { $ref: "publicApiError#" },
          502: { $ref: "publicApiError#" },
          503: { $ref: "publicApiError#" }
        }
      }
    },
    async (request, reply) => {
      const { domain, service } = request.params as { domain: string; service: string };
      const actionIdRaw = `${domain}.${service}`;
      const ip = request.ip ?? null;

      const authorization = getAuthorizationHeader(request.headers);
      const auth = await resolvePublicApiClient(authorization, findClientByApiKey);

      if (!auth.ok) {
        await logAudit(request.log, {
          clientId: auth.clientId,
          permissionId: null,
          actionIdRaw,
          ip,
          success: false,
          error: auth.error
        });
        return reply.status(auth.status).send({ ok: false, error: auth.error });
      }

      const client = auth.client;

      const body = asServiceRequestBody(request.body);
      if (!body) {
        await logAudit(request.log, {
          clientId: client.id,
          permissionId: null,
          actionIdRaw,
          ip,
          success: false,
          error: "invalid_body"
        });
        return reply.status(400).send({ ok: false, error: "invalid_body" });
      }

      const entityExtraction = extractRequestedEntityIds(body);
      if (!entityExtraction.ok) {
        await logAudit(request.log, {
          clientId: client.id,
          permissionId: null,
          actionIdRaw,
          ip,
          success: false,
          error: entityExtraction.error
        });
        return reply.status(403).send({ ok: false, error: entityExtraction.error });
      }

      const matchedPermission = findAllowedServicePermission(
        client.permissions,
        domain,
        service,
        entityExtraction.entityIds
      );

      if (!matchedPermission.ok) {
        await logAudit(request.log, {
          clientId: client.id,
          permissionId: null,
          actionIdRaw,
          ip,
          success: false,
          error: matchedPermission.error
        });
        return reply.status(403).send({ ok: false, error: matchedPermission.error });
      }

      try {
        const queryIndex = request.url.indexOf("?");
        const queryString = queryIndex >= 0 ? request.url.slice(queryIndex) : "";
        const haResponse = await proxyHaServiceCall(domain, service, body, queryString);

        await logAudit(request.log, {
          clientId: client.id,
          permissionId: matchedPermission.permission.id,
          actionIdRaw,
          ip,
          success: haResponse.ok,
          error: haResponse.ok ? null : `ha_request_failed:${haResponse.status}`
        });

        if (haResponse.contentType) {
          reply.header("content-type", haResponse.contentType);
        }
        // Home Assistant's status is passed through as-is; Fastify 5 types only the schema's codes.
        return reply.status(haResponse.status as never).send(haResponse.body as never);
      } catch (err) {
        const message = err instanceof Error ? err.message : "unknown_error";
        await logAudit(request.log, {
          clientId: client.id,
          permissionId: matchedPermission.permission.id,
          actionIdRaw,
          ip,
          success: false,
          error: message
        });

        if (err instanceof HaBusyError) {
          return reply.header("retry-after", "1").status(503).send({ ok: false, error: "ha_busy" });
        }
        request.log.error({ err }, "ha_proxy_failed");
        return reply.status(502).send({ ok: false, error: "ha_proxy_failed" });
      }
    }
  );

  app.get(
    "/states/:entityId",
    {
      config: { rateLimit: publicApiRateLimit },
      schema: {
        tags: ["Gatekeeper API"],
        summary: "Read a single entity's state, if this token is allowed to read it",
        security: [{ bearerAuth: [] }],
        params: {
          type: "object",
          required: ["entityId"],
          properties: {
            entityId: { type: "string", description: "e.g. sensor.temperature" }
          }
        },
        response: {
          401: { $ref: "publicApiError#" },
          403: { $ref: "publicApiError#" },
          502: { $ref: "publicApiError#" },
          503: { $ref: "publicApiError#" }
        }
      }
    },
    async (request, reply) => {
    const { entityId } = request.params as { entityId: string };
    const actionIdRaw = `states.${entityId}`;
    const ip = request.ip ?? null;

    const authorization = getAuthorizationHeader(request.headers);
    const auth = await resolvePublicApiClient(authorization, findClientByApiKey);

    if (!auth.ok) {
      await logAudit(request.log, {
        clientId: auth.clientId,
        permissionId: null,
        actionIdRaw,
        ip,
        success: false,
        error: auth.error
      });
      return reply.status(auth.status).send({ ok: false, error: auth.error });
    }

    const client = auth.client;

    const matchedPermission = findAllowedStatePermission(client.permissions, entityId);
    if (!matchedPermission.ok) {
      await logAudit(request.log, {
        clientId: client.id,
        permissionId: null,
        actionIdRaw,
        ip,
        success: false,
        error: matchedPermission.error
      });
      return reply.status(403).send({ ok: false, error: matchedPermission.error });
    }

    try {
      const haResponse = await proxyHaState(entityId);

      await logAudit(request.log, {
        clientId: client.id,
        permissionId: matchedPermission.permission.id,
        actionIdRaw,
        ip,
        success: haResponse.ok,
        error: haResponse.ok ? null : `ha_request_failed:${haResponse.status}`
      });

      if (haResponse.contentType) {
        reply.header("content-type", haResponse.contentType);
      }
      if (haResponse.stale) {
        // Last known state while the live link to Home Assistant is down: say so, never hide it.
        reply.header("x-ha-stale", "1");
      }
      // Home Assistant's status is passed through as-is; Fastify 5 types only the schema's codes.
        return reply.status(haResponse.status as never).send(haResponse.body as never);
    } catch (err) {
      const message = err instanceof Error ? err.message : "unknown_error";
      await logAudit(request.log, {
        clientId: client.id,
        permissionId: matchedPermission.permission.id,
        actionIdRaw,
        ip,
        success: false,
        error: message
      });

      if (err instanceof HaBusyError) {
        return reply.header("retry-after", "1").status(503).send({ ok: false, error: "ha_busy" });
      }
      if (err instanceof HaUnavailableError) {
        return reply.header("retry-after", "5").status(503).send({ ok: false, error: "ha_unavailable" });
      }
      request.log.error({ err }, "ha_state_proxy_failed");
      return reply.status(502).send({ ok: false, error: "ha_state_proxy_failed" });
    }
  });
};
