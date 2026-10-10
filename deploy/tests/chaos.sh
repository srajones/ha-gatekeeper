#!/usr/bin/env bash
#
# Chaos test for an INSTALLED HA Gatekeeper: breaks it on purpose in the ways real servers break and checks that it
# heals itself without help, and how fast. It only ever does things that are undone at the end (a killed container,
# a hung process, a deleted container, an unreadable database file) and never touches Home Assistant, your data
# contents, your other containers or the firewall.
#
#   sudo bash deploy/tests/chaos.sh [--app-dir DIR] [--only a,b,...] [--with-docker-restart]
#
# Scenarios: kill (SIGKILL), restart (docker restart), hang (the node process frozen with SIGSTOP),
#            remove (docker rm -f), stop (docker stop, an operator's mistake),
#            diskfull (the data folder fills up; only with --with-diskfull, see below),
#            docker (restart the Docker daemon; only with --with-docker-restart, needs systemd)
#
# --with-diskfull briefly stops the app, mounts a tiny RAM disk over its data folder (a copy of the database goes
# along), fills it, checks that the app notices and restarts itself, then puts everything back, including the
# changes made meanwhile. It is restored even if you press Ctrl-C.
# The hang/remove/db/stop scenarios need the watchdog running (systemd timer or cron); they are skipped with a
# message when its heartbeat is stale.

set -uo pipefail
APP_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ONLY=""; WITH_DOCKER=false; WITH_DISKFULL=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-dir) APP_DIR="$2"; shift ;;
    --only) ONLY="$2"; shift ;;
    --with-docker-restart) WITH_DOCKER=true ;;
    --with-diskfull) WITH_DISKFULL=true ;;
    *) echo "unknown option $1"; exit 2 ;;
  esac
  shift
done
STATE_DIR="${GK_STATE_DIR:-/var/lib/ha-gatekeeper}"
C=ha-gatekeeper
pass=0; failn=0; skipped=0
ok()   { echo "  PASS: $*"; pass=$((pass + 1)); }
bad()  { echo "  FAIL: $*"; failn=$((failn + 1)); }
skip() { echo "  SKIP: $*"; skipped=$((skipped + 1)); }
want() { [[ -z "$ONLY" || ",$ONLY," == *",$1,"* ]]; }

dc() { ( cd "$APP_DIR" && docker compose "$@" ); }
url() {
  local port
  port="$(grep -E '^GATEKEEPER_PORT=' "$APP_DIR/.env" 2>/dev/null | tail -n1 | cut -d= -f2- | tr -d '"')"
  printf 'http://127.0.0.1:%s' "${port:-8080}"
}
# The host PID of the node process (not tini or the shell wrapper above it).
app_pids() { docker top "$C" -eo pid,args 2>/dev/null | awk '/node dist\/index\.js/ && !/awk/ {print $1}'; }
healthy() { [[ "$(curl -fsS -m 4 "$(url)/healthz" 2>/dev/null)" == *'"ok":true'* ]]; }
state() { docker inspect -f '{{.State.Status}}/{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$C" 2>/dev/null || echo "missing/"; }
restarts() { docker inspect -f '{{.RestartCount}}' "$C" 2>/dev/null || echo -1; }
started() { docker inspect -f '{{.State.StartedAt}}' "$C" 2>/dev/null || echo none; }

# wait_healthy SECONDS -> prints the seconds it took, returns 0 if healthy in time
wait_healthy() {
  local limit="$1" t0 now
  t0="$(date +%s)"
  while true; do
    if healthy && [[ "$(state)" == running/healthy ]]; then echo $(( $(date +%s) - t0 )); return 0; fi
    now="$(date +%s)"
    (( now - t0 >= limit )) && { echo "$limit"; return 1; }
    sleep 2
  done
}

# The watchdog never takes more than a few corrective actions an hour (so it cannot thrash). Each scenario here
# causes some, so the budget is cleared before each one that depends on the watchdog.
reset_budget() { : >"$STATE_DIR/actions.log" 2>/dev/null || true; rm -f "$STATE_DIR"/fail.* "$STATE_DIR/last_action" 2>/dev/null || true; }

watchdog_alive() {
  local hb
  hb="$(cat "$STATE_DIR/heartbeat" 2>/dev/null || echo 0)"
  [[ "$hb" =~ ^[0-9]+$ ]] && (( $(date +%s) - hb < 180 ))
}

[[ $EUID -eq 0 ]] || { echo "run as root"; exit 2; }
command -v docker >/dev/null || { echo "docker not found"; exit 2; }
docker inspect "$C" >/dev/null 2>&1 || { echo "container $C not found: is Gatekeeper installed in $APP_DIR?"; exit 2; }

echo "Before: $(state), restarts so far: $(restarts), /healthz: $(healthy && echo ok || echo NOT ok)"
healthy || { echo "It is not healthy to begin with; fix that first (gatekeeper verify)."; exit 2; }

if want kill; then
  echo "kill: SIGKILL the app process from outside (what the kernel's out-of-memory killer does)"
  # NOT `docker kill`: Docker treats that as an operator stopping the container and does not restart it.
  # A process killed by the kernel is a crash, and the restart policy brings it back.
  was_started="$(started)"
  node_pids="$(app_pids)"
  if [[ -z "$node_pids" ]]; then bad "could not find the app process (node dist/index.js) in the container"; else
    # shellcheck disable=SC2086
    kill -KILL $node_pids
    secs="$(wait_healthy 120)" && ok "healthy again after ${secs}s (Docker's restart policy)" || bad "not healthy 120s after SIGKILL ($(state))"
    [[ "$(started)" != "$was_started" ]] && ok "a new process was started" || bad "the container was not restarted"
  fi
fi

if want restart; then
  echo "restart: docker restart (what an operator or the watchdog does)"
  docker restart "$C" >/dev/null 2>&1
  secs="$(wait_healthy 120)" && ok "healthy again after ${secs}s" || bad "not healthy 120s after a restart ($(state))"
fi

if want hang; then
  echo "hang: freeze the app with SIGSTOP (alive but answering nothing, like a deadlock)"
  if ! watchdog_alive; then skip "the watchdog is not running (no recent heartbeat in $STATE_DIR)"; else
    reset_budget
    # PID 1 in the container is tini, then a shell; freezing those alone would leave node answering. Freeze node itself.
    node_pids="$(app_pids)"
    [[ -n "$node_pids" ]] || bad "could not find the app process (node dist/index.js) in the container"
    # shellcheck disable=SC2086
    [[ -z "$node_pids" ]] || kill -STOP $node_pids
    t0="$(date +%s)"; was="$(started)"
    echo "  (waiting for Docker to call it unhealthy and the watchdog to restart it; up to 8 minutes)"
    secs="$(wait_healthy 480)" && [[ "$(started)" != "$was" ]] && ok "restarted by the watchdog and healthy after $(( $(date +%s) - t0 ))s" || bad "not healed within 8 minutes ($(state))"
    # shellcheck disable=SC2086
    [[ -z "$node_pids" ]] || kill -CONT $node_pids 2>/dev/null || true
  fi
fi

if want remove; then
  echo "remove: docker rm -f (the container is simply gone)"
  if ! watchdog_alive; then skip "the watchdog is not running"; else
    reset_budget
    t0="$(date +%s)"
    docker rm -f "$C" >/dev/null 2>&1
    secs="$(wait_healthy 360)" && ok "recreated by the watchdog and healthy after $(( $(date +%s) - t0 ))s" || bad "not back within 6 minutes ($(state))"
  fi
fi

if want stop; then
  echo "stop: docker stop (someone stops it by mistake; 'gatekeeper stop' pauses the watchdog, this does not)"
  if ! watchdog_alive; then skip "the watchdog is not running"; else
    reset_budget
    t0="$(date +%s)"
    docker stop "$C" >/dev/null 2>&1
    secs="$(wait_healthy 360)" && ok "started again by the watchdog, healthy after $(( $(date +%s) - t0 ))s" || bad "not back within 6 minutes ($(state))"
  fi
fi

if want diskfull; then
  echo "diskfull: the data folder runs out of space (writes fail; reads still work)"
  data="$(grep -E '^GATEKEEPER_DATA_DIR=' "$APP_DIR/.env" 2>/dev/null | tail -n1 | cut -d= -f2- | tr -d '"')"; data="${data:-./data}"
  [[ "$data" == /* ]] || data="$APP_DIR/$data"
  if ! $WITH_DISKFULL; then skip "add --with-diskfull to run this (it briefly stops the app and mounts a RAM disk over $data)"; \
  elif ! command -v mount >/dev/null || ! command -v mountpoint >/dev/null; then skip "mount is not available"; else
    backup="$data.chaos-backup"
    restore() {
      docker stop "$C" >/dev/null 2>&1 || true
      rm -f "$data/.chaos-fill"
      if mountpoint -q "$data"; then
        cp -a "$data/." "$backup/" 2>/dev/null || true
        umount "$data"
      fi
      if [[ -d "$backup" ]]; then cp -a "$backup/." "$data/"; rm -rf "$backup"; fi
      docker start "$C" >/dev/null 2>&1 || true
    }
    trap restore EXIT INT TERM
    docker stop "$C" >/dev/null 2>&1
    rm -rf "$backup"; cp -a "$data" "$backup"
    mount -t tmpfs -o size=4m,mode=0750,uid=1001,gid=1001 tmpfs "$data" && cp -a "$backup/." "$data/"
    docker start "$C" >/dev/null 2>&1
    secs="$(wait_healthy 120)" && ok "healthy on the small RAM disk (${secs}s)" || bad "did not start on the RAM disk ($(state))"
    was="$(started)"
    # fill what is left; the app's own write probe then fails
    dd if=/dev/zero of="$data/.chaos-fill" bs=64k status=none 2>/dev/null || true
    t0="$(date +%s)"; seen503=false
    for _ in $(seq 1 45); do
      code="$(curl -s -m 4 -o /dev/null -w '%{http_code}' "$(url)/healthz" 2>/dev/null)"
      [[ "$code" == 503 ]] && { seen503=true; break; }
      sleep 3
    done
    $seen503 && ok "/healthz turned 503 after $(( $(date +%s) - t0 ))s (the failed write was noticed)" || bad "/healthz stayed OK on a full disk"
    echo "  (waiting for the app to give up and restart itself, about 90 s of failures)"
    for _ in $(seq 1 60); do [[ "$(started)" != "$was" ]] && break; sleep 3; done
    [[ "$(started)" != "$was" ]] && ok "the app restarted itself after $(( $(date +%s) - t0 ))s" || bad "no self-restart within 3 minutes"
    rm -f "$data/.chaos-fill"
    secs="$(wait_healthy 180)" && ok "healthy again ${secs}s after space was freed" || bad "not healthy after freeing space ($(state))"
    restore
    trap - EXIT INT TERM
    secs="$(wait_healthy 120)" && ok "everything put back, healthy after ${secs}s" || bad "not healthy after restoring ($(state))"
  fi
fi

if want docker; then
  echo "docker: restart the Docker daemon"
  if ! $WITH_DOCKER; then skip "add --with-docker-restart to run this (it briefly stops ALL containers on the server)"; \
  elif ! command -v systemctl >/dev/null || [[ ! -d /run/systemd/system ]]; then skip "needs systemd"; else
    t0="$(date +%s)"
    systemctl restart docker
    secs="$(wait_healthy 300)" && ok "healthy again after ${secs}s (containers came back with the daemon)" || bad "not healthy 5 minutes after the daemon restart ($(state))"
  fi
fi

echo
echo "RESULT: $pass passed, $failn failed, $skipped skipped"
[[ $failn -eq 0 ]]
