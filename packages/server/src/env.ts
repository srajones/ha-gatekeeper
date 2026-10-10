import dotenv from "dotenv";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { resolveRuntimeConfig } from "./runtimeConfig.js";
import { loadSecretFiles } from "./secretFiles.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
dotenv.config({ path: path.join(__dirname, "../.env") });

// Secrets may arrive as NAME_FILE=/path (see secretFiles.ts); the values are not copied into process.env.
export const env = resolveRuntimeConfig(loadSecretFiles(process.env));
export const isProd = env.NODE_ENV === "production";
