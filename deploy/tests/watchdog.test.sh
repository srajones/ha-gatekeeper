#!/usr/bin/env bash
# Offline tests for deploy/watchdog.sh with a shimmed docker (needs node for two tiny fake servers). Run: bash deploy/tests/watchdog.test.sh
# Deterministic watchdog logic tests using shimmed docker/systemctl/service and fake HTTP servers.
# Scratch-only, not part of the repo.
if ! command -v node >/dev/null 2>&1; then
  echo "SKIPPED: these tests need node (for the two tiny fake HTTP servers) and it is not installed here."
  echo "         Install node (apt install nodejs) to run them. Nothing was tested."
  exit 0
fi
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"; SCR="$(mktemp -d)"
T=$SCR/shimtest; rm -rf "$T"; mkdir -p "$T/bin" "$T/app" "$T/state"
WD="$REPO"/deploy/watchdog.sh
pass=0; failn=0
ok()  { echo "  PASS: $*"; pass=$((pass+1)); }
bad() { echo "  FAIL: $*"; failn=$((failn+1)); }

# ---- shims -------------------------------------------------------------------------------
cat > "$T/bin/docker" <<'EOF'
#!/usr/bin/env bash
T="$(dirname "$(dirname "$(readlink -f "$0")")")"
echo "docker $*" >> "$T/calls.log"
case "$1" in
  info) [[ -f "$T/docker_down" ]] && exit 1; exit 0 ;;
  inspect)
    name="${@: -1}"
    [[ -f "$T/state.$name" ]] || { echo "Error: No such object: $name" >&2; exit 1; }
    cat "$T/state.$name"; exit 0 ;;
  compose)
    if [[ "$*" == *"--no-build"* && -f "$T/image_missing" ]]; then echo "pull access denied" >&2; exit 1; fi
    exit 0 ;;
  restart|start|image|builder) exit 0 ;;
esac
exit 0
EOF
for c in systemctl service; do
cat > "$T/bin/$c" <<'EOF'
#!/usr/bin/env bash
T="$(dirname "$(dirname "$(readlink -f "$0")")")"
echo "$(basename "$0") $*" >> "$T/calls.log"; exit 0
EOF
done
chmod +x "$T"/bin/*

# ---- fake gatekeeper /healthz and a webhook receiver --------------------------------------
cat > "$T/servers.mjs" <<'EOF'
import http from "node:http"; import fs from "node:fs";
const T = process.argv[2];
http.createServer((q, r) => {
  if (fs.existsSync(`${T}/http_ok`)) { r.writeHead(200, {"content-type":"application/json"}); r.end('{"ok":true}'); }
  else { r.writeHead(503); r.end("down"); }
}).listen(18999, "127.0.0.1");
http.createServer((q, r) => {
  let b = ""; q.on("data", d => b += d); q.on("end", () => { fs.appendFileSync(`${T}/webhook.log`, b + "\n"); r.writeHead(200); r.end("ok"); });
}).listen(19999, "127.0.0.1");
EOF
(nohup node "$T/servers.mjs" "$T" > "$T/servers.log" 2>&1 &); sleep 1

# ---- environment for the watchdog ----------------------------------------------------------
cat > "$T/app/.env" <<EOF
GATEKEEPER_PORT="18999"
ALERT_WEBHOOK_URL="http://127.0.0.1:19999/hook"
EOF
export PATH="$T/bin:$PATH" GK_APP_DIR="$T/app" GK_STATE_DIR="$T/state" GK_WATCHDOG_LOG="$T/wd.log"
export GK_FAIL_THRESHOLD=1 GK_GRACE_SECONDS=0 GK_PROBE_TIMEOUT=2 GK_STUCK_ALERT_AFTER=0 GK_MAX_ACTIONS_PER_HOUR=6
running_unhealthy="running|unhealthy|false|0|$(date -u +%FT%T.000000000Z)"
running_healthy="running|healthy|false|0|$(date -u +%FT%T.000000000Z)"
run() { "$WD" >/dev/null 2>&1; }
calls() { grep -c "$1" "$T/calls.log" 2>/dev/null || echo 0; }

echo "A: persistent failure walks the ladder: restart, restart, recreate, recreate, recreate-all, then hits the hourly cap"
echo "$running_unhealthy" > "$T/state.ha-gatekeeper"; rm -f "$T/http_ok"; : > "$T/calls.log"
for i in $(seq 1 9); do run; done
echo "  actions.log:"; sed 's/^/    /' "$T/state/actions.log"
seq_actual="$(awk '{print $3}' "$T/state/actions.log" | paste -sd, -)"
[[ "$seq_actual" == "restart,restart,recreate,recreate,recreate-all,recreate-all" ]] && ok "ladder order and cap: $seq_actual" || bad "unexpected ladder: $seq_actual"
n_actions="$(wc -l < "$T/state/actions.log")"
(( n_actions == 6 )) && ok "exactly 6 actions in 9 runs (budget respected)" || bad "$n_actions actions recorded"
grep -q "action budget" "$T/wd.log" && ok "logged 'action budget used up' once capped" || bad "no budget log"
[[ "$(calls 'docker restart ha-gatekeeper')" == 2 ]] && ok "exactly 2 'docker restart' calls" || bad "restart calls: $(calls 'docker restart ha-gatekeeper')"
[[ "$(calls '^service docker restart')" == 1 || "$(calls '^systemctl restart docker')" == 1 ]] && ok "Docker daemon restarted exactly once as last resort" || bad "daemon restart count wrong: $(grep -E 'docker restart|service|systemctl' "$T/calls.log" | tr '\n' ';')"

echo "B: alerts are de-duplicated (one DOWN, one STILL DOWN), then exactly one RECOVERED"
down_n="$(grep -c '"text":"\[HA Gatekeeper @ [^"]*\] DOWN' "$T/webhook.log")"
still_n="$(grep -c 'STILL DOWN' "$T/webhook.log")"
[[ "$down_n" == 1 ]] && ok "exactly one DOWN alert across 9 failing runs" || bad "DOWN alerts: $down_n"
[[ "$still_n" == 1 ]] && ok "exactly one STILL DOWN alert" || bad "STILL DOWN alerts: $still_n"
echo "  regression: a container that is merely 'starting' after our restart is NOT 'recovered'"
echo "running|starting|false|0|$(date -u +%FT%T.000000000Z)" > "$T/state.ha-gatekeeper"; rm -f "$T/http_ok"
run; run
[[ "$(grep -c 'RECOVERED after' "$T/webhook.log")" == 0 ]] && ok "no RECOVERED alert while only 'starting'" || bad "premature RECOVERED alert"
echo "$running_healthy" > "$T/state.ha-gatekeeper"; touch "$T/http_ok"
run; run; run
rec_n="$(grep -c 'RECOVERED after' "$T/webhook.log")"
[[ "$rec_n" == 1 ]] && ok "exactly one RECOVERED alert, only after a passing check" || bad "RECOVERED alerts: $rec_n"
echo "  webhook payload sample: $(head -1 "$T/webhook.log" | cut -c1-200)"
jq -e '.text and .content and .message' "$T/webhook.log" >/dev/null 2>&1 && ok "payload is valid JSON with text+content+message (Slack/Discord compatible)" || bad "payload not valid JSON"

echo "C: healthy system -> silent and no actions"
: > "$T/calls.log"; before="$(wc -l < "$T/state/actions.log")"; : > "$T/wd.log"
run; run
[[ ! -s "$T/wd.log" ]] && ok "no log output when healthy" || bad "noisy: $(cat "$T/wd.log")"
[[ "$(wc -l < "$T/state/actions.log")" == "$before" ]] && ok "no new actions" || bad "action taken while healthy"
grep -qE '^docker (restart|compose)' "$T/calls.log" && bad "docker mutating call while healthy: $(cat "$T/calls.log")" || ok "no mutating docker calls"

echo "D: health 'starting' inside the Docker start period is left alone (no restart storms after boot)"
rm -f "$T/state/actions.log" "$T/state/fail."*; : > "$T/calls.log"; : > "$T/wd.log"
echo "running|starting|false|0|$(date -u +%FT%T.000000000Z)" > "$T/state.ha-gatekeeper"; rm -f "$T/http_ok"
run; run; run
[[ ! -s "$T/state/actions.log" ]] && ok "3 runs while 'starting': zero actions" || bad "acted during startup: $(cat "$T/state/actions.log")"
echo "  ...but 'starting' for far too long counts as stuck:"
echo "running|starting|false|0|$(date -u -d '-20 minutes' +%FT%T.000000000Z)" > "$T/state.ha-gatekeeper"
run; run
grep -q "never became healthy" "$T/wd.log" && ok "stuck-'starting' detected and acted on" || bad "stuck starting not detected: $(cat "$T/wd.log")"

echo "E: Docker daemon down -> start it, later restart it (rate-limited), alert on recovery"
rm -f "$T/state/"*; : > "$T/calls.log"; : > "$T/webhook.log"; : > "$T/wd.log"
touch "$T/docker_down"
run
grep -qE '^(service docker start|systemctl start docker)' "$T/calls.log" && ok "1st failed check: starts the daemon" || bad "no daemon start: $(cat "$T/calls.log")"
run
grep -qE '^(service docker restart|systemctl restart docker)' "$T/calls.log" && ok "2nd failed check: restarts the daemon" || bad "no daemon restart"
: > "$T/calls.log"; run; run
grep -qE '(restart docker)' "$T/calls.log" && bad "daemon restarted again within 10 min (not rate-limited)" || ok "further restarts rate-limited to 1 per 10 min"
rm -f "$T/docker_down"; echo "$running_healthy" > "$T/state.ha-gatekeeper"; touch "$T/http_ok"
run
grep -q "Docker daemon is responding again" "$T/wd.log" && ok "logged Docker recovery" || bad "no docker recovery log"
grep -q "RECOVERED: the Docker daemon" "$T/webhook.log" && ok "sent Docker recovery alert" || bad "no docker recovery alert"

echo "F: container missing -> brought up immediately (no threshold wait)"
rm -f "$T/state/"* "$T/state.ha-gatekeeper"; : > "$T/calls.log"; : > "$T/wd.log"
GK_FAIL_THRESHOLD=5 run
grep -q 'docker compose up -d --no-build' "$T/calls.log" && ok "tried 'up -d --no-build' first" || bad "calls: $(cat "$T/calls.log")"
grep -q "bringing the stack up" "$T/wd.log" && ok "acted on the very first run despite threshold=5" || bad "waited for threshold"
[[ "$(grep -c 'docker compose' "$T/calls.log")" == 1 ]] && ok "no needless second compose call when --no-build works" || bad "extra compose calls"
echo "  ...and when the image itself is gone (e.g. 'docker system prune -a'), it falls back to a build:"
rm -f "$T/state/"*; : > "$T/calls.log"; : > "$T/wd.log"; touch "$T/image_missing"
GK_FAIL_THRESHOLD=5 run
grep -q 'docker compose up -d --no-build' "$T/calls.log" && ok "first attempt used --no-build (and failed)" || bad "no --no-build attempt"
grep -E 'docker compose up -d --remove-orphans$' "$T/calls.log" >/dev/null && ok "second attempt is a full 'up' that can build" || bad "no build fallback: $(cat "$T/calls.log")"
grep -q "image missing" "$T/wd.log" && ok "logged why it is building" || bad "no explanation logged"
rm -f "$T/image_missing"

echo "G: proxy profile: caddy is watched too, and only a dead listener (not TLS/cert trouble) triggers a restart"
rm -f "$T/state/"*; : > "$T/calls.log"; : > "$T/wd.log"
printf 'GATEKEEPER_PORT="18999"\nCOMPOSE_PROFILES="proxy"\n' > "$T/app/.env"
echo "$running_healthy" > "$T/state.ha-gatekeeper"; echo "$running_healthy" > "$T/state.ha-gatekeeper-caddy"; touch "$T/http_ok"
run
grep -q "caddy: check failed" "$T/wd.log" && ok "caddy with nothing on :443 flagged" || bad "caddy not checked: $(cat "$T/wd.log")"
grep -q "caddy: .*restarting container" "$T/wd.log" && ok "caddy restarted after threshold" || bad "caddy not restarted"
echo "  now a listener that accepts connections but speaks no valid TLS (like a proxy still waiting on its certificate):"
(nohup node -e 'require("net").createServer(s=>s.on("error",()=>{})).listen(443,"127.0.0.1")' >/dev/null 2>&1 & echo $! > "$T/l443.pid"); sleep 1
rm -f "$T/state/"*; : > "$T/wd.log"; : > "$T/calls.log"
run; run
grep -q "caddy" "$T/wd.log" && bad "caddy touched despite listening: $(cat "$T/wd.log")" || ok "listening-but-no-cert caddy left alone (ACME retry back-off not reset)"
kill "$(cat "$T/l443.pid")" 2>/dev/null

echo "H: no .env / paused -> watchdog does nothing and exits 0"
rm -f "$T/state/"*; : > "$T/calls.log"; : > "$T/wd.log"
mv "$T/app/.env" "$T/app/.env.bak"; "$WD" >/dev/null 2>&1; rc=$?
[[ $rc == 0 ]] && ok "exit 0 without .env" || bad "exit $rc"
grep -q "not configured" "$T/wd.log" && ok "explains why" || bad "no explanation"
mv "$T/app/.env.bak" "$T/app/.env"

pkill -f "servers.mjs $T" 2>/dev/null
echo; echo "RESULT: $pass passed, $failn failed"
[[ $failn -eq 0 ]]
