import fs from "node:fs";
import os from "node:os";

// Where alerts go. The same keys are read by the host watchdog (deploy/watchdog.sh, straight from .env), so
// one set of settings covers "the app notices Home Assistant is down" and "the watchdog notices the app is
// down". Secrets (SMTP password, ntfy token, Telegram bot token, the webhook URL) arrive as files, like the
// other secrets, and never appear in `docker inspect`.
//
// A mistake in one channel never stops the server or the other channels: it is reported as "misconfigured".

export type ChannelName = "email" | "webhook" | "ntfy" | "telegram";

export type ChannelStatus = {
  name: ChannelName;
  configured: boolean;
  // Where it goes, with anything secret left out (shown in the dashboard).
  target: string;
  problem?: string;
};

export type AlertConfig = {
  hostLabel: string;
  email: { to: string[]; from: string; host: string; port: number; security: "starttls" | "tls" | "none"; user: string; password: string } | null;
  webhookUrl: string | null;
  ntfy: { url: string; token: string } | null;
  telegram: { token: string; chatId: string; apiBase: string } | null;
  channels: ChannelStatus[];
};

type RawEnv = Record<string, string | undefined>;
const defaultReader = (filePath: string): string => fs.readFileSync(filePath, "utf8");

// NAME, or the content of the file named by NAME_FILE. Empty means "not set"; an unreadable file is a problem.
function secret(raw: RawEnv, key: string, readFile: (p: string) => string): { value: string; problem?: string } {
  const filePath = raw[`${key}_FILE`]?.trim();
  if (filePath) {
    try {
      return { value: readFile(filePath).trim() };
    } catch (error) {
      const code = (error as NodeJS.ErrnoException).code;
      return { value: "", problem: `cannot read the ${key.toLowerCase()} file${code ? ` (${code})` : ""}` };
    }
  }
  return { value: (raw[key] ?? "").trim() };
}

function isHttpUrl(value: string): boolean {
  try {
    const url = new URL(value);
    return url.protocol === "https:" || url.protocol === "http:";
  } catch {
    return false;
  }
}

function maskEmail(address: string): string {
  const [name = "", domain = ""] = address.split("@");
  return `${name.slice(0, 1)}***@${domain}`;
}

function hostOf(value: string): string {
  try {
    return new URL(value).host;
  } catch {
    return "?";
  }
}

const EMAIL = /^[^\s@<>"',;]+@[^\s@<>"',;]+\.[^\s@<>"',;]+$/;

export function resolveAlertConfig(raw: RawEnv, readFile: (p: string) => string = defaultReader): AlertConfig {
  const channels: ChannelStatus[] = [];
  const hostLabel = (raw.ALERT_NAME ?? "").trim() || os.hostname() || "server";

  // --- email
  let email: AlertConfig["email"] = null;
  const toList = (raw.ALERT_EMAIL_TO ?? "").split(",").map((s) => s.trim()).filter(Boolean);
  if (toList.length > 0 || (raw.SMTP_HOST ?? "").trim()) {
    const problems: string[] = [];
    const smtpHost = (raw.SMTP_HOST ?? "").trim();
    const port = Number((raw.SMTP_PORT ?? "").trim() || "587");
    const securityRaw = (raw.SMTP_SECURITY ?? "").trim().toLowerCase() || "starttls";
    const user = (raw.SMTP_USER ?? "").trim();
    const password = secret(raw, "SMTP_PASSWORD", readFile);
    const from = (raw.SMTP_FROM ?? "").trim() || (EMAIL.test(user) ? user : "");
    if (toList.length === 0) problems.push("ALERT_EMAIL_TO is empty");
    for (const address of toList) if (!EMAIL.test(address)) problems.push(`"${address}" is not an e-mail address`);
    if (!smtpHost) problems.push("SMTP_HOST is empty");
    if (!Number.isInteger(port) || port < 1 || port > 65535) problems.push("SMTP_PORT is not a port number");
    if (!["starttls", "tls", "none"].includes(securityRaw)) problems.push("SMTP_SECURITY must be starttls, tls or none");
    if (!from || !EMAIL.test(from)) problems.push("SMTP_FROM is missing or not an e-mail address");
    if (user && !password.value) problems.push(password.problem ?? "SMTP_USER is set but there is no SMTP_PASSWORD");
    if (problems.length === 0) {
      email = { to: toList, from, host: smtpHost, port, security: securityRaw as "starttls" | "tls" | "none", user, password: password.value };
    }
    channels.push({
      name: "email",
      configured: email !== null,
      target: toList.map(maskEmail).join(", ") + (smtpHost ? ` via ${smtpHost}` : ""),
      problem: problems.length ? problems.join("; ") : undefined
    });
  } else {
    channels.push({ name: "email", configured: false, target: "" });
  }

  // --- generic webhook (Slack, Discord, Mattermost, Teams bridges, anything taking JSON)
  const webhook = secret(raw, "ALERT_WEBHOOK_URL", readFile);
  let webhookUrl: string | null = null;
  if (webhook.value || webhook.problem) {
    const problem = webhook.problem ?? (isHttpUrl(webhook.value) ? undefined : "the webhook address is not a valid http(s) URL");
    if (!problem) webhookUrl = webhook.value;
    channels.push({ name: "webhook", configured: webhookUrl !== null, target: webhook.value ? hostOf(webhook.value) : "", problem });
  } else {
    channels.push({ name: "webhook", configured: false, target: "" });
  }

  // --- ntfy (ntfy.sh or your own server): a phone push without any account
  const ntfyUrl = (raw.ALERT_NTFY_URL ?? "").trim();
  let ntfy: AlertConfig["ntfy"] = null;
  if (ntfyUrl) {
    const token = secret(raw, "ALERT_NTFY_TOKEN", readFile);
    const problem = token.problem ?? (isHttpUrl(ntfyUrl) ? undefined : "ALERT_NTFY_URL is not a valid http(s) URL");
    if (!problem) ntfy = { url: ntfyUrl, token: token.value };
    channels.push({ name: "ntfy", configured: ntfy !== null, target: `${hostOf(ntfyUrl)}${new URL(isHttpUrl(ntfyUrl) ? ntfyUrl : "http://x/").pathname}`, problem });
  } else {
    channels.push({ name: "ntfy", configured: false, target: "" });
  }

  // --- Telegram bot
  const chatId = (raw.ALERT_TELEGRAM_CHAT_ID ?? "").trim();
  const botToken = secret(raw, "ALERT_TELEGRAM_BOT_TOKEN", readFile);
  let telegram: AlertConfig["telegram"] = null;
  if (chatId || botToken.value || botToken.problem) {
    const problems: string[] = [];
    if (botToken.problem) problems.push(botToken.problem);
    else if (!botToken.value) problems.push("the Telegram bot token is missing");
    if (!/^-?\d+$/.test(chatId) && !/^@[A-Za-z0-9_]{5,}$/.test(chatId)) problems.push("ALERT_TELEGRAM_CHAT_ID must be a number (or @channelname)");
    const apiBase = ((raw.ALERT_TELEGRAM_API_BASE ?? "").trim() || "https://api.telegram.org").replace(/\/$/, "");
    if (!isHttpUrl(apiBase)) problems.push("ALERT_TELEGRAM_API_BASE is not a valid URL");
    if (problems.length === 0) telegram = { token: botToken.value, chatId, apiBase };
    channels.push({ name: "telegram", configured: telegram !== null, target: chatId ? `chat ${chatId}` : "", problem: problems.length ? problems.join("; ") : undefined });
  } else {
    channels.push({ name: "telegram", configured: false, target: "" });
  }

  return { hostLabel, email, webhookUrl, ntfy, telegram, channels };
}

let cached: AlertConfig | null = null;
export function getAlertConfig(): AlertConfig {
  cached ??= resolveAlertConfig(process.env);
  return cached;
}
export function setAlertConfigForTests(config: AlertConfig | null): void {
  cached = config;
}
