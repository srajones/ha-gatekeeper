import assert from "node:assert/strict";
import http from "node:http";
import { after, test } from "node:test";
import { resolveAlertConfig } from "./alertConfig.js";
import { AlertManager, safeError, sendAlert, type AlertMessage, type ChannelResult } from "./alerts.js";
import { FakeSmtpServer } from "./testSmtp.js";

// ---------------------------------------------------------------- configuration

const files: Record<string, string> = {
  "/run/secrets/smtp_password": "smtp-pass\n",
  "/run/secrets/alert_webhook_url": "https://hooks.example.com/services/T000/B000/SECRETSECRET\n",
  "/run/secrets/alert_ntfy_token": "tk_ntfy_secret\n",
  "/run/secrets/alert_telegram_bot_token": "123456:ABC-telegram-secret\n",
  "/run/secrets/empty": "\n"
};
const read = (p: string) => {
  if (p in files) return files[p]!;
  const error = new Error("nope") as NodeJS.ErrnoException;
  error.code = "ENOENT";
  throw error;
};

test("nothing configured: no channels, no problems", () => {
  const config = resolveAlertConfig({}, read);
  assert.deepEqual(config.channels.map((c) => [c.name, c.configured, c.problem]), [
    ["email", false, undefined],
    ["webhook", false, undefined],
    ["ntfy", false, undefined],
    ["telegram", false, undefined]
  ]);
});

test("every channel configured from environment and secret files", () => {
  const config = resolveAlertConfig(
    {
      ALERT_NAME: "vultr-1",
      ALERT_EMAIL_TO: "david@example.com, other@example.org",
      SMTP_HOST: "smtp.example.com",
      SMTP_PORT: "465",
      SMTP_SECURITY: "tls",
      SMTP_USER: "alerts@example.com",
      SMTP_PASSWORD_FILE: "/run/secrets/smtp_password",
      ALERT_WEBHOOK_URL_FILE: "/run/secrets/alert_webhook_url",
      ALERT_NTFY_URL: "https://ntfy.sh/my-topic",
      ALERT_NTFY_TOKEN_FILE: "/run/secrets/alert_ntfy_token",
      ALERT_TELEGRAM_CHAT_ID: "-1001234",
      ALERT_TELEGRAM_BOT_TOKEN_FILE: "/run/secrets/alert_telegram_bot_token"
    },
    read
  );
  assert.equal(config.hostLabel, "vultr-1");
  assert.deepEqual(config.email?.to, ["david@example.com", "other@example.org"]);
  assert.equal(config.email?.from, "alerts@example.com", "the login doubles as the sender when it is an address");
  assert.equal(config.email?.password, "smtp-pass");
  assert.equal(config.email?.security, "tls");
  assert.equal(config.webhookUrl, "https://hooks.example.com/services/T000/B000/SECRETSECRET");
  assert.equal(config.ntfy?.token, "tk_ntfy_secret");
  assert.equal(config.telegram?.token, "123456:ABC-telegram-secret");
  assert.ok(config.channels.every((c) => c.configured && !c.problem));
});

test("the dashboard view of a channel never carries a secret", () => {
  const config = resolveAlertConfig(
    {
      ALERT_EMAIL_TO: "david@example.com",
      SMTP_HOST: "smtp.example.com",
      SMTP_FROM: "a@example.com",
      ALERT_WEBHOOK_URL_FILE: "/run/secrets/alert_webhook_url",
      ALERT_NTFY_URL: "https://ntfy.sh/my-topic",
      ALERT_TELEGRAM_CHAT_ID: "42",
      ALERT_TELEGRAM_BOT_TOKEN_FILE: "/run/secrets/alert_telegram_bot_token"
    },
    read
  );
  const shown = JSON.stringify(config.channels);
  for (const secretPart of ["SECRETSECRET", "T000", "telegram-secret", "david@example.com"]) {
    assert.ok(!shown.includes(secretPart), `${secretPart} leaked into ${shown}`);
  }
  assert.ok(shown.includes("hooks.example.com"), "the host is shown so you know where it goes");
});

test("mistakes are reported per channel and never throw", () => {
  const config = resolveAlertConfig(
    {
      ALERT_EMAIL_TO: "not-an-address",
      SMTP_HOST: "",
      SMTP_PORT: "99999",
      SMTP_SECURITY: "ssl",
      SMTP_USER: "u",
      ALERT_WEBHOOK_URL: "ftp://x",
      ALERT_NTFY_URL: "nonsense",
      ALERT_TELEGRAM_CHAT_ID: "abc",
      ALERT_TELEGRAM_BOT_TOKEN_FILE: "/run/secrets/missing"
    },
    read
  );
  for (const c of config.channels) {
    assert.equal(c.configured, false, c.name);
    assert.ok(c.problem, `${c.name} should explain the problem`);
  }
  const email = config.channels.find((c) => c.name === "email")!;
  assert.match(email.problem!, /not an e-mail address/);
  assert.match(email.problem!, /SMTP_HOST/);
  assert.match(email.problem!, /SMTP_PORT/);
  assert.match(email.problem!, /SMTP_SECURITY/);
  assert.match(config.channels.find((c) => c.name === "telegram")!.problem!, /ENOENT/);
});

test("a login without a password is a problem, an open relay (no login) is fine", () => {
  const bad = resolveAlertConfig({ ALERT_EMAIL_TO: "a@b.co", SMTP_HOST: "h", SMTP_FROM: "x@y.zz", SMTP_USER: "u" }, read);
  assert.match(bad.channels[0]!.problem!, /SMTP_PASSWORD/);
  const open = resolveAlertConfig({ ALERT_EMAIL_TO: "a@b.co", SMTP_HOST: "h", SMTP_FROM: "x@y.zz", SMTP_SECURITY: "none", SMTP_PORT: "25" }, read);
  assert.equal(open.channels[0]!.configured, true);
});

test("errors are scrubbed of URLs (which embed secrets)", () => {
  const text = safeError(new Error("connect failed for https://api.telegram.org/bot123:SECRET/sendMessage after 10 s"));
  assert.ok(!text.includes("SECRET"));
  assert.ok(text.includes("<url>"));
});

// ---------------------------------------------------------------- when to alert

function manager(settings = { downAfterSeconds: 120, reminderMinutes: 60 }) {
  const sent: AlertMessage[] = [];
  let now = 1_000_000_000_000;
  const m = new AlertManager({
    send: async (message): Promise<ChannelResult[]> => {
      sent.push(message);
      return [{ channel: "webhook", ok: true }];
    },
    settings: () => settings,
    now: () => now,
    hasChannels: () => true
  });
  const advance = async (ms: number) => {
    now += ms;
    m.tick();
    await Promise.resolve();
    await Promise.resolve();
  };
  return { m, sent, advance, set: (s: typeof settings) => Object.assign(settings, s) };
}

test("a short outage sends nothing at all", async () => {
  const { m, sent, advance } = manager();
  m.report({ up: false, reason: "cannot connect (ECONNREFUSED)" });
  await advance(60_000);
  m.report({ up: true });
  await advance(300_000);
  assert.equal(sent.length, 0);
});

test("a long outage: one DOWN after the delay, reminders spaced out, one RECOVERED with the duration", async () => {
  const { m, sent, advance } = manager();
  m.report({ up: false, reason: "cannot connect (ECONNREFUSED)" });
  await advance(119_000);
  assert.equal(sent.length, 0, "not yet");
  await advance(2_000);
  assert.deepEqual(sent.map((s) => s.kind), ["down"]);
  assert.match(sent[0]!.body, /ECONNREFUSED/);
  for (let i = 0; i < 10; i += 1) {
    m.report({ up: false });
    await advance(60_000);
  }
  assert.deepEqual(sent.map((s) => s.kind), ["down"], "reminders are 60 minutes apart, so none in the next 10");
});

test("reminders every N minutes; 0 means never", async () => {
  const a = manager({ downAfterSeconds: 30, reminderMinutes: 10 });
  a.m.report({ up: false, reason: "x" });
  await a.advance(31_000);
  for (let i = 0; i < 35; i += 1) {
    a.m.report({ up: false });
    await a.advance(60_000);
  }
  assert.deepEqual(a.sent.map((s) => s.kind), ["down", "reminder", "reminder", "reminder"]);

  const b = manager({ downAfterSeconds: 30, reminderMinutes: 0 });
  b.m.report({ up: false, reason: "x" });
  await b.advance(31_000);
  for (let i = 0; i < 600; i += 1) {
    b.m.report({ up: false });
    await b.advance(60_000);
  }
  assert.deepEqual(b.sent.map((s) => s.kind), ["down"]);
});

test("recovery after an alerted outage says how long it lasted, once", async () => {
  const { m, sent, advance } = manager();
  m.report({ up: false, reason: "no answer" });
  await advance(121_000);
  await advance(600_000);
  m.report({ up: true });
  m.report({ up: true });
  await advance(10_000);
  assert.deepEqual(sent.map((s) => s.kind), ["down", "recovered"]);
  assert.match(sent[1]!.body, /about 12 minutes/);
  assert.equal(m.status().haDown, false);
});

test("a rejected token is called out with what to do", async () => {
  const { m, sent, advance } = manager();
  m.report({ up: false, reason: "Home Assistant rejected the access token (HTTP 401)" });
  await advance(121_000);
  assert.match(sent[0]!.body, /refused the long-lived access token/);
  assert.match(sent[0]!.body, /gatekeeper --reconfigure/);
});

test("a second outage after recovery alerts again; flapping inside the delay stays silent", async () => {
  const { m, sent, advance } = manager();
  m.report({ up: false, reason: "a" });
  await advance(121_000);
  m.report({ up: true });
  await advance(1000);
  for (let i = 0; i < 20; i += 1) {
    m.report({ up: false, reason: "flap" });
    await advance(30_000);
    m.report({ up: true });
    await advance(30_000);
  }
  assert.deepEqual(sent.map((s) => s.kind), ["down", "recovered"], "20 short blips: nothing");
  m.report({ up: false, reason: "b" });
  await advance(121_000);
  assert.deepEqual(sent.map((s) => s.kind), ["down", "recovered", "down"]);
});

test("changing the delay in Settings applies to a running outage", async () => {
  const { m, sent, advance, set } = manager({ downAfterSeconds: 600, reminderMinutes: 60 });
  m.report({ up: false, reason: "x" });
  await advance(200_000);
  assert.equal(sent.length, 0);
  set({ downAfterSeconds: 120, reminderMinutes: 60 });
  await advance(1000);
  assert.deepEqual(sent.map((s) => s.kind), ["down"]);
});

test("no channels: the manager stays quiet and does not fail", async () => {
  let called = 0;
  const m = new AlertManager({
    send: async () => { called += 1; return []; },
    settings: () => ({ downAfterSeconds: 30, reminderMinutes: 1 }),
    now: (() => { let t = 0; return () => (t += 60_000); })(),
    hasChannels: () => false
  });
  m.report({ up: false, reason: "x" });
  m.tick();
  m.tick();
  m.report({ up: true });
  await Promise.resolve();
  assert.equal(called, 0);
});

test("a sender that throws is recorded, never crashes the monitor", async () => {
  const m = new AlertManager({
    send: async () => { throw new Error("boom https://secret.example/hook"); },
    settings: () => ({ downAfterSeconds: 30, reminderMinutes: 0 }),
    now: (() => { let t = 0; return () => (t += 60_000); })(),
    hasChannels: () => true
  });
  m.report({ up: false, reason: "x" });
  m.tick();
  m.tick();
  await new Promise((r) => setTimeout(r, 10));
  assert.equal(m.history.length, 1);
  assert.ok(!JSON.stringify(m.history).includes("secret.example"));
});

// ---------------------------------------------------------------- delivery

const seen: Record<string, { url: string; headers: http.IncomingHttpHeaders; body: string }[]> = { hook: [], ntfy: [], tg: [] };
let hookStatus = 200;
const web = http.createServer((req, res) => {
  let body = "";
  req.on("data", (c) => (body += c));
  req.on("end", () => {
    const key = req.url?.startsWith("/hook") ? "hook" : req.url?.startsWith("/ntfy") ? "ntfy" : "tg";
    seen[key]!.push({ url: req.url ?? "", headers: req.headers, body });
    res.writeHead(key === "hook" ? hookStatus : 200);
    res.end("ok");
  });
});
await new Promise<void>((resolve) => web.listen(0, "127.0.0.1", resolve));
const webPort = (web.address() as { port: number }).port;
const smtp = new FakeSmtpServer();
const smtpPort = await smtp.listen();
after(async () => {
  web.close();
  await smtp.close();
});

const message: AlertMessage = { kind: "down", title: "Home Assistant is NOT reachable", body: "down for 3 minutes" };

test("all four channels deliver, in the right format", async () => {
  const config = resolveAlertConfig({
    ALERT_NAME: "vultr-1",
    ALERT_EMAIL_TO: "david@example.com",
    SMTP_HOST: "127.0.0.1",
    SMTP_PORT: String(smtpPort),
    SMTP_SECURITY: "none",
    SMTP_FROM: "gatekeeper@example.com",
    ALERT_WEBHOOK_URL: `http://127.0.0.1:${webPort}/hook/secret-path`,
    ALERT_NTFY_URL: `http://127.0.0.1:${webPort}/ntfy/topic`,
    ALERT_NTFY_TOKEN: "tk_x",
    ALERT_TELEGRAM_CHAT_ID: "777",
    ALERT_TELEGRAM_BOT_TOKEN: "111:tg-token",
    ALERT_TELEGRAM_API_BASE: `http://127.0.0.1:${webPort}/tg`
  });
  const results = await sendAlert(config, message);
  assert.deepEqual(results.map((r) => [r.channel, r.ok]).sort(), [["email", true], ["ntfy", true], ["telegram", true], ["webhook", true]]);

  const mail = smtp.mails.at(-1)!;
  assert.deepEqual(mail.to, ["david@example.com"]);
  assert.equal(mail.from, "gatekeeper@example.com");
  assert.match(mail.data, /Subject: \[HA Gatekeeper @ vultr-1\] Home Assistant is NOT reachable/);
  assert.match(mail.data, /down for 3 minutes/);

  const hook = JSON.parse(seen.hook.at(-1)!.body);
  assert.match(hook.text, /vultr-1.*NOT reachable/s);
  assert.equal(hook.content, hook.text);
  assert.equal(hook.message, hook.text);

  const ntfy = seen.ntfy.at(-1)!;
  assert.equal(ntfy.body, "down for 3 minutes");
  assert.equal(ntfy.headers.priority, "high");
  assert.equal(ntfy.headers.authorization, "Bearer tk_x");
  assert.match(String(ntfy.headers.title), /vultr-1/);

  const tg = seen.tg.at(-1)!;
  assert.equal(tg.url, "/tg/bot111:tg-token/sendMessage");
  assert.equal(JSON.parse(tg.body).chat_id, "777");
});

test("email with a login sends the credentials; a refusing server is reported", async () => {
  const withLogin = resolveAlertConfig({
    ALERT_EMAIL_TO: "d@example.com", SMTP_HOST: "127.0.0.1", SMTP_PORT: String(smtpPort), SMTP_SECURITY: "none",
    SMTP_USER: "alerts@example.com", SMTP_PASSWORD: "pw-123"
  });
  const [ok] = await sendAlert(withLogin, message);
  assert.equal(ok!.ok, true);
  const mail = smtp.mails.at(-1)!;
  assert.equal(mail.user, "alerts@example.com");
  assert.equal(mail.password, "pw-123");

  smtp.rejectAll = true;
  const [refused] = await sendAlert(withLogin, message);
  smtp.rejectAll = false;
  assert.equal(refused!.ok, false);
  assert.ok(!String(refused!.error).includes("pw-123"));
});

test("one failing channel never blocks the others, and its error carries no secret", async () => {
  hookStatus = 500;
  const config = resolveAlertConfig({
    ALERT_WEBHOOK_URL: `http://127.0.0.1:${webPort}/hook/very-secret-token`,
    ALERT_NTFY_URL: `http://127.0.0.1:${webPort}/ntfy/topic`
  });
  const results = await sendAlert(config, message);
  hookStatus = 200;
  const byName = Object.fromEntries(results.map((r) => [r.channel, r]));
  assert.equal(byName.webhook!.ok, false);
  assert.match(byName.webhook!.error!, /HTTP 500/);
  assert.ok(!JSON.stringify(results).includes("very-secret-token"));
  assert.equal(byName.ntfy!.ok, true);
});

test("an unreachable destination fails fast and clearly instead of hanging", async () => {
  const config = resolveAlertConfig({ ALERT_WEBHOOK_URL: "http://127.0.0.1:9/hook", ALERT_EMAIL_TO: "a@b.co", SMTP_HOST: "127.0.0.1", SMTP_PORT: "9", SMTP_SECURITY: "none", SMTP_FROM: "x@y.zz" });
  const started = Date.now();
  const results = await sendAlert(config, message);
  assert.ok(Date.now() - started < 12_000);
  assert.ok(results.every((r) => !r.ok && r.error));
});

test("redirects are refused (a webhook cannot bounce the message elsewhere)", async () => {
  const redirector = http.createServer((_req, res) => { res.writeHead(302, { location: `http://127.0.0.1:${webPort}/hook/elsewhere` }); res.end(); });
  await new Promise<void>((resolve) => redirector.listen(0, "127.0.0.1", resolve));
  const port = (redirector.address() as { port: number }).port;
  const before = seen.hook.length;
  const [result] = await sendAlert(resolveAlertConfig({ ALERT_WEBHOOK_URL: `http://127.0.0.1:${port}/x` }), message);
  redirector.close();
  assert.equal(result!.ok, false);
  assert.equal(seen.hook.length, before);
});
