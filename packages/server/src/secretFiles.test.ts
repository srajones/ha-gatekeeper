import assert from "node:assert/strict";
import test from "node:test";
import { loadSecretFiles } from "./secretFiles.js";

const files: Record<string, string> = {
  "/run/secrets/ha_token": "file-token\n",
  "/run/secrets/admin_password": "file-admin-password",
  "/run/secrets/empty": "  \n"
};
const reader = (path: string) => {
  if (path in files) {
    return files[path] as string;
  }
  const error = new Error("nope") as NodeJS.ErrnoException;
  error.code = path.endsWith("dir") ? "EISDIR" : "ENOENT";
  throw error;
};

test("a *_FILE variable is replaced by the file's content", () => {
  const raw = { HA_TOKEN_FILE: "/run/secrets/ha_token", ADMIN_PASSWORD_FILE: "/run/secrets/admin_password", PORT: "8080" };
  const out = loadSecretFiles(raw, reader);

  assert.equal(out.HA_TOKEN, "file-token\n");
  assert.equal(out.ADMIN_PASSWORD, "file-admin-password");
  assert.equal(out.PORT, "8080");
  assert.equal(out.HA_TOKEN_FILE, undefined);
});

test("the input environment is never modified", () => {
  const raw = { HA_TOKEN_FILE: "/run/secrets/ha_token" };
  loadSecretFiles(raw, reader);

  assert.deepEqual(raw, { HA_TOKEN_FILE: "/run/secrets/ha_token" });
});

test("variables without a *_FILE counterpart pass through untouched", () => {
  const raw = { HA_TOKEN: "plain-token", API_KEY_HASH_SECRET: "plain-secret-0123456789" };

  assert.deepEqual(loadSecretFiles(raw, reader), raw);
});

test("setting both the variable and its *_FILE is rejected", () => {
  assert.throws(
    () => loadSecretFiles({ HA_TOKEN: "x", HA_TOKEN_FILE: "/run/secrets/ha_token" }, reader),
    /HA_TOKEN and HA_TOKEN_FILE are both set/
  );
});

test("an empty *_FILE variable is ignored", () => {
  assert.deepEqual(loadSecretFiles({ HA_TOKEN_FILE: "  ", HA_TOKEN: "x" }, reader), { HA_TOKEN_FILE: "  ", HA_TOKEN: "x" });
});

test("unreadable, directory and empty files give clear errors without leaking content", () => {
  assert.throws(() => loadSecretFiles({ HA_TOKEN_FILE: "/missing" }, reader), /HA_TOKEN_FILE: cannot read \/missing \(ENOENT\)/);
  assert.throws(() => loadSecretFiles({ HA_TOKEN_FILE: "/some/dir" }, reader), /EISDIR\) \(it is a directory/);
  assert.throws(() => loadSecretFiles({ HA_TOKEN_FILE: "/run/secrets/empty" }, reader), /is empty/);
});
