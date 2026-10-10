// Operator tool, run inside the container by `gatekeeper 2fa-reset`:
//   node dist/totpCli.js status   shows whether two-factor is on
//   node dist/totpCli.js reset    switches it off (use when the phone AND the recovery codes are lost)
// Needs shell access to the server, which is the point: only someone who can already control the
// server (and could read .env) can turn the second factor off this way. The password still applies.
import { clearTotpState, loadTotpState } from "./adminTotp.js";
import { prisma } from "./db.js";

const command = process.argv[2] ?? "status";

try {
  const state = await loadTotpState();
  if (command === "status") {
    process.stdout.write(state ? `enabled (${state.recoveryHashes.length} recovery codes left)\n` : "disabled\n");
  } else if (command === "reset") {
    await clearTotpState();
    process.stdout.write(state ? "Two-factor authentication is now OFF.\n" : "Two-factor authentication was already off.\n");
  } else {
    process.stderr.write("usage: totpCli.js status|reset\n");
    process.exitCode = 2;
  }
} catch (error) {
  process.stderr.write(`failed: ${error instanceof Error ? error.message : String(error)}\n`);
  process.exitCode = 1;
} finally {
  await prisma.$disconnect();
}
