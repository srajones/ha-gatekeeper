import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import { z } from "zod";
import { prisma } from "./db.js";
import { env } from "./env.js";
import { logAudit } from "./audit.js";
import { timingSafeEqual } from "./security.js";
import {
  decryptSecret,
  encryptSecret,
  formatSecret,
  generateRecoveryCodes,
  generateTotpSecret,
  hashRecoveryCode,
  looksLikeRecoveryCode,
  otpauthUri,
  verifyTotp
} from "./totp.js";

// Optional second factor (TOTP) for the administrator login. Off until the administrator turns it on in
// the dashboard (Security). Details and the lock-out recovery path: docs/TWO_FACTOR.md.

const STATE_KEY = "auth.totp";
const PENDING_MS = 5 * 60_000; // time allowed between the password and the code
const SETUP_MS = 15 * 60_000; // time allowed to scan the secret and confirm it
const MAX_SESSION_FAILS = 5; // wrong codes before the half-finished login is thrown away
const MAX_GLOBAL_FAILS = 10; // wrong codes (any session) per window before every attempt waits
const GLOBAL_WINDOW_MS = 15 * 60_000;
const ISSUER = "HA Gatekeeper";

type TotpState = {
  v: 1;
  secretEnc: string;
  lastStep: number;
  recoveryHashes: string[];
  enabledAt: string;
};

export async function loadTotpState(): Promise<TotpState | null> {
  const row = await prisma.setting.findUnique({ where: { key: STATE_KEY } });
  if (!row) {
    return null;
  }
  try {
    const parsed = JSON.parse(row.value) as TotpState;
    if (parsed && parsed.v === 1 && typeof parsed.secretEnc === "string" && Array.isArray(parsed.recoveryHashes)) {
      return parsed;
    }
  } catch {
    // fall through: unreadable state counts as "enabled but broken" so the login stays closed
  }
  return { v: 1, secretEnc: "", lastStep: -1, recoveryHashes: [], enabledAt: row.updatedAt.toISOString() };
}

async function saveTotpState(state: TotpState): Promise<void> {
  const value = JSON.stringify(state);
  await prisma.setting.upsert({
    where: { key: STATE_KEY },
    create: { key: STATE_KEY, value },
    update: { value, updatedAt: new Date() }
  });
}

export async function clearTotpState(): Promise<void> {
  await prisma.setting.deleteMany({ where: { key: STATE_KEY } });
}

const failures: number[] = [];
function pruneFailures(now: number): void {
  while (failures.length > 0 && now - failures[0] > GLOBAL_WINDOW_MS) {
    failures.shift();
  }
}
export function resetTotpFailuresForTests(): void {
  failures.length = 0;
}

export type SecondFactorResult =
  | { ok: true; method: "totp" | "recovery" }
  | { ok: false; reason: "invalid" | "locked" | "broken" };

// Checks a 6-digit code or a recovery code against the saved state. A code that was already used is
// refused, a recovery code works once, and too many wrong codes (from anywhere) pause all attempts.
export async function checkSecondFactor(code: string, now: number = Date.now()): Promise<SecondFactorResult> {
  pruneFailures(now);
  if (failures.length >= MAX_GLOBAL_FAILS) {
    return { ok: false, reason: "locked" };
  }
  const state = await loadTotpState();
  if (!state) {
    return { ok: false, reason: "broken" };
  }
  let secret: Buffer;
  try {
    secret = decryptSecret(state.secretEnc, env.ADMIN_SESSION_SECRET);
  } catch {
    // The secret can no longer be read (ADMIN_SESSION_SECRET changed or the row is damaged). Fail
    // closed; the operator resets with `gatekeeper 2fa-reset` (needs shell access to the server).
    return { ok: false, reason: "broken" };
  }

  if (looksLikeRecoveryCode(code) && !/^\d{6}$/.test(code.replace(/\s/g, ""))) {
    const hash = hashRecoveryCode(code, env.ADMIN_SESSION_SECRET);
    const index = state.recoveryHashes.findIndex((h) => timingSafeEqual(h, hash));
    if (index >= 0) {
      const remaining = state.recoveryHashes.filter((_, i) => i !== index);
      await saveTotpState({ ...state, recoveryHashes: remaining });
      failures.length = 0;
      return { ok: true, method: "recovery" };
    }
    failures.push(now);
    return { ok: false, reason: "invalid" };
  }

  const step = verifyTotp(secret, code, { nowMs: now, lastUsedStep: state.lastStep });
  if (step === null) {
    failures.push(now);
    return { ok: false, reason: "invalid" };
  }
  await saveTotpState({ ...state, lastStep: step });
  failures.length = 0;
  return { ok: true, method: "totp" };
}

const codeSchema = z.object({ code: z.string().min(6).max(32) });
const passwordCodeSchema = z.object({ password: z.string().min(1), code: z.string().min(6).max(32) });
const passwordSchema = z.object({ password: z.string().min(1) });

export type TotpDeps = {
  ensureAdmin: (request: FastifyRequest, reply: FastifyReply) => boolean;
};

function secondFactorError(reply: FastifyReply, reason: "invalid" | "locked" | "broken") {
  if (reason === "locked") {
    return reply.status(429).header("retry-after", "60").send({ ok: false, error: "2fa_locked" });
  }
  if (reason === "broken") {
    return reply.status(409).send({ ok: false, error: "2fa_unreadable" });
  }
  return reply.status(401).send({ ok: false, error: "invalid_code" });
}

export function registerTotpRoutes(app: FastifyInstance, deps: TotpDeps): void {
  const limit = { config: { rateLimit: { max: 10, timeWindow: "1 minute" } } };
  const notAvailable = (reply: FastifyReply) => reply.status(404).send({ ok: false, error: "not_available" });

  // Second step of the login: the password was accepted, now the code.
  app.post("/login/2fa", limit, async (request, reply) => {
    const ip = request.ip ?? null;
    if (env.HA_GATEKEEPER_ADDON) {
      return notAvailable(reply);
    }
    const pendingAt = request.session.get("pending2fa");
    const parsed = codeSchema.safeParse(request.body ?? {});
    if (typeof pendingAt !== "number" || Date.now() - pendingAt > PENDING_MS) {
      request.session.delete();
      return reply.status(401).send({ ok: false, error: "login_expired" });
    }
    if (!parsed.success) {
      return reply.status(400).send({ ok: false, error: "invalid_body" });
    }
    const result = await checkSecondFactor(parsed.data.code);
    if (!result.ok) {
      const fails = (request.session.get("fails2fa") ?? 0) + 1;
      await logAudit(request.log, { clientId: null, permissionId: null, actionIdRaw: "admin.login", ip, success: false, error: `2fa_${result.reason}` });
      if (result.reason === "invalid" && fails >= MAX_SESSION_FAILS) {
        request.session.delete(); // start over with the password
        return reply.status(401).send({ ok: false, error: "too_many_attempts" });
      }
      request.session.set("fails2fa", fails);
      return secondFactorError(reply, result.reason);
    }
    request.session.set("admin", true);
    request.session.set("pending2fa", undefined);
    request.session.set("fails2fa", undefined);
    await logAudit(request.log, { clientId: null, permissionId: null, actionIdRaw: "admin.login", ip, success: true });
    if (result.method === "recovery") {
      await logAudit(request.log, { clientId: null, permissionId: null, actionIdRaw: "admin.2fa.recovery_used", ip, success: true });
    }
    return reply.send({ ok: true, recoveryCodeUsed: result.method === "recovery" });
  });

  app.get("/2fa", async (request, reply) => {
    if (!deps.ensureAdmin(request, reply)) {
      return;
    }
    if (env.HA_GATEKEEPER_ADDON) {
      return reply.send({ ok: true, available: false, enabled: false, recoveryCodesLeft: 0 });
    }
    const state = await loadTotpState();
    return reply.send({ ok: true, available: true, enabled: state !== null, recoveryCodesLeft: state?.recoveryHashes.length ?? 0 });
  });

  // Step 1 of turning it on: needs the password again; returns the secret for the authenticator app.
  app.post("/2fa/setup", limit, async (request, reply) => {
    if (!deps.ensureAdmin(request, reply)) {
      return;
    }
    if (env.HA_GATEKEEPER_ADDON) {
      return notAvailable(reply);
    }
    const parsed = passwordSchema.safeParse(request.body ?? {});
    if (!parsed.success) {
      return reply.status(400).send({ ok: false, error: "invalid_body" });
    }
    if (!timingSafeEqual(parsed.data.password, env.ADMIN_PASSWORD)) {
      await logAudit(request.log, { clientId: null, permissionId: null, actionIdRaw: "admin.2fa.setup", ip: request.ip ?? null, success: false, error: "invalid_credentials" });
      return reply.status(401).send({ ok: false, error: "invalid_credentials" });
    }
    if ((await loadTotpState()) !== null) {
      return reply.status(409).send({ ok: false, error: "already_enabled" });
    }
    const secret = generateTotpSecret();
    request.session.set("totpSetup", { secretEnc: encryptSecret(secret, env.ADMIN_SESSION_SECRET), at: Date.now() });
    return reply.send({
      ok: true,
      secret: formatSecret(secret),
      otpauthUri: otpauthUri(secret, "admin", ISSUER),
      issuer: ISSUER
    });
  });

  // Step 2: prove the app shows the right codes, then it is switched on and the recovery codes are shown once.
  app.post("/2fa/enable", limit, async (request, reply) => {
    if (!deps.ensureAdmin(request, reply)) {
      return;
    }
    if (env.HA_GATEKEEPER_ADDON) {
      return notAvailable(reply);
    }
    const parsed = codeSchema.safeParse(request.body ?? {});
    const pending = request.session.get("totpSetup");
    if (!parsed.success) {
      return reply.status(400).send({ ok: false, error: "invalid_body" });
    }
    if (!pending || Date.now() - pending.at > SETUP_MS) {
      request.session.set("totpSetup", undefined);
      return reply.status(409).send({ ok: false, error: "setup_expired" });
    }
    if ((await loadTotpState()) !== null) {
      return reply.status(409).send({ ok: false, error: "already_enabled" });
    }
    let secret: Buffer;
    try {
      secret = decryptSecret(pending.secretEnc, env.ADMIN_SESSION_SECRET);
    } catch {
      request.session.set("totpSetup", undefined);
      return reply.status(409).send({ ok: false, error: "setup_expired" });
    }
    const step = verifyTotp(secret, parsed.data.code);
    if (step === null) {
      await logAudit(request.log, { clientId: null, permissionId: null, actionIdRaw: "admin.2fa.enable", ip: request.ip ?? null, success: false, error: "invalid_code" });
      return reply.status(401).send({ ok: false, error: "invalid_code" });
    }
    const recoveryCodes = generateRecoveryCodes();
    await saveTotpState({
      v: 1,
      secretEnc: pending.secretEnc,
      lastStep: step,
      recoveryHashes: recoveryCodes.map((c) => hashRecoveryCode(c, env.ADMIN_SESSION_SECRET)),
      enabledAt: new Date().toISOString()
    });
    request.session.set("totpSetup", undefined);
    await logAudit(request.log, { clientId: null, permissionId: null, actionIdRaw: "admin.2fa.enable", ip: request.ip ?? null, success: true });
    return reply.send({ ok: true, recoveryCodes });
  });

  // Turning it off, and making new recovery codes, need the password AND a current code.
  app.post("/2fa/disable", limit, async (request, reply) => {
    if (!deps.ensureAdmin(request, reply)) {
      return;
    }
    if (env.HA_GATEKEEPER_ADDON) {
      return notAvailable(reply);
    }
    const parsed = passwordCodeSchema.safeParse(request.body ?? {});
    if (!parsed.success) {
      return reply.status(400).send({ ok: false, error: "invalid_body" });
    }
    if (!timingSafeEqual(parsed.data.password, env.ADMIN_PASSWORD)) {
      await logAudit(request.log, { clientId: null, permissionId: null, actionIdRaw: "admin.2fa.disable", ip: request.ip ?? null, success: false, error: "invalid_credentials" });
      return reply.status(401).send({ ok: false, error: "invalid_credentials" });
    }
    if ((await loadTotpState()) === null) {
      return reply.status(409).send({ ok: false, error: "not_enabled" });
    }
    const result = await checkSecondFactor(parsed.data.code);
    if (!result.ok) {
      await logAudit(request.log, { clientId: null, permissionId: null, actionIdRaw: "admin.2fa.disable", ip: request.ip ?? null, success: false, error: `2fa_${result.reason}` });
      return secondFactorError(reply, result.reason);
    }
    await clearTotpState();
    await logAudit(request.log, { clientId: null, permissionId: null, actionIdRaw: "admin.2fa.disable", ip: request.ip ?? null, success: true });
    return reply.send({ ok: true });
  });

  app.post("/2fa/recovery-codes", limit, async (request, reply) => {
    if (!deps.ensureAdmin(request, reply)) {
      return;
    }
    if (env.HA_GATEKEEPER_ADDON) {
      return notAvailable(reply);
    }
    const parsed = passwordCodeSchema.safeParse(request.body ?? {});
    if (!parsed.success) {
      return reply.status(400).send({ ok: false, error: "invalid_body" });
    }
    if (!timingSafeEqual(parsed.data.password, env.ADMIN_PASSWORD)) {
      await logAudit(request.log, { clientId: null, permissionId: null, actionIdRaw: "admin.2fa.recovery_codes", ip: request.ip ?? null, success: false, error: "invalid_credentials" });
      return reply.status(401).send({ ok: false, error: "invalid_credentials" });
    }
    if ((await loadTotpState()) === null) {
      return reply.status(409).send({ ok: false, error: "not_enabled" });
    }
    const result = await checkSecondFactor(parsed.data.code);
    if (!result.ok) {
      await logAudit(request.log, { clientId: null, permissionId: null, actionIdRaw: "admin.2fa.recovery_codes", ip: request.ip ?? null, success: false, error: `2fa_${result.reason}` });
      return secondFactorError(reply, result.reason);
    }
    const state = await loadTotpState();
    const recoveryCodes = generateRecoveryCodes();
    if (state) {
      await saveTotpState({ ...state, recoveryHashes: recoveryCodes.map((c) => hashRecoveryCode(c, env.ADMIN_SESSION_SECRET)) });
    }
    await logAudit(request.log, { clientId: null, permissionId: null, actionIdRaw: "admin.2fa.recovery_codes", ip: request.ip ?? null, success: true });
    return reply.send({ ok: true, recoveryCodes });
  });
}
