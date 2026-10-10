import type { PrismaClient } from "@prisma/client";
import { z } from "zod";
import { env } from "./env.js";

// How the gateway behaves, chosen by the administrator in the dashboard (Settings page) and kept in
// the database. Every option has a safe default; .env values (HA_STATE_CACHE_MS, HA_MAX_CONCURRENCY)
// only provide the starting defaults, a value saved in the dashboard wins. Changes apply immediately,
// no restart. Documented in docs/HOME_ASSISTANT_CONNECTION.md.

export const settingsSchema = z.object({
  // How state reads (GET /api/states/...) are answered:
  //   subscription  one websocket to Home Assistant pushes changes into memory; API reads never reach HA
  //   cache         every read asks Home Assistant, but answers are shared for `cacheMs`
  //   direct        every read asks Home Assistant (simultaneous reads of one entity still share one request)
  stateSource: z.enum(["subscription", "cache", "direct"]),
  // Seconds-scale sharing window for reads that do ask Home Assistant (cache mode, and the fallback paths).
  cacheMs: z.number().int().min(0).max(60_000),
  // At most this many requests to Home Assistant at the same moment; the rest wait, then get 503 ha_busy.
  maxConcurrency: z.number().int().min(1).max(64),
  // What a read returns while the live link to Home Assistant is down (subscription mode):
  //   live-then-last-known  ask Home Assistant directly; if that fails too, last known data marked X-HA-Stale: 1
  //   last-known            always last known data, marked X-HA-Stale: 1
  //   error                 503 ha_unavailable
  onLinkDown: z.enum(["live-then-last-known", "last-known", "error"]),
  // Requests per minute allowed for each API key.
  rateLimitPerMinute: z.number().int().min(1).max(10_000)
});

export type GatewaySettings = z.infer<typeof settingsSchema>;
export type GatewaySettingsPatch = Partial<GatewaySettings>;

export const SETTING_KEYS = Object.keys(settingsSchema.shape) as Array<keyof GatewaySettings>;

export function defaultSettings(): GatewaySettings {
  return {
    stateSource: "subscription",
    cacheMs: env.HA_STATE_CACHE_MS,
    maxConcurrency: env.HA_MAX_CONCURRENCY,
    onLinkDown: "live-then-last-known",
    rateLimitPerMinute: 100
  };
}

let current: GatewaySettings = defaultSettings();
const listeners = new Set<(settings: GatewaySettings) => void>();

export function getSettings(): GatewaySettings {
  return current;
}

export function onSettingsChange(listener: (settings: GatewaySettings) => void): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

export function parseSettingsPatch(input: unknown): { ok: true; patch: GatewaySettingsPatch } | { ok: false; errors: string[] } {
  const parsed = settingsSchema.partial().strict().safeParse(input);
  if (!parsed.success) {
    return { ok: false, errors: parsed.error.issues.map((issue) => `${issue.path.join(".") || "body"}: ${issue.message}`) };
  }
  return { ok: true, patch: parsed.data };
}

// Reads the saved options. A saved value that no longer validates is ignored (its default applies).
export async function loadSettings(prisma: PrismaClient): Promise<GatewaySettings> {
  const next: GatewaySettings = defaultSettings();
  let rows: Array<{ key: string; value: string }> = [];
  try {
    rows = await prisma.setting.findMany();
  } catch {
    // The table is created by the migration at start; if it is unreadable, run with the defaults.
  }
  for (const row of rows) {
    const key = row.key as keyof GatewaySettings;
    if (!SETTING_KEYS.includes(key)) {
      continue;
    }
    try {
      const value = JSON.parse(row.value);
      const check = settingsSchema.shape[key].safeParse(value);
      if (check.success) {
        (next as Record<string, unknown>)[key] = check.data;
      }
    } catch {
      // keep the default
    }
  }
  apply(next);
  return next;
}

export async function saveSettings(prisma: PrismaClient, patch: GatewaySettingsPatch): Promise<GatewaySettings> {
  const next = settingsSchema.parse({ ...current, ...patch });
  for (const key of SETTING_KEYS) {
    if (patch[key] === undefined || patch[key] === current[key]) {
      continue;
    }
    const value = JSON.stringify(next[key]);
    await prisma.setting.upsert({
      where: { key },
      create: { key, value },
      update: { value, updatedAt: new Date() }
    });
  }
  apply(next);
  return next;
}

export async function resetSettings(prisma: PrismaClient): Promise<GatewaySettings> {
  await prisma.setting.deleteMany();
  const next = defaultSettings();
  apply(next);
  return next;
}

function apply(next: GatewaySettings): void {
  current = next;
  for (const listener of listeners) {
    try {
      listener(next);
    } catch {
      // a failing listener must not block the others
    }
  }
}

// Plain-language descriptions shown next to each option in the dashboard (and mirrored in
// docs/HOME_ASSISTANT_CONNECTION.md). One source, so the page and the docs cannot drift apart.
export type SettingHelp = {
  key: keyof GatewaySettings;
  label: string;
  summary: string;
  detail: string;
  choices?: Array<{ value: string; label: string; description: string }>;
  unit?: string;
  min?: number;
  max?: number;
};

export const SETTINGS_HELP: SettingHelp[] = [
  {
    key: "stateSource",
    label: "How state reads are answered",
    summary: "Where the answer to GET /api/states/... comes from.",
    detail:
      "Subscription keeps ONE connection to Home Assistant open and receives only changes, so reads are answered from memory " +
      "and Home Assistant never sees them: 100 keys cost it the same as 1. Cache and Direct ask Home Assistant when a read comes in.",
    choices: [
      {
        value: "subscription",
        label: "Live subscription (recommended)",
        description:
          "One websocket pushes changes of exactly the entities your keys may read. Idle cost for Home Assistant is a keepalive ping every 20 seconds. If the link drops, the 'When the live link is down' option decides what happens."
      },
      {
        value: "cache",
        label: "Ask Home Assistant, share answers briefly",
        description:
          "Every read is answered by asking Home Assistant, but simultaneous reads of one entity share one request and the answer is reused for the window below."
      },
      {
        value: "direct",
        label: "Always ask Home Assistant",
        description:
          "No reuse except that reads of the same entity arriving at the same instant share one request. The most current answers, the most load on Home Assistant."
      }
    ]
  },
  {
    key: "cacheMs",
    label: "Sharing window",
    summary: "How long an answer fetched from Home Assistant is reused.",
    detail:
      "Used by 'Ask Home Assistant, share answers briefly' and as the fallback when the live link is down or an entity was only just added to a key. 0 turns reuse off.",
    unit: "milliseconds",
    min: 0,
    max: 60000
  },
  {
    key: "maxConcurrency",
    label: "Requests to Home Assistant at the same moment",
    summary: "A hard ceiling on how many requests Home Assistant gets at once.",
    detail:
      "Extra requests wait in a short queue; when the queue is full or a request waits more than 10 seconds the caller gets 503 ha_busy with Retry-After, instead of piling work onto Home Assistant.",
    min: 1,
    max: 64
  },
  {
    key: "onLinkDown",
    label: "When the live link is down",
    summary: "What a state read returns while the subscription is reconnecting (subscription mode only).",
    detail:
      "Reads for entities that were never received yet always ask Home Assistant directly. Data that comes from memory while the link is down is marked with the response header X-HA-Stale: 1 so a client can tell.",
    choices: [
      {
        value: "live-then-last-known",
        label: "Ask Home Assistant, fall back to last known (recommended)",
        description: "Fresh data if Home Assistant answers; if it cannot be reached either, the last known state with X-HA-Stale: 1."
      },
      {
        value: "last-known",
        label: "Last known state",
        description: "Always the last known state with X-HA-Stale: 1, never extra requests to Home Assistant while it is struggling."
      },
      {
        value: "error",
        label: "Report an error",
        description: "503 ha_unavailable. Use when a wrong or old value is worse than no value."
      }
    ]
  },
  {
    key: "rateLimitPerMinute",
    label: "Requests per key per minute",
    summary: "How often one API key may call this server.",
    detail: "Applies to each key separately. A key over the limit gets 429 rate_limited. This protects this server; Home Assistant is protected by the options above.",
    unit: "requests per minute",
    min: 1,
    max: 10000
  }
];
