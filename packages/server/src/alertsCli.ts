// Operator tool, run inside the container by `gatekeeper alerts test`:
//   node dist/alertsCli.js status   which channels are set up (secrets are never printed)
//   node dist/alertsCli.js test     send a test message through every channel and say what happened
import { getAlertConfig } from "./alertConfig.js";
import { sendAlert } from "./alerts.js";

const command = process.argv[2] ?? "status";
const config = getAlertConfig();

if (command === "status") {
  for (const c of config.channels) {
    process.stdout.write(`${c.name.padEnd(9)} ${c.configured ? "on " : c.problem ? "BAD" : "off"}  ${c.target}${c.problem ? `  [${c.problem}]` : ""}\n`);
  }
} else if (command === "test") {
  const active = config.channels.filter((c) => c.configured);
  if (active.length === 0) {
    process.stdout.write("No alert channel is set up. Run: sudo gatekeeper alerts\n");
    process.exitCode = 1;
  } else {
    const results = await sendAlert(config, {
      kind: "test",
      title: "Test alert",
      body: "This is a test from HA Gatekeeper. If you can read this, alerts about Home Assistant being unreachable will reach you."
    });
    for (const r of results) {
      process.stdout.write(`${r.channel.padEnd(9)} ${r.ok ? "delivered" : `FAILED: ${r.error}`}\n`);
    }
    process.exitCode = results.every((r) => r.ok) ? 0 : 1;
  }
} else {
  process.stderr.write("usage: alertsCli.js status|test\n");
  process.exitCode = 2;
}
