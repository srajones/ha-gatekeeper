import crypto from "node:crypto";

// Time-based one-time passwords (RFC 6238, HMAC-SHA1, 6 digits, 30 s) for the optional second factor on
// the administrator login, plus single-use recovery codes. Standard authenticator apps (Google
// Authenticator, Aegis, 1Password, Bitwarden, Authy ...) all speak this. No third-party library: the
// algorithm is small and fully covered by the RFC test vectors in totp.test.ts.

const STEP_SECONDS = 30;
const DIGITS = 6;
const B32 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";

export function base32Encode(bytes: Buffer): string {
  let bits = 0;
  let value = 0;
  let out = "";
  for (const byte of bytes) {
    value = (value << 8) | byte;
    bits += 8;
    while (bits >= 5) {
      out += B32[(value >>> (bits - 5)) & 31];
      bits -= 5;
    }
  }
  if (bits > 0) {
    out += B32[(value << (5 - bits)) & 31];
  }
  return out;
}

export function base32Decode(input: string): Buffer {
  const clean = input.toUpperCase().replace(/[\s-]/g, "").replace(/=+$/, "");
  let bits = 0;
  let value = 0;
  const out: number[] = [];
  for (const ch of clean) {
    const idx = B32.indexOf(ch);
    if (idx < 0) {
      throw new Error("invalid_base32");
    }
    value = (value << 5) | idx;
    bits += 5;
    if (bits >= 8) {
      out.push((value >>> (bits - 8)) & 255);
      bits -= 8;
    }
  }
  return Buffer.from(out);
}

export function generateTotpSecret(): Buffer {
  return crypto.randomBytes(20);
}

// 32 base32 characters in groups of four, easy to type into an authenticator app.
export function formatSecret(secret: Buffer): string {
  return base32Encode(secret).replace(/(.{4})/g, "$1 ").trim();
}

export function hotp(secret: Buffer, counter: number, digits = DIGITS): string {
  const buf = Buffer.alloc(8);
  buf.writeBigUInt64BE(BigInt(counter));
  const mac = crypto.createHmac("sha1", secret).update(buf).digest();
  const offset = mac[mac.length - 1] & 0x0f;
  const bin =
    ((mac[offset] & 0x7f) << 24) | (mac[offset + 1] << 16) | (mac[offset + 2] << 8) | mac[offset + 3];
  return String(bin % 10 ** digits).padStart(digits, "0");
}

export function currentStep(nowMs: number = Date.now()): number {
  return Math.floor(nowMs / 1000 / STEP_SECONDS);
}

export function totpCode(secret: Buffer, nowMs: number = Date.now()): string {
  return hotp(secret, currentStep(nowMs));
}

function safeEqual(a: string, b: string): boolean {
  const ab = Buffer.from(a);
  const bb = Buffer.from(b);
  return ab.length === bb.length && crypto.timingSafeEqual(ab, bb);
}

// Returns the time step the code belongs to, or null. One step either side is accepted (clock drift
// between phone and server). A step at or before `lastUsedStep` is refused, so a code that was just
// used (or sniffed) cannot be replayed within its validity window.
export function verifyTotp(
  secret: Buffer,
  code: string,
  options: { nowMs?: number; lastUsedStep?: number; window?: number } = {}
): number | null {
  const clean = code.replace(/\s/g, "");
  if (!/^\d{6}$/.test(clean)) {
    return null;
  }
  const step = currentStep(options.nowMs ?? Date.now());
  const window = options.window ?? 1;
  const last = options.lastUsedStep ?? -1;
  let matched: number | null = null;
  // Always check every candidate (no early exit) so timing does not reveal which step matched.
  for (let s = step - window; s <= step + window; s += 1) {
    if (safeEqual(hotp(secret, s), clean) && s > last && matched === null) {
      matched = s;
    }
  }
  return matched;
}

export function otpauthUri(secret: Buffer, account: string, issuer: string): string {
  const label = `${encodeURIComponent(issuer)}:${encodeURIComponent(account)}`;
  const params = new URLSearchParams({
    secret: base32Encode(secret),
    issuer,
    algorithm: "SHA1",
    digits: String(DIGITS),
    period: String(STEP_SECONDS)
  });
  return `otpauth://totp/${label}?${params.toString()}`;
}

// --- storage helpers: the secret is encrypted at rest (AES-256-GCM) with a key derived from the
// server's session secret, so a copy of the database alone does not reveal it.

function deriveKey(masterSecret: string, purpose: string): Buffer {
  return Buffer.from(crypto.hkdfSync("sha256", masterSecret, "ha-gatekeeper-totp", purpose, 32));
}

export function encryptSecret(secret: Buffer, masterSecret: string): string {
  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv("aes-256-gcm", deriveKey(masterSecret, "enc"), iv);
  const ct = Buffer.concat([cipher.update(secret), cipher.final()]);
  return ["v1", iv.toString("base64url"), cipher.getAuthTag().toString("base64url"), ct.toString("base64url")].join(":");
}

// Throws when the value was not written with this master secret (e.g. ADMIN_SESSION_SECRET changed).
export function decryptSecret(stored: string, masterSecret: string): Buffer {
  const [version, iv, tag, ct] = stored.split(":");
  if (version !== "v1" || !iv || !tag || !ct) {
    throw new Error("bad_format");
  }
  const decipher = crypto.createDecipheriv("aes-256-gcm", deriveKey(masterSecret, "enc"), Buffer.from(iv, "base64url"));
  decipher.setAuthTag(Buffer.from(tag, "base64url"));
  return Buffer.concat([decipher.update(Buffer.from(ct, "base64url")), decipher.final()]);
}

// --- recovery codes: 10 single-use codes like "K7QF-2M9X-ABCD"; only keyed hashes are stored.

export function generateRecoveryCodes(count = 10): string[] {
  const codes: string[] = [];
  for (let i = 0; i < count; i += 1) {
    const raw = base32Encode(crypto.randomBytes(8)).slice(0, 12);
    codes.push(`${raw.slice(0, 4)}-${raw.slice(4, 8)}-${raw.slice(8, 12)}`);
  }
  return codes;
}

// Codes use letters only (no digits 0, 1), so a typed 0 or 1 can only mean the letter O or I.
export function normalizeRecoveryCode(input: string): string {
  return input.toUpperCase().replace(/[\s-]/g, "").replace(/0/g, "O").replace(/1/g, "I");
}

export function hashRecoveryCode(code: string, masterSecret: string): string {
  return crypto.createHmac("sha256", deriveKey(masterSecret, "recovery")).update(normalizeRecoveryCode(code)).digest("hex");
}

export function looksLikeRecoveryCode(input: string): boolean {
  return /^[A-Z2-7]{12}$/.test(normalizeRecoveryCode(input));
}
