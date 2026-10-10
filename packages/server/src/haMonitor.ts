import { getAlertConfig } from "./alertConfig.js";
import { AlertManager, sendAlert, safeError, type AlertMessage, type ChannelResult } from "./alerts.js";
import { haHub } from "./hubRuntime.js";
import { probeHomeAssistant } from "./ha.js";
import { getSettings } from "./settings.js";

// Watches the connection to Home Assistant and raises the alert when it stays down (see alerts.ts for the rules).
//
// Where the answer comes from:
//   * live subscription in use  -> the websocket itself: it is either connected or it is not (no extra traffic)
//   * otherwise (cache/direct modes, or no key watches an entity yet) -> one tiny request to /api/ every minute
// Either way the AlertManager gets the same report, so the behaviour is identical in every mode.

const PROBE_EVERY_MS = 60_000;
const TICK_MS = 5_000;

export const alertManager = new AlertManager({
  send: (message: AlertMessage): Promise<ChannelResult[]> => sendAlert(getAlertConfig(), message),
  settings: () => {
    const s = getSettings();
    return { downAfterSeconds: s.alertDownAfterSeconds, reminderMinutes: s.alertReminderMinutes };
  },
  hasChannels: () => getAlertConfig().channels.some((c) => c.configured),
  log: (message) => console.info(message)
});

let timer: NodeJS.Timeout | null = null;
let lastProbeAt = 0;
let probing = false;

async function step(): Promise<void> {
  const hub = haHub.status();
  const liveInUse = getSettings().stateSource === "subscription" && hub.running && hub.subscribed > 0;
  if (liveInUse) {
    alertManager.report({ up: hub.connected, reason: hub.lastError ?? undefined });
  } else if (!probing && Date.now() - lastProbeAt >= PROBE_EVERY_MS) {
    probing = true;
    lastProbeAt = Date.now();
    try {
      alertManager.report(await probeHomeAssistant());
    } finally {
      probing = false;
    }
  }
  alertManager.tick();
}

export function startHaMonitor(): void {
  if (timer) {
    return;
  }
  // First look right away (the server may have started while Home Assistant is down), then every few seconds.
  void step().catch(() => undefined);
  timer = setInterval(() => void step().catch(() => undefined), TICK_MS);
  timer.unref();
}

export function stopHaMonitor(): void {
  if (timer) {
    clearInterval(timer);
    timer = null;
  }
}

// Sends one message through every configured channel and returns what happened (dashboard button and CLI).
export async function sendTestAlert(): Promise<ChannelResult[]> {
  const config = getAlertConfig();
  return sendAlert(config, {
    kind: "test",
    title: "Test alert",
    body: "This is a test from HA Gatekeeper. If you can read this, alerts about Home Assistant being unreachable will reach you."
  });
}

export { safeError, probeHomeAssistant };
