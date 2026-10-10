import { prisma } from "./db.js";
import { env } from "./env.js";
import { HaStateHub, type HubLogger } from "./haHub.js";
import { connectHaWebSocket } from "./haHubConnection.js";
import { getHaToken } from "./haToken.js";
import { parsePermission } from "./permissions.js";

let logger: HubLogger = {
  info: (message) => console.info(message),
  warn: (message) => console.warn(message)
};

export function setHubLogger(next: HubLogger): void {
  logger = next;
}

// The one list of what to subscribe to: every entity an ACTIVE API key may read. Disabled keys are
// skipped here, not filtered afterwards. Anything that reads an entity must be reflected in this
// list, otherwise it is simply answered by asking Home Assistant (never from a stale copy).
export async function collectEntityIds(): Promise<string[]> {
  const clients = await prisma.client.findMany({ where: { status: "active" }, include: { permissions: true } });
  const ids: string[] = [];
  for (const client of clients) {
    for (const record of client.permissions) {
      const rule = parsePermission(record);
      if (rule?.kind === "state") {
        ids.push(...rule.entityIds);
      }
    }
  }
  return [...new Set(ids)];
}

export const haHub = new HaStateHub({
  baseUrl: env.HA_BASE_URL,
  websocketPath: env.HA_GATEKEEPER_ADDON ? "/websocket" : "/api/websocket",
  getToken: getHaToken,
  collectEntityIds,
  connect: (url) => connectHaWebSocket(url),
  log: { info: (message) => logger.info(message), warn: (message) => logger.warn(message) }
});

// Call whenever the set of readable entities may have changed (key created, edited, disabled,
// deleted). A no-op while the live connection is not in use.
export function requestHubResubscribe(): void {
  haHub.requestResubscribe();
}
