import nodemailer from "nodemailer";
import type { AlertConfig, ChannelName } from "./alertConfig.js";

// Sending alerts and deciding when to send them.
//
// WHEN (AlertManager): the link to Home Assistant going down is not an emergency the second it happens (Home
// Assistant restarts, WiFi blips), so the first message waits `downAfterSeconds`. If it recovers before that,
// nothing is sent. If it stays down: one DOWN message, a reminder every `reminderMinutes` (0 = never), and one
// RECOVERED message with how long it lasted. Nothing is sent twice for the same outage.
//
// HOW (sendAlert): every configured channel is tried independently; one failing never blocks the others, and
// the result per channel is returned (and shown in the dashboard). Errors never contain secrets.

export type AlertKind = "down" | "reminder" | "recovered" | "test";
export type ChannelResult = { channel: ChannelName; ok: boolean; error?: string };
export type AlertMessage = { kind: AlertKind; title: string; body: string };

const TIMEOUT_MS = 10_000;

// An error text that is safe to show and log: no URLs (they embed secrets), no credentials.
export function safeError(error: unknown): string {
  const code = (error as { code?: string })?.code;
  const message = error instanceof Error ? error.message : String(error);
  const cleaned = message.replace(/https?:\/\/\S+/gi, "<url>").replace(/\s+/g, " ").slice(0, 160);
  return code && !cleaned.includes(code) ? `${code}: ${cleaned}` : cleaned;
}

async function postJson(url: string, payload: unknown, headers: Record<string, string> = {}): Promise<void> {
  const res = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json", ...headers },
    body: JSON.stringify(payload),
    signal: AbortSignal.timeout(TIMEOUT_MS),
    redirect: "error"
  });
  if (!res.ok) {
    throw new Error(`HTTP ${res.status}`);
  }
}

export async function sendAlert(config: AlertConfig, message: AlertMessage): Promise<ChannelResult[]> {
  const subject = `[HA Gatekeeper @ ${config.hostLabel}] ${message.title}`;
  const text = `${subject}\n\n${message.body}`;
  const jobs: Array<Promise<ChannelResult>> = [];
  const run = (channel: ChannelName, job: () => Promise<void>) => {
    jobs.push(
      job().then(
        () => ({ channel, ok: true }),
        (error: unknown) => ({ channel, ok: false, error: safeError(error) })
      )
    );
  };

  if (config.email) {
    const e = config.email;
    run("email", async () => {
      const transport = nodemailer.createTransport({
        host: e.host,
        port: e.port,
        secure: e.security === "tls",
        requireTLS: e.security === "starttls",
        ignoreTLS: e.security === "none",
        auth: e.user ? { user: e.user, pass: e.password } : undefined,
        connectionTimeout: TIMEOUT_MS,
        greetingTimeout: TIMEOUT_MS,
        socketTimeout: 15_000
      });
      try {
        await transport.sendMail({ from: e.from, to: e.to, subject, text });
      } finally {
        transport.close();
      }
    });
  }
  if (config.webhookUrl) {
    const url = config.webhookUrl;
    // text / content / message: Slack, Discord, Mattermost, Rocket.Chat and most generic receivers each read one of them.
    run("webhook", () => postJson(url, { text, content: text, message: text, title: subject, kind: message.kind }));
  }
  if (config.ntfy) {
    const n = config.ntfy;
    run("ntfy", async () => {
      const res = await fetch(n.url, {
        method: "POST",
        headers: {
          Title: subject.replace(/[^\x20-\x7e]/g, "?"),
          Priority: message.kind === "down" || message.kind === "reminder" ? "high" : "default",
          Tags: message.kind === "recovered" ? "white_check_mark" : message.kind === "test" ? "bell" : "rotating_light",
          ...(n.token ? { Authorization: `Bearer ${n.token}` } : {})
        },
        body: message.body,
        signal: AbortSignal.timeout(TIMEOUT_MS),
        redirect: "error"
      });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
    });
  }
  if (config.telegram) {
    const t = config.telegram;
    run("telegram", () => postJson(`${t.apiBase}/bot${t.token}/sendMessage`, { chat_id: t.chatId, text, disable_web_page_preview: true }));
  }

  return Promise.all(jobs);
}

export type AlertSettings = { downAfterSeconds: number; reminderMinutes: number };

export type AlertRecord = { at: string; kind: AlertKind; results: ChannelResult[] };

export type LinkReport = { up: boolean; reason?: string };

// Pure state machine over a clock, so every rule is testable without waiting.
export class AlertManager {
  private downSince: number | null = null;
  private lastReason = "";
  private alertedDown = false;
  private lastNotice = 0;
  private sending = false;
  readonly history: AlertRecord[] = [];

  constructor(
    private readonly deps: {
      send: (message: AlertMessage) => Promise<ChannelResult[]>;
      settings: () => AlertSettings;
      now?: () => number;
      hasChannels: () => boolean;
      log?: (message: string) => void;
    }
  ) {}

  private now(): number {
    return (this.deps.now ?? Date.now)();
  }

  // The state of the link to Home Assistant, reported whenever it is known or changes.
  report(link: LinkReport): void {
    const now = this.now();
    if (link.up) {
      if (this.downSince !== null) {
        const minutes = Math.max(1, Math.round((now - this.downSince) / 60_000));
        const wasAlerted = this.alertedDown;
        this.downSince = null;
        this.alertedDown = false;
        this.lastNotice = 0;
        if (wasAlerted) {
          void this.dispatch({
            kind: "recovered",
            title: "Home Assistant is reachable again",
            body: `The connection to Home Assistant is back after about ${minutes} minute${minutes === 1 ? "" : "s"}. API keys are served normally again.`
          });
        }
      }
      return;
    }
    this.lastReason = link.reason ?? this.lastReason;
    if (this.downSince === null) {
      this.downSince = now;
    }
  }

  // Called every few seconds: sends the DOWN message once the outage has lasted long enough, then reminders.
  tick(): void {
    if (this.downSince === null) {
      return;
    }
    const now = this.now();
    const { downAfterSeconds, reminderMinutes } = this.deps.settings();
    const downFor = now - this.downSince;
    if (!this.alertedDown) {
      if (downFor >= downAfterSeconds * 1000) {
        this.alertedDown = true;
        this.lastNotice = now;
        void this.dispatch({ kind: "down", title: "Home Assistant is NOT reachable", body: this.downBody(downFor) });
      }
      return;
    }
    if (reminderMinutes > 0 && now - this.lastNotice >= reminderMinutes * 60_000) {
      this.lastNotice = now;
      void this.dispatch({ kind: "reminder", title: "Home Assistant is STILL not reachable", body: this.downBody(downFor) });
    }
  }

  private downBody(downFor: number): string {
    const minutes = Math.max(1, Math.round(downFor / 60_000));
    const hint = /token|401|403|rejected/i.test(this.lastReason)
      ? "\nHome Assistant refused the long-lived access token. Create a new token in Home Assistant and update it on the server: sudo gatekeeper --reconfigure"
      : "\nThe server keeps retrying by itself. API keys are answered with the last known data (marked X-HA-Stale) or an error, depending on your Settings.";
    return `The connection to Home Assistant has been down for about ${minutes} minute${minutes === 1 ? "" : "s"}.\nLast problem: ${this.lastReason || "unknown"}.${hint}`;
  }

  private async dispatch(message: AlertMessage): Promise<void> {
    if (!this.deps.hasChannels()) {
      return;
    }
    let results: ChannelResult[] = [];
    try {
      results = await this.deps.send(message);
    } catch (error) {
      results = [{ channel: "webhook", ok: false, error: safeError(error) }];
    }
    this.history.unshift({ at: new Date(this.now()).toISOString(), kind: message.kind, results });
    this.history.length = Math.min(this.history.length, 30);
    const failed = results.filter((r) => !r.ok);
    this.deps.log?.(
      `alert ${message.kind}: ${results.length - failed.length}/${results.length} channels delivered${failed.length ? ` (failed: ${failed.map((f) => `${f.channel}: ${f.error}`).join("; ")})` : ""}`
    );
  }

  status(): { haDown: boolean; downSince: string | null; alerted: boolean } {
    return { haDown: this.downSince !== null, downSince: this.downSince === null ? null : new Date(this.downSince).toISOString(), alerted: this.alertedDown };
  }
}
