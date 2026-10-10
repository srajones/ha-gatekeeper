import { isIP } from "node:net";
import { z } from "zod";

const nodeEnvSchema = z.enum(["development", "test", "production"]).default("development");
const logLevelSchema = z.enum(["trace", "debug", "info", "warn", "error", "fatal"]).default("info");

// Mirrors Fastify's `trustProxy` option. `false` (the default) keeps the socket peer as the
// client address. Anything else derives `request.ip` from X-Forwarded-For, so it must only be
// set behind a reverse proxy that overwrites that header.
export type TrustProxySetting = boolean | number | string[];

const TRUST_PROXY_KEYWORDS = new Set(["loopback", "linklocal", "uniquelocal"]);

const trustProxySchema = z
  .string()
  .trim()
  .default("")
  .transform((value, ctx): TrustProxySetting => {
    const normalized = value.toLowerCase();

    if (!normalized || ["false", "0", "no", "off"].includes(normalized)) {
      return false;
    }

    if (["true", "yes", "on"].includes(normalized)) {
      return true;
    }

    if (/^\d+$/.test(normalized)) {
      const hops = Number(normalized);
      return hops > 0 ? hops : false;
    }

    const entries = normalized
      .split(",")
      .map((entry) => entry.trim())
      .filter(Boolean);
    const invalid = entries.find((entry) => !isValidTrustProxyEntry(entry));

    if (entries.length === 0 || invalid !== undefined) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        message: `TRUST_PROXY must be false, true, a hop count, or a comma-separated list of IPs/CIDRs (got "${
          invalid ?? value
        }")`
      });
      return z.NEVER;
    }

    return entries;
  });

export type RuntimeConfig = {
  NODE_ENV: z.infer<typeof nodeEnvSchema>;
  PORT: number;
  DATABASE_URL: string;
  HA_BASE_URL: string;
  HA_TOKEN: string;
  ADMIN_PASSWORD: string;
  ADMIN_SESSION_SECRET: string;
  API_KEY_HASH_SECRET: string;
  CORS_ORIGIN: string;
  HA_GATEKEEPER_ADDON: boolean;
  ADDON_EXPOSE_API: boolean;
  LOG_LEVEL: z.infer<typeof logLevelSchema>;
  AUDIT_LOG_RETENTION_DAYS: number;
  TRUST_PROXY: TrustProxySetting;
  HA_STATE_CACHE_MS: number;
  HA_MAX_CONCURRENCY: number;
};

const commonSchema = z.object({
  NODE_ENV: nodeEnvSchema,
  PORT: z.coerce.number().int().positive().default(8080),
  DATABASE_URL: z.string().default("file:./prisma/dev.db"),
  ADMIN_SESSION_SECRET: z.string().trim().min(8),
  API_KEY_HASH_SECRET: z.string().trim().min(16),
  CORS_ORIGIN: z.string().default("http://localhost:5173"),
  LOG_LEVEL: logLevelSchema,
  AUDIT_LOG_RETENTION_DAYS: z.coerce.number().int().min(0).default(90),
  // How long a state read is shared between callers (0 = off) and how many requests may be
  // in flight to Home Assistant at once. See haGateway.ts.
  HA_STATE_CACHE_MS: z.coerce.number().int().min(0).max(60_000).default(2000),
  HA_MAX_CONCURRENCY: z.coerce.number().int().min(1).max(64).default(8)
});

const standaloneSchema = commonSchema.extend({
  HA_BASE_URL: z.string().trim().url(),
  HA_TOKEN: z.string().trim().min(1),
  ADMIN_PASSWORD: z.string().trim().min(8),
  TRUST_PROXY: trustProxySchema
});

const addonSchema = commonSchema.extend({
  SUPERVISOR_TOKEN: z.string().trim().min(1),
  ADMIN_PASSWORD: z.string().trim().min(8).optional()
});

export function resolveRuntimeConfig(raw: Record<string, string | undefined>): RuntimeConfig {
  const HA_GATEKEEPER_ADDON = parseBooleanFlag(raw.HA_GATEKEEPER_ADDON);
  const ADDON_EXPOSE_API = parseBooleanFlag(raw.ADDON_EXPOSE_API);

  if (HA_GATEKEEPER_ADDON) {
    const parsed = addonSchema.parse(raw);

    return {
      NODE_ENV: parsed.NODE_ENV,
      PORT: parsed.PORT,
      DATABASE_URL: parsed.DATABASE_URL,
      HA_BASE_URL: "http://supervisor/core",
      HA_TOKEN: parsed.SUPERVISOR_TOKEN,
      ADMIN_PASSWORD: parsed.ADMIN_PASSWORD || "addon-ingress-authenticated",
      ADMIN_SESSION_SECRET: parsed.ADMIN_SESSION_SECRET,
      API_KEY_HASH_SECRET: parsed.API_KEY_HASH_SECRET,
      CORS_ORIGIN: parsed.CORS_ORIGIN,
      HA_GATEKEEPER_ADDON,
      ADDON_EXPOSE_API,
      LOG_LEVEL: parsed.LOG_LEVEL,
      AUDIT_LOG_RETENTION_DAYS: parsed.AUDIT_LOG_RETENTION_DAYS,
      // Never honored in add-on mode: ingress trust is decided from the real socket peer
      // (see adminAuth.ts), so letting X-Forwarded-For rewrite `request.ip` would let a LAN
      // client impersonate the Supervisor proxy.
      TRUST_PROXY: false,
      HA_STATE_CACHE_MS: parsed.HA_STATE_CACHE_MS,
      HA_MAX_CONCURRENCY: parsed.HA_MAX_CONCURRENCY
    };
  }

  const parsed = standaloneSchema.parse(raw);

  return {
    NODE_ENV: parsed.NODE_ENV,
    PORT: parsed.PORT,
    DATABASE_URL: parsed.DATABASE_URL,
    HA_BASE_URL: parsed.HA_BASE_URL,
    HA_TOKEN: parsed.HA_TOKEN,
    ADMIN_PASSWORD: parsed.ADMIN_PASSWORD,
    ADMIN_SESSION_SECRET: parsed.ADMIN_SESSION_SECRET,
    API_KEY_HASH_SECRET: parsed.API_KEY_HASH_SECRET,
    CORS_ORIGIN: parsed.CORS_ORIGIN,
    HA_GATEKEEPER_ADDON,
    ADDON_EXPOSE_API,
    LOG_LEVEL: parsed.LOG_LEVEL,
    AUDIT_LOG_RETENTION_DAYS: parsed.AUDIT_LOG_RETENTION_DAYS,
    TRUST_PROXY: parsed.TRUST_PROXY,
    HA_STATE_CACHE_MS: parsed.HA_STATE_CACHE_MS,
    HA_MAX_CONCURRENCY: parsed.HA_MAX_CONCURRENCY
  };
}

function isValidTrustProxyEntry(entry: string): boolean {
  if (TRUST_PROXY_KEYWORDS.has(entry)) {
    return true;
  }

  const [address, prefix, ...rest] = entry.split("/");
  const family = isIP(address ?? "");

  if (rest.length > 0 || family === 0) {
    return false;
  }

  if (prefix === undefined) {
    return true;
  }

  return /^\d+$/.test(prefix) && Number(prefix) <= (family === 4 ? 32 : 128);
}

function parseBooleanFlag(value: string | undefined): boolean {
  if (!value) {
    return false;
  }

  return ["true", "1", "yes", "on"].includes(value.trim().toLowerCase());
}
