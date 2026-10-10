import { fetch } from "undici";
import { env } from "./env.js";
import { CoalescingCache, ConcurrencyLimiter } from "./haGateway.js";

export type HaServiceProxyResult = {
  ok: boolean;
  status: number;
  contentType?: string;
  body: string;
};

const baseUrl = env.HA_BASE_URL.replace(/\/$/, "");

// Every request to Home Assistant goes through one limiter, and state reads through one shared
// cache, so the number of API keys in front of this server never turns into load on Home
// Assistant (see haGateway.ts).
const REQUEST_TIMEOUT_MS = 15_000;
const limiter = new ConcurrencyLimiter(env.HA_MAX_CONCURRENCY, env.HA_MAX_CONCURRENCY * 8, 10_000);
const stateCache = new CoalescingCache<HaServiceProxyResult>(env.HA_STATE_CACHE_MS);

async function haRequest(
  url: string,
  init: { method: "GET" | "POST"; body?: string }
): Promise<HaServiceProxyResult> {
  return limiter.run(async () => {
    const res = await fetch(url, {
      method: init.method,
      headers: {
        Authorization: `Bearer ${env.HA_TOKEN}`,
        "Content-Type": "application/json"
      },
      body: init.body,
      signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS)
    });
    return {
      ok: res.ok,
      status: res.status,
      contentType: res.headers.get("content-type") ?? undefined,
      body: await res.text()
    };
  });
}

export type HaServiceCatalog = {
  domain: string;
  services: string[];
};

export type HaEntity = {
  entityId: string;
  domain: string;
  name: string;
};

export async function proxyHaServiceCall(
  domain: string,
  service: string,
  body: Record<string, unknown>,
  queryString = ""
): Promise<HaServiceProxyResult> {
  const url = `${baseUrl}/api/services/${encodeURIComponent(domain)}/${encodeURIComponent(
    service
  )}${queryString}`;
  try {
    return await haRequest(url, { method: "POST", body: JSON.stringify(body) });
  } finally {
    // Whatever the outcome, the next state read must reflect what this call may have changed.
    stateCache.invalidate();
  }
}

export async function proxyHaState(entityId: string): Promise<HaServiceProxyResult> {
  const url = `${baseUrl}/api/states/${encodeURIComponent(entityId)}`;
  return stateCache.get(
    entityId,
    () => haRequest(url, { method: "GET" }),
    (result) => result.ok
  );
}

async function haJson<T>(path: string, failure: string): Promise<T> {
  const res = await haRequest(`${baseUrl}${path}`, { method: "GET" });
  if (!res.ok) {
    throw new Error(`${failure}:${res.status}`);
  }
  return JSON.parse(res.body) as T;
}

export async function fetchHaServices(): Promise<HaServiceCatalog[]> {
  const data = await haJson<Array<{ domain: string; services: Record<string, unknown> }>>(
    "/api/services",
    "ha_services_failed"
  );
  return data.map((entry) => ({
    domain: entry.domain,
    services: Object.keys(entry.services ?? {})
  }));
}

export async function fetchHaEntities(): Promise<HaEntity[]> {
  const data = await haJson<
    Array<{
      entity_id: string;
      attributes?: { friendly_name?: string };
    }>
  >("/api/states", "ha_entities_failed");

  return data.map((entry) => {
    const entityId = entry.entity_id;
    const domain = entityId.split(".")[0] ?? "unknown";
    const name = entry.attributes?.friendly_name ?? entityId;
    return { entityId, domain, name };
  });
}
