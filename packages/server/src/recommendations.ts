import type { GatewaySettings } from "./settings.js";

// "Recommended for your setup": the dashboard shows, next to every option, what to pick and why, based on how
// many entities the active API keys can read, how many keys there are, and whether Home Assistant is on this
// network or reached over the internet. Pure functions (no I/O) so every rule is unit tested. The rules are
// deliberately few and each one states its reason in plain words; nothing here is applied without the
// administrator pressing a button.

export const MAX_SUBSCRIBED_ENTITIES = 2000;

export type SetupFacts = {
  // Distinct entities that active keys may read (what a live subscription would watch).
  readableEntities: number;
  activeKeys: number;
  // Home Assistant is reached over the internet (Nabu Casa or a public address) rather than the local network.
  haRemote: boolean;
};

export type Recommendation<K extends keyof GatewaySettings = keyof GatewaySettings> = {
  key: K;
  value: GatewaySettings[K];
  reason: string;
};

// Local network / same machine: localhost, private ranges, *.local, host.docker.internal, single-label names.
export function isRemoteHaUrl(baseUrl: string): boolean {
  let host: string;
  try {
    host = new URL(baseUrl).hostname.toLowerCase();
  } catch {
    return false;
  }
  if (host === "localhost" || host === "host.docker.internal" || host.endsWith(".local") || host.endsWith(".lan")) return false;
  if (!host.includes(".") && !host.includes(":")) return false;
  if (host === "::1" || host.startsWith("fe80:") || host.startsWith("fc") || host.startsWith("fd")) return false;
  const m = /^(\d+)\.(\d+)\.\d+\.\d+$/.exec(host);
  if (m) {
    const a = Number(m[1]);
    const b = Number(m[2]);
    return !(a === 10 || a === 127 || (a === 192 && b === 168) || (a === 172 && b >= 16 && b <= 31) || (a === 169 && b === 254));
  }
  return true;
}

const n = (count: number, one: string, many: string) => `${count} ${count === 1 ? one : many}`;

export function recommendSettings(facts: SetupFacts): Array<Recommendation> {
  const { readableEntities: entities, activeKeys: keys, haRemote } = facts;
  const out: Array<Recommendation> = [];

  // 1. How state reads are answered
  let stateSource: GatewaySettings["stateSource"];
  let sourceReason: string;
  if (entities > MAX_SUBSCRIBED_ENTITIES) {
    stateSource = "cache";
    sourceReason = `${n(entities, "entity is", "entities are")} readable by your keys, above the live subscription limit of ${MAX_SUBSCRIBED_ENTITIES}. The live link is not used above that, so sharing answers briefly is the gentlest choice. Narrowing the keys' state permissions to what they need brings you back under the limit.`;
  } else if (entities === 0) {
    stateSource = "subscription";
    sourceReason = "No key can read states yet, so there is nothing to watch and this costs nothing. Live subscription is still the right choice: it starts by itself as soon as a key may read an entity.";
  } else {
    stateSource = "subscription";
    sourceReason = `${n(entities, "entity", "entities")} to watch, well inside the limit of ${MAX_SUBSCRIBED_ENTITIES}. Home Assistant then sends only changes, and ${n(keys, "key", "keys")} reading as often as they like costs it nothing.`;
  }
  out.push({ key: "stateSource", value: stateSource, reason: sourceReason });

  // 2. Sharing window (only matters when answers are fetched from Home Assistant)
  let cacheMs = 2000;
  let cacheReason = "2 seconds is short enough to feel live and long enough that simultaneous readers share one request.";
  if (stateSource !== "subscription" && (entities > 200 || keys > 10)) {
    cacheMs = 5000;
    cacheReason = `With ${n(entities, "entity", "entities")} and ${n(keys, "key", "keys")} asking Home Assistant directly, a 5 second window keeps its load low; sensors rarely change faster.`;
  } else if (stateSource === "subscription") {
    cacheReason += " With the live subscription it is only a fallback (link down, or an entity just added to a key), so the default is fine.";
  }
  out.push({ key: "cacheMs", value: cacheMs, reason: cacheReason });

  // 3. Concurrency ceiling
  let maxConcurrency = 8;
  let concReason = "8 at once is plenty for a typical home setup and cannot overwhelm a Raspberry Pi-class Home Assistant, because extra requests wait in line.";
  if (haRemote) {
    maxConcurrency = 4;
    concReason = "Home Assistant is reached over the internet (each request is slower and the remote service may rate-limit), so a lower ceiling of 4 avoids piling requests up.";
  } else if (stateSource !== "subscription" && entities > 200) {
    maxConcurrency = 4;
    concReason = `With ${n(entities, "entity", "entities")} read by asking Home Assistant, 4 at once protects it during bursts; requests simply queue briefly.`;
  }
  out.push({ key: "maxConcurrency", value: maxConcurrency, reason: concReason });

  // 4. Link down
  out.push({
    key: "onLinkDown",
    value: "live-then-last-known",
    reason:
      "Fresh data when Home Assistant answers, otherwise the last known value clearly marked X-HA-Stale: 1. Choose 'Report an error' instead only if an old value is dangerous for what your agents do (locks, alarms, heating)."
  });

  // 5. Per-key rate limit
  out.push({
    key: "rateLimitPerMinute",
    value: 100,
    reason:
      stateSource === "subscription"
        ? "100 requests a minute is about one every 0.6 seconds per key. Reads are answered from memory, so raising it for an agent that really polls faster is safe; service calls are held back by the ceiling above anyway."
        : "100 requests a minute is about one every 0.6 seconds per key. Because reads reach Home Assistant in this mode, raise it only for an agent that really needs to poll faster."
  });

  // 6. Alerts
  out.push({
    key: "alertDownAfterSeconds",
    value: haRemote ? 180 : 120,
    reason: haRemote
      ? "Home Assistant is reached over the internet, which blips more often than a local network, so wait 3 minutes before the first message to avoid false alarms."
      : "2 minutes ignores short restarts (an update or a reboot of Home Assistant takes about that long) and still tells you quickly about a real outage."
  });
  out.push({
    key: "alertReminderMinutes",
    value: 360,
    reason: "A reminder every 6 hours while it is still down: noticeable, not nagging. 0 turns reminders off."
  });

  return out;
}
