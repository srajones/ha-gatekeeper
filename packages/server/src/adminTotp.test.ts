import assert from "node:assert/strict";
import crypto from "node:crypto";
import { after, beforeEach, test } from "node:test";
import cookie from "@fastify/cookie";
import secureSession from "@fastify/secure-session";
import Fastify from "fastify";
import { createTestDatabase } from "./testDb.js";

process.env.NODE_ENV = "test";
process.env.HA_BASE_URL = "http://127.0.0.1:1";
process.env.HA_TOKEN = "fake-ha-token";
process.env.ADMIN_PASSWORD = "correct-horse-battery-staple";
process.env.ADMIN_SESSION_SECRET = "12345678901234567890123456789012";
process.env.API_KEY_HASH_SECRET = "12345678901234567890123456789012";
const PASSWORD = process.env.ADMIN_PASSWORD;

const testDb = createTestDatabase();
process.env.DATABASE_URL = testDb.databaseUrl;

const { prisma } = await import("./db.js");
const { adminRoutes } = await import("./admin.js");
const { resetTotpFailuresForTests, clearTotpState } = await import("./adminTotp.js");
const { base32Decode, hotp, currentStep } = await import("./totp.js");
const { resetSettings, getSettings } = await import("./settings.js");

const app = Fastify({ logger: false });
await app.register(cookie);
await app.register(secureSession, {
  key: crypto.createHash("sha256").update(process.env.ADMIN_SESSION_SECRET).digest(),
  cookieName: "hgk_admin",
  cookie: { path: "/", httpOnly: true, sameSite: "lax", secure: false }
});
await app.register(adminRoutes, { prefix: "/admin" });

after(async () => {
  await app.close();
  await prisma.$disconnect();
  testDb.cleanup();
});

beforeEach(async () => {
  await clearTotpState();
  resetTotpFailuresForTests();
});

// A tiny cookie jar: one "browser".
let nextIp = 10;
class Browser {
  private jar = "";
  // each "browser" has its own address so the per-IP rate limit of one test never spills into another
  private readonly ip = `192.0.2.${nextIp++}`;
  async call(method: "GET" | "POST", url: string, payload?: unknown) {
    const response = await app.inject({ method, url, payload: payload as object | undefined, remoteAddress: this.ip, headers: this.jar ? { cookie: this.jar } : {} });
    const set = response.headers["set-cookie"];
    const raw = Array.isArray(set) ? set[0] : set;
    if (typeof raw === "string") {
      this.jar = raw.split(";")[0];
    }
    return response;
  }
  login(password = PASSWORD) {
    return this.call("POST", "/admin/login", { password });
  }
  async me() {
    return (await this.call("GET", "/admin/me")).json() as { authenticated: boolean; twoFactorPending: boolean };
  }
}

function codeFor(secretText: string, offset = 0): string {
  return hotp(base32Decode(secretText), currentStep() + offset);
}

// Turns 2FA on in a logged-in browser and returns what the user would keep.
async function enable(browser: Browser) {
  await browser.login();
  const setup = (await browser.call("POST", "/admin/2fa/setup", { password: PASSWORD })).json() as { secret: string; otpauthUri: string };
  const secret = setup.secret;
  const enabled = await browser.call("POST", "/admin/2fa/enable", { code: codeFor(secret) });
  assert.equal(enabled.statusCode, 200);
  return { secret, recoveryCodes: (enabled.json() as { recoveryCodes: string[] }).recoveryCodes };
}

test("without 2FA the login is unchanged (password only)", async () => {
  const b = new Browser();
  const res = await b.login();
  assert.equal(res.statusCode, 200);
  assert.deepEqual(res.json(), { ok: true });
  assert.equal((await b.me()).authenticated, true);
  const status = (await b.call("GET", "/admin/2fa")).json();
  assert.deepEqual(status, { ok: true, available: true, enabled: false, recoveryCodesLeft: 0 });
});

test("2FA endpoints need an admin session", async () => {
  const b = new Browser();
  for (const [method, url] of [["GET", "/admin/2fa"], ["POST", "/admin/2fa/setup"], ["POST", "/admin/2fa/enable"], ["POST", "/admin/2fa/disable"], ["POST", "/admin/2fa/recovery-codes"]] as const) {
    assert.equal((await b.call(method, url, {})).statusCode, 401, url);
  }
});

test("setup needs the password again; the secret is not stored until the code is confirmed", async () => {
  const b = new Browser();
  await b.login();
  assert.equal((await b.call("POST", "/admin/2fa/setup", { password: "wrong" })).statusCode, 401);
  const setup = await b.call("POST", "/admin/2fa/setup", { password: PASSWORD });
  assert.equal(setup.statusCode, 200);
  const body = setup.json() as { secret: string; otpauthUri: string };
  assert.match(body.secret.replace(/ /g, ""), /^[A-Z2-7]{32}$/);
  assert.ok(body.otpauthUri.startsWith("otpauth://totp/"));
  assert.equal(await prisma.setting.count({ where: { key: "auth.totp" } }), 0, "nothing saved before confirmation");
  // a wrong code does not switch it on
  assert.equal((await b.call("POST", "/admin/2fa/enable", { code: "000000" })).statusCode, 401);
  assert.equal((await b.call("GET", "/admin/2fa")).json().enabled, false);
});

test("enabling returns 10 recovery codes once; the database holds only encrypted/hashed values", async () => {
  const b = new Browser();
  const { secret, recoveryCodes } = await enable(b);
  assert.equal(recoveryCodes.length, 10);
  const row = await prisma.setting.findUniqueOrThrow({ where: { key: "auth.totp" } });
  const raw = base32Decode(secret).toString("hex");
  assert.ok(!row.value.includes(secret.replace(/ /g, "")), "secret not in the clear");
  assert.ok(!row.value.toLowerCase().includes(raw), "secret bytes not in the clear");
  for (const code of recoveryCodes) {
    assert.ok(!row.value.includes(code), "recovery code not in the clear");
  }
  const status = (await b.call("GET", "/admin/2fa")).json();
  assert.deepEqual(status, { ok: true, available: true, enabled: true, recoveryCodesLeft: 10 });
  assert.equal((await b.call("POST", "/admin/2fa/setup", { password: PASSWORD })).statusCode, 409, "already enabled");
});

test("with 2FA on, the password alone does not log in", async () => {
  await enable(new Browser());
  const b = new Browser();
  const res = await b.login();
  assert.equal(res.statusCode, 200);
  assert.deepEqual(res.json(), { ok: true, needs2fa: true });
  const me = await b.me();
  assert.equal(me.authenticated, false);
  assert.equal(me.twoFactorPending, true);
  assert.equal((await b.call("GET", "/admin/clients")).statusCode, 401, "admin API stays closed");
  assert.equal((await b.call("GET", "/admin/settings")).statusCode, 401);
});

test("password then a valid code logs in; the same code cannot be used again", async () => {
  const { secret } = await enable(new Browser());
  // the enabling code is already used, so use the next step (one step ahead is allowed)
  const b = new Browser();
  await b.login();
  const code = codeFor(secret, 1);
  assert.equal((await b.call("POST", "/admin/login/2fa", { code })).statusCode, 200);
  assert.equal((await b.me()).authenticated, true);
  // replay from a second browser
  const c = new Browser();
  await c.login();
  const replay = await c.call("POST", "/admin/login/2fa", { code });
  assert.equal(replay.statusCode, 401);
  assert.equal(replay.json().error, "invalid_code");
  assert.equal((await c.me()).authenticated, false);
});

test("a wrong password never reaches the second step", async () => {
  await enable(new Browser());
  const b = new Browser();
  const res = await b.login("nope");
  assert.equal(res.statusCode, 401);
  assert.equal((await b.call("POST", "/admin/login/2fa", { code: "123456" })).statusCode, 401);
});

test("the code step without a prior password is refused", async () => {
  const { secret } = await enable(new Browser());
  const b = new Browser();
  const res = await b.call("POST", "/admin/login/2fa", { code: codeFor(secret, 1) });
  assert.equal(res.statusCode, 401);
  assert.equal(res.json().error, "login_expired");
});

test("five wrong codes throw the half-finished login away", async () => {
  const { secret } = await enable(new Browser());
  const b = new Browser();
  await b.login();
  for (let i = 0; i < 4; i += 1) {
    assert.equal((await b.call("POST", "/admin/login/2fa", { code: "000000" })).json().error, "invalid_code");
  }
  const fifth = await b.call("POST", "/admin/login/2fa", { code: "000000" });
  assert.equal(fifth.json().error, "too_many_attempts");
  // the right code no longer helps without the password again
  const after = await b.call("POST", "/admin/login/2fa", { code: codeFor(secret, 1) });
  assert.equal(after.statusCode, 401);
  assert.equal((await b.me()).authenticated, false);
});

test("many wrong codes across sessions lock every attempt for a while, even the right code", async () => {
  const { secret } = await enable(new Browser());
  for (let i = 0; i < 10; i += 1) {
    const b = new Browser();
    await b.login();
    assert.equal((await b.call("POST", "/admin/login/2fa", { code: "000000" })).statusCode, 401);
  }
  const b = new Browser();
  await b.login();
  const locked = await b.call("POST", "/admin/login/2fa", { code: codeFor(secret, 1) });
  assert.equal(locked.statusCode, 429);
  assert.equal(locked.json().error, "2fa_locked");
  assert.equal((await b.me()).authenticated, false);
});

test("a recovery code logs in once and is then gone", async () => {
  const { recoveryCodes } = await enable(new Browser());
  const b = new Browser();
  await b.login();
  const res = await b.call("POST", "/admin/login/2fa", { code: recoveryCodes[3].toLowerCase() });
  assert.equal(res.statusCode, 200);
  assert.equal(res.json().recoveryCodeUsed, true);
  assert.equal((await b.call("GET", "/admin/2fa")).json().recoveryCodesLeft, 9);
  const c = new Browser();
  await c.login();
  assert.equal((await c.call("POST", "/admin/login/2fa", { code: recoveryCodes[3] })).statusCode, 401);
  const d = new Browser();
  await d.login();
  assert.equal((await d.call("POST", "/admin/login/2fa", { code: recoveryCodes[4] })).statusCode, 200);
  const used = await prisma.auditLog.count({ where: { actionIdRaw: "admin.2fa.recovery_used", success: true } });
  assert.equal(used, 2);
});

test("disabling needs the password and a valid code", async () => {
  const b = new Browser();
  const { secret } = await enable(b);
  assert.equal((await b.call("POST", "/admin/2fa/disable", { password: "wrong", code: codeFor(secret, 1) })).statusCode, 401);
  assert.equal((await b.call("POST", "/admin/2fa/disable", { password: PASSWORD, code: "000000" })).statusCode, 401);
  assert.equal((await b.call("GET", "/admin/2fa")).json().enabled, true, "still on after the failed attempts");
  // the code used to enable it cannot be reused; the next step can
  assert.equal((await b.call("POST", "/admin/2fa/disable", { password: PASSWORD, code: codeFor(secret) })).statusCode, 401);
  const ok = await b.call("POST", "/admin/2fa/disable", { password: PASSWORD, code: codeFor(secret, 1) });
  assert.equal(ok.statusCode, 200);
  assert.equal((await b.call("GET", "/admin/2fa")).json().enabled, false);
  const fresh = new Browser();
  assert.deepEqual((await fresh.login()).json(), { ok: true }, "password-only login again");
});

test("disabling also works with a recovery code (lost phone)", async () => {
  const b = new Browser();
  const { recoveryCodes } = await enable(b);
  const ok = await b.call("POST", "/admin/2fa/disable", { password: PASSWORD, code: recoveryCodes[0] });
  assert.equal(ok.statusCode, 200);
  assert.equal((await b.call("GET", "/admin/2fa")).json().enabled, false);
});

test("regenerating recovery codes replaces the old ones", async () => {
  const b = new Browser();
  const { secret, recoveryCodes } = await enable(b);
  assert.equal((await b.call("POST", "/admin/2fa/recovery-codes", { password: PASSWORD, code: "000000" })).statusCode, 401);
  const res = await b.call("POST", "/admin/2fa/recovery-codes", { password: PASSWORD, code: codeFor(secret, 1) });
  assert.equal(res.statusCode, 200);
  const fresh = res.json().recoveryCodes as string[];
  assert.equal(fresh.length, 10);
  const c = new Browser();
  await c.login();
  assert.equal((await c.call("POST", "/admin/login/2fa", { code: recoveryCodes[0] })).statusCode, 401, "an old code no longer works");
  assert.equal((await c.call("POST", "/admin/login/2fa", { code: fresh[0] })).statusCode, 200);
});

test("if the saved secret can no longer be read the login stays closed (fail closed), with a clear error", async () => {
  await enable(new Browser());
  const row = await prisma.setting.findUniqueOrThrow({ where: { key: "auth.totp" } });
  const state = JSON.parse(row.value);
  state.secretEnc = "v1:AAAA:AAAA:AAAA";
  await prisma.setting.update({ where: { key: "auth.totp" } , data: { value: JSON.stringify(state) } });
  const b = new Browser();
  assert.deepEqual((await b.login()).json(), { ok: true, needs2fa: true });
  const res = await b.call("POST", "/admin/login/2fa", { code: "123456" });
  assert.equal(res.statusCode, 409);
  assert.equal(res.json().error, "2fa_unreadable");
  assert.equal((await b.me()).authenticated, false);
  // corrupt JSON must not open the door either
  await prisma.setting.update({ where: { key: "auth.totp" }, data: { value: "{not json" } });
  const c = new Browser();
  assert.deepEqual((await c.login()).json(), { ok: true, needs2fa: true });
});

test("resetting the gateway options does not touch the 2FA state", async () => {
  await enable(new Browser());
  await resetSettings(prisma);
  assert.equal(getSettings().stateSource, "subscription");
  assert.equal(await prisma.setting.count({ where: { key: "auth.totp" } }), 1);
});

test("the login steps are audited without codes or secrets", async () => {
  const { secret } = await enable(new Browser());
  const b = new Browser();
  await b.login();
  await b.call("POST", "/admin/login/2fa", { code: "000000" });
  await b.call("POST", "/admin/login/2fa", { code: codeFor(secret, 1) });
  const rows = await prisma.auditLog.findMany({ where: { actionIdRaw: { startsWith: "admin." } } });
  const names = new Set(rows.map((r) => r.actionIdRaw));
  for (const expected of ["admin.login.password", "admin.login", "admin.2fa.enable"]) {
    assert.ok(names.has(expected), expected);
  }
  assert.ok(rows.some((r) => r.error === "2fa_invalid" || r.error === null));
  assert.ok(!JSON.stringify(rows).includes(secret.replace(/ /g, "")));
});
