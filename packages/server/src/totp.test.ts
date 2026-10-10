import assert from "node:assert/strict";
import test from "node:test";
import {
  base32Decode,
  base32Encode,
  decryptSecret,
  encryptSecret,
  generateRecoveryCodes,
  hashRecoveryCode,
  hotp,
  looksLikeRecoveryCode,
  otpauthUri,
  verifyTotp
} from "./totp.js";

// RFC 6238 appendix B, SHA-1 secret "12345678901234567890" (the table lists 8 digits; the last 6 are ours).
const rfcSecret = Buffer.from("12345678901234567890", "ascii");
const vectors: Array<[number, string]> = [
  [59, "287082"],
  [1111111109, "081804"],
  [1111111111, "050471"],
  [1234567890, "005924"],
  [2000000000, "279037"],
  [20000000000, "353130"]
];

test("TOTP matches the RFC 6238 test vectors", () => {
  for (const [seconds, expected] of vectors) {
    assert.equal(hotp(rfcSecret, Math.floor(seconds / 30)), expected, `t=${seconds}`);
  }
});

test("HOTP matches the RFC 4226 test vectors", () => {
  const expected = ["755224", "287082", "359152", "969429", "338314", "254676", "287922", "162583", "399871", "520489"];
  expected.forEach((code, counter) => assert.equal(hotp(rfcSecret, counter), code));
});

test("base32 round-trips and accepts spaces, dashes and lower case", () => {
  const raw = Buffer.from("00112233445566778899aabbccddeeff00112233", "hex");
  const text = base32Encode(raw);
  assert.equal(base32Decode(text).toString("hex"), raw.toString("hex"));
  assert.equal(base32Decode(text.toLowerCase().replace(/(.{4})/g, "$1 ")).toString("hex"), raw.toString("hex"));
  assert.throws(() => base32Decode("not*base32"), /invalid_base32/);
  assert.equal(base32Encode(Buffer.from("foobar")), "MZXW6YTBOI");
});

test("a code is accepted one step either side, not two", () => {
  const now = 1_700_000_000_000;
  const step = Math.floor(now / 1000 / 30);
  assert.equal(verifyTotp(rfcSecret, hotp(rfcSecret, step), { nowMs: now }), step);
  assert.equal(verifyTotp(rfcSecret, hotp(rfcSecret, step - 1), { nowMs: now }), step - 1);
  assert.equal(verifyTotp(rfcSecret, hotp(rfcSecret, step + 1), { nowMs: now }), step + 1);
  assert.equal(verifyTotp(rfcSecret, hotp(rfcSecret, step - 2), { nowMs: now }), null);
  assert.equal(verifyTotp(rfcSecret, hotp(rfcSecret, step + 2), { nowMs: now }), null);
});

test("a used code cannot be replayed, including a neighbouring older one", () => {
  const now = 1_700_000_000_000;
  const step = Math.floor(now / 1000 / 30);
  const code = hotp(rfcSecret, step);
  assert.equal(verifyTotp(rfcSecret, code, { nowMs: now, lastUsedStep: step }), null);
  assert.equal(verifyTotp(rfcSecret, hotp(rfcSecret, step - 1), { nowMs: now, lastUsedStep: step }), null);
  assert.equal(verifyTotp(rfcSecret, hotp(rfcSecret, step + 1), { nowMs: now, lastUsedStep: step }), step + 1);
});

test("malformed codes are rejected without throwing", () => {
  for (const bad of ["", "12345", "1234567", "12345a", "１２３４５６", "123 45", "-12345", "000000 "]) {
    const result = verifyTotp(rfcSecret, bad, { nowMs: 59_000 });
    assert.ok(result === null || bad === "000000 ", `bad=${JSON.stringify(bad)}`);
  }
  assert.equal(verifyTotp(rfcSecret, "287 082", { nowMs: 59_000 }), 1, "spaces inside are tolerated (apps display 287 082)");
});

test("the secret is encrypted at rest and only the same master secret opens it", () => {
  const stored = encryptSecret(rfcSecret, "master-secret-0123456789abcdef0123");
  assert.ok(!stored.includes(rfcSecret.toString("base64url")));
  assert.equal(decryptSecret(stored, "master-secret-0123456789abcdef0123").toString("ascii"), "12345678901234567890");
  assert.throws(() => decryptSecret(stored, "another-master-secret-0123456789ab"));
  const tampered = stored.slice(0, -2) + (stored.endsWith("AA") ? "BB" : "AA");
  assert.throws(() => decryptSecret(tampered, "master-secret-0123456789abcdef0123"));
  assert.throws(() => decryptSecret("garbage", "master-secret-0123456789abcdef0123"));
  assert.notEqual(encryptSecret(rfcSecret, "m"), encryptSecret(rfcSecret, "m"), "fresh IV each time");
});

test("recovery codes: 10 unique, readable, and hashed with the master secret", () => {
  const codes = generateRecoveryCodes();
  assert.equal(codes.length, 10);
  assert.equal(new Set(codes).size, 10);
  for (const code of codes) {
    assert.match(code, /^[A-Z2-7]{4}-[A-Z2-7]{4}-[A-Z2-7]{4}$/);
    assert.ok(looksLikeRecoveryCode(code));
    assert.ok(looksLikeRecoveryCode(code.toLowerCase().replace(/-/g, " ")));
  }
  const a = hashRecoveryCode(codes[0], "master");
  assert.equal(a, hashRecoveryCode(codes[0].toLowerCase().replace(/-/g, ""), "master"));
  assert.notEqual(a, hashRecoveryCode(codes[0], "other"));
  assert.notEqual(a, hashRecoveryCode(codes[1], "master"));
  assert.equal(hashRecoveryCode("ABCO-IIII-OOOO", "m"), hashRecoveryCode("abc0-1111-0000", "m"), "0/1 typed for the letters O/I");
  assert.ok(!looksLikeRecoveryCode("123456"));
});

test("otpauth URI carries the standard parameters", () => {
  const uri = otpauthUri(rfcSecret, "admin", "HA Gatekeeper");
  assert.ok(uri.startsWith("otpauth://totp/HA%20Gatekeeper:admin?"));
  const params = new URL(uri).searchParams;
  assert.equal(params.get("secret"), base32Encode(rfcSecret));
  assert.equal(params.get("issuer"), "HA Gatekeeper");
  assert.equal(params.get("digits"), "6");
  assert.equal(params.get("period"), "30");
});
