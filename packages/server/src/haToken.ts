import fs from "node:fs";
import { env } from "./env.js";

// The Home Assistant token, read through an mtime cache so a rotated secret file is picked up
// without a restart. Falls back to the value read at startup if the file cannot be read.
let cached: { mtimeMs: number; value: string } | null = null;

export function getHaToken(): string {
  const file = process.env.HA_TOKEN_FILE?.trim();
  if (!file || env.HA_GATEKEEPER_ADDON) {
    return env.HA_TOKEN;
  }
  try {
    const { mtimeMs } = fs.statSync(file);
    if (!cached || cached.mtimeMs !== mtimeMs) {
      const value = fs.readFileSync(file, "utf8").trim();
      cached = value ? { mtimeMs, value } : null;
    }
    return cached?.value ?? env.HA_TOKEN;
  } catch {
    return env.HA_TOKEN;
  }
}
