import fs from "node:fs";

// Secrets that may be supplied as files (`NAME_FILE=/run/secrets/name`) instead of as plain
// environment variables. A file mounted read-only into the container keeps the value out of
// `docker inspect` and /proc/<pid>/environ, which is how the VPS installer deploys them.
export const SECRET_FILE_KEYS = ["HA_TOKEN", "ADMIN_PASSWORD", "ADMIN_SESSION_SECRET", "API_KEY_HASH_SECRET"] as const;

type RawEnv = Record<string, string | undefined>;

const defaultReader = (filePath: string): string => fs.readFileSync(filePath, "utf8");

/**
 * Returns a copy of `raw` in which every `NAME_FILE` has been replaced by `NAME` holding the
 * file's content. The input (normally `process.env`) is never modified, so the secret values do
 * not end up in the process environment. Error messages name the file, never its content.
 */
export function loadSecretFiles(raw: RawEnv, readFile: (filePath: string) => string = defaultReader): RawEnv {
  const out: RawEnv = { ...raw };

  for (const key of SECRET_FILE_KEYS) {
    const fileKey = `${key}_FILE`;
    const filePath = raw[fileKey]?.trim();
    if (!filePath) {
      continue;
    }

    if (raw[key]?.trim()) {
      throw new Error(`${key} and ${fileKey} are both set; use only one of them`);
    }

    let content: string;
    try {
      content = readFile(filePath);
    } catch (error) {
      const code = (error as NodeJS.ErrnoException).code;
      const hint = code === "EISDIR" ? " (it is a directory: run the installer again to recreate it)" : "";
      throw new Error(`${fileKey}: cannot read ${filePath}${code ? ` (${code})` : ""}${hint}`);
    }

    if (!content.trim()) {
      throw new Error(`${fileKey}: ${filePath} is empty`);
    }

    out[key] = content;
    delete out[fileKey];
  }

  return out;
}
