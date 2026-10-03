#!/usr/bin/env bash
#
# HA Gatekeeper watchdog: detects failures and heals them. install.sh runs it every minute
# (systemd timer, or cron where systemd is missing). Safe to run by hand at any time.
#
# It only ever restarts or recreates containers (and, as a last resort, the Docker daemon).
# It never deletes data, volumes or images.
#
# Defence in depth
#   1. Docker            restart: unless-stopped restarts a crashed container within seconds.
#   2. This script       every minute: is Docker up, do the containers exist and run, does
#                        /healthz answer? If not it escalates restart -> recreate -> restart
#                        Docker, capped at GK_MAX_ACTIONS_PER_HOUR, and can send a webhook
#                        alert when things go down and when they recover.
#   3. ha-gatekeeper.service brings the whole stack up again at boot.
#
# `gatekeeper stop` (install.sh stop) pauses this script so an intentional stop stays stopped.

set -uo pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
APP_DIR="${GK_APP_DIR:-$(cd -P "$(dirname "$SELF")/.." && pwd)}"
STATE_DIR="${GK_STATE_DIR:-/var/lib/ha-gatekeeper}"
LOG_FILE="${GK_WATCHDOG_LOG:-/var/log/ha-gatekeeper-watchdog.log}"

FAIL_THRESHOLD="${GK_FAIL_THRESHOLD:-3}"                 # consecutive bad checks before acting
GRACE_SECONDS="${GK_GRACE_SECONDS:-120}"                 # quiet time after we restart something
MAX_ACTIONS_PER_HOUR="${GK_MAX_ACTIONS_PER_HOUR:-6}"
PROBE_TIMEOUT="${GK_PROBE_TIMEOUT:-8}"
STARTING_MAX_SECONDS="${GK_STARTING_MAX_SECONDS:-300}"   # 'starting' health for longer = stuck
STUCK_ALERT_AFTER="${GK_STUCK_ALERT_AFTER:-900}"
MIN_FREE_MB="${GK_MIN_FREE_MB:-1024}"
DC_TIMEOUT="${GK_DC_TIMEOUT:-600}"

GK_CONTAINER="ha-gatekeeper"
CADDY_CONTAINER="ha-gatekeeper-caddy"

# shellcheck source=deploy/lib.sh
source "$(dirname "$SELF")/lib.sh"

NOW="$(date +%s)"
HOSTNAME_LABEL="$(hostname 2>/dev/null || echo server)"
REASON=""

# ---------------------------------------------------------------------------------------------
# Logging, state, alerts
# ---------------------------------------------------------------------------------------------

rotate_log() {
  local size
  size="$(stat -c %s "$LOG_FILE" 2>/dev/null || echo 0)"
  if [[ "$size" -gt 1048576 ]]; then
    mv -f "$LOG_FILE" "$LOG_FILE.1" 2>/dev/null || true
  fi
}

log() {
  local line
  line="$(date '+%Y-%m-%d %H:%M:%S') $*"
  printf '%s\n' "$line"
  printf '%s\n' "$line" >>"$LOG_FILE" 2>/dev/null || true
}

sget() { # sget KEY [DEFAULT]
  local f="$STATE_DIR/$1"
  if [[ -r "$f" ]]; then cat "$f"; else printf '%s' "${2-}"; fi
}

sset() { printf '%s' "$2" >"$STATE_DIR/$1" 2>/dev/null || true; }

sdel() { rm -f "$STATE_DIR/$1" 2>/dev/null || true; }

alert() {
  local url
  url="$(env_file_get "$APP_DIR/.env" ALERT_WEBHOOK_URL 2>/dev/null || true)"
  [[ -n "$url" ]] || return 0
  send_webhook "$url" "[HA Gatekeeper @ ${HOSTNAME_LABEL}] $*" >/dev/null 2>&1 || log "alert delivery failed"
}

# ---------------------------------------------------------------------------------------------
# Action budget: never thrash. Every corrective action is recorded with a timestamp.
# ---------------------------------------------------------------------------------------------

record_action() { # record_action SERVICE ACTION
  printf '%s %s %s\n' "$NOW" "$1" "$2" >>"$STATE_DIR/actions.log" 2>/dev/null || true
  sset last_action "$NOW"
}

count_actions() { # count_actions SECONDS [SERVICE]
  local since=$((NOW - $1)) svc="${2:-}"
  [[ -r "$STATE_DIR/actions.log" ]] || { echo 0; return; }
  awk -v since="$since" -v svc="$svc" '$1 >= since && (svc == "" || $2 == svc) { n++ } END { print n + 0 }' \
    "$STATE_DIR/actions.log"
}

prune_actions() {
  [[ -r "$STATE_DIR/actions.log" ]] || return 0
  awk -v since="$((NOW - 86400))" '$1 >= since' "$STATE_DIR/actions.log" >"$STATE_DIR/actions.log.tmp" 2>/dev/null \
    && mv -f "$STATE_DIR/actions.log.tmp" "$STATE_DIR/actions.log" 2>/dev/null || true
}

in_grace() {
  local last
  last="$(sget last_action 0)"
  [[ "$last" =~ ^[0-9]+$ ]] || last=0
  (( NOW - last < GRACE_SECONDS ))
}

# ---------------------------------------------------------------------------------------------
# Environment
# ---------------------------------------------------------------------------------------------

dc() { ( cd "$APP_DIR" && timeout "$DC_TIMEOUT" docker compose "$@" ); }

proxy_enabled() {
  local profiles
  profiles="$(env_file_get "$APP_DIR/.env" COMPOSE_PROFILES 2>/dev/null || true)"
  [[ ",${profiles// /}," == *",proxy,"* ]]
}

gatekeeper_url() {
  local bind port
  bind="$(env_file_get "$APP_DIR/.env" GATEKEEPER_BIND 2>/dev/null || true)"
  port="$(env_file_get "$APP_DIR/.env" GATEKEEPER_PORT 2>/dev/null || true)"
  case "$bind" in ""|0.0.0.0|"::") bind="127.0.0.1" ;; esac
  printf 'http://%s:%s' "$bind" "${port:-8080}"
}

is_paused() {
  local f="$STATE_DIR/paused" v
  [[ -f "$f" ]] || return 1
  v="$(cat "$f" 2>/dev/null)"
  if [[ "$v" == "forever" ]]; then return 0; fi
  if [[ "$v" =~ ^[0-9]+$ ]] && (( v > NOW )); then return 0; fi
  # Expired or unreadable: a stale pause must never disable healing forever.
  sdel paused
  log "pause flag expired - resuming checks"
  return 1
}

# ---------------------------------------------------------------------------------------------
# Docker daemon
# ---------------------------------------------------------------------------------------------

start_docker_daemon() {
  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    timeout 120 systemctl "$1" docker >/dev/null 2>&1
  elif command -v service >/dev/null 2>&1; then
    timeout 120 service docker "$1" >/dev/null 2>&1
  else
    return 1
  fi
}

check_docker() {
  if timeout 20 docker info >/dev/null 2>&1; then
    if [[ "$(sget docker_fail 0)" != "0" ]]; then
      log "Docker daemon is responding again"
      alert "RECOVERED: the Docker daemon is responding again."
      sset docker_fail 0
    fi
    return 0
  fi

  local n
  n="$(sget docker_fail 0)"
  n=$((n + 1))
  sset docker_fail "$n"
  log "Docker daemon is not responding (check $n)"

  if (( n == 1 )); then
    # Most likely just stopped: starting it is cheap and safe.
    start_docker_daemon start && log "started docker.service"
  elif (( n >= 2 )); then
    # Running but wedged: restart it, at most once per 10 minutes.
    local last
    last="$(sget docker_restart 0)"
    if (( NOW - last > 600 )); then
      sset docker_restart "$NOW"
      log "restarting the Docker daemon"
      start_docker_daemon restart || log "could not restart Docker (no systemd/service?)"
      alert "Docker daemon was unresponsive for ${n} checks; restarted it."
    fi
  fi
  return 1
}

# ---------------------------------------------------------------------------------------------
# Component checks
#
# container_state NAME -> "status|health|restarting|restartcount|startedat"
# check_component NAME -> 0 healthy | 1 unhealthy | 2 still starting (leave alone) | 3 missing
# ---------------------------------------------------------------------------------------------

container_state() {
  timeout 20 docker inspect --type container --format \
    '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}|{{.State.Restarting}}|{{.RestartCount}}|{{.State.StartedAt}}' \
    "$1" 2>/dev/null
}

probe_gatekeeper() {
  local body
  body="$(curl -fsS --max-time "$PROBE_TIMEOUT" "$(gatekeeper_url)/healthz" 2>/dev/null)" || return 1
  [[ "$body" == *'"ok":true'* ]]
}

# Only checks that something is listening: certificate problems (DNS not ready yet, ACME
# retrying) must not make us restart Caddy, which would only reset its retry back-off.
probe_proxy() {
  timeout 5 bash -c 'exec 3<>/dev/tcp/127.0.0.1/443' 2>/dev/null
}

check_component() {
  local name="$1" st status health started uptime
  REASON=""

  st="$(container_state "$name")" || { REASON="container does not exist"; return 3; }
  IFS='|' read -r status health _ _ started <<<"$st"

  case "$status" in
    running) ;;
    restarting) REASON="crash loop (Docker keeps restarting it)"; return 1 ;;
    paused)     REASON="container is paused"; return 1 ;;
    *)          REASON="container is ${status}"; return 1 ;;
  esac

  if in_grace; then return 2; fi

  case "$health" in
    starting)
      uptime=$(( NOW - $(date -d "$started" +%s 2>/dev/null || echo "$NOW") ))
      if (( uptime > STARTING_MAX_SECONDS )); then
        REASON="health check never became healthy after ${uptime}s"
        return 1
      fi
      return 2
      ;;
    unhealthy) REASON="Docker health check reports unhealthy"; return 1 ;;
  esac

  if [[ "$name" == "$GK_CONTAINER" ]]; then
    probe_gatekeeper || { REASON="/healthz is not answering"; return 1; }
  else
    probe_proxy || { REASON="nothing is listening on port 443"; return 1; }
  fi
  return 0
}

# ---------------------------------------------------------------------------------------------
# Remediation ladder (bounded, never destructive)
#   1st/2nd action in 30 min   restart the container
#   3rd/4th                    recreate it from the image
#   5th and beyond             recreate everything, then restart Docker (once per hour)
# ---------------------------------------------------------------------------------------------

bring_stack_up() {
  # --no-build first: watchdog should not compile anything unless the image is really gone.
  if dc up -d --no-build --remove-orphans >/dev/null 2>&1; then
    return 0
  fi
  log "'up --no-build' failed (image missing?) - trying a full 'up' with build"
  dc up -d --remove-orphans >/dev/null 2>&1
}

remediate() { # remediate CONTAINER SERVICE REASON
  local container="$1" service="$2" reason="$3" hourly recent
  hourly="$(count_actions 3600)"
  if (( hourly >= MAX_ACTIONS_PER_HOUR )); then
    log "${service}: ${reason} - action budget (${MAX_ACTIONS_PER_HOUR}/hour) used up, waiting"
    return 1
  fi

  recent="$(count_actions 1800 "$service")"
  if (( recent < 2 )); then
    log "${service}: ${reason} - restarting container"
    record_action "$service" restart
    timeout 90 docker restart "$container" >/dev/null 2>&1 || {
      log "docker restart failed or timed out"
      timeout 30 docker start "$container" >/dev/null 2>&1 || true
    }
  elif (( recent < 4 )); then
    log "${service}: ${reason} - still failing, recreating container"
    record_action "$service" recreate
    dc up -d --no-build --force-recreate "$service" >/dev/null 2>&1 || bring_stack_up
  else
    log "${service}: ${reason} - recreating the whole stack"
    record_action "$service" recreate-all
    bring_stack_up
    dc up -d --no-build --force-recreate >/dev/null 2>&1 || true
    local last
    last="$(sget docker_restart 0)"
    if (( NOW - last > 3600 )); then
      sset docker_restart "$NOW"
      log "restarting the Docker daemon as a last resort"
      start_docker_daemon restart || true
    fi
  fi
  return 0
}

# handle_component CONTAINER SERVICE -> 0 healthy | 1 failing | 2 unknown (still starting or in
# its post-restart grace period: neither healthy nor failed, so outage state must not change)
handle_component() {
  local container="$1" service="$2" rc fails
  check_component "$container"
  rc=$?

  case "$rc" in
    0)
      if [[ "$(sget "fail.$service" 0)" != "0" ]]; then
        log "${service}: healthy again"
      fi
      sset "fail.$service" 0
      return 0
      ;;
    2) return 2 ;;
    3)
      # A missing container is not a flaky check: bring it back straight away.
      log "${service}: ${REASON} - bringing the stack up"
      record_action "$service" up
      bring_stack_up || log "${service}: could not bring the stack up"
      sset "fail.$service" 1
      return 1
      ;;
  esac

  fails="$(sget "fail.$service" 0)"
  fails=$((fails + 1))
  sset "fail.$service" "$fails"
  log "${service}: check failed (${fails}/${FAIL_THRESHOLD}): ${REASON}"

  if (( fails >= FAIL_THRESHOLD )); then
    remediate "$container" "$service" "$REASON" || true
  fi
  return 1
}

# ---------------------------------------------------------------------------------------------
# Disk guard: a full disk is the most common way a small VPS dies quietly.
# ---------------------------------------------------------------------------------------------

check_disk() {
  local avail_mb last
  avail_mb="$(df -Pm /var/lib/docker 2>/dev/null | awk 'NR==2 {print $4}')"
  [[ -n "$avail_mb" ]] || avail_mb="$(df -Pm "$APP_DIR" | awk 'NR==2 {print $4}')"
  [[ "$avail_mb" =~ ^[0-9]+$ ]] || return 0

  if (( avail_mb < MIN_FREE_MB )); then
    log "low disk space: ${avail_mb} MB free - pruning dangling images and build cache"
    timeout 300 docker image prune -f >/dev/null 2>&1 || true
    timeout 300 docker builder prune -f >/dev/null 2>&1 || true
    last="$(sget disk_alert 0)"
    if (( NOW - last > 86400 )); then
      sset disk_alert "$NOW"
      alert "WARNING: only ${avail_mb} MB of disk space left. Old images/build cache were pruned; free more space to keep the service safe."
    fi
  fi
}

# ---------------------------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------------------------

main() {
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
  rotate_log

  # One run at a time.
  exec 9>"$STATE_DIR/watchdog.lock" || exit 0
  flock -n 9 || exit 0

  sset heartbeat "$NOW"

  if ! command -v docker >/dev/null 2>&1; then
    log "docker is not installed - nothing to watch"
    exit 0
  fi

  if is_paused; then
    exit 0
  fi

  if [[ ! -f "$APP_DIR/.env" ]]; then
    log "no $APP_DIR/.env - Gatekeeper is not configured, run install.sh"
    exit 0
  fi

  prune_actions

  if ! check_docker; then
    exit 0
  fi

  local failing=0 unknown=0 rc
  handle_component "$GK_CONTAINER" gatekeeper
  rc=$?
  (( rc == 1 )) && failing=1
  (( rc == 2 )) && unknown=1
  if proxy_enabled; then
    handle_component "$CADDY_CONTAINER" caddy
    rc=$?
    (( rc == 1 )) && failing=1
    (( rc == 2 )) && unknown=1
  fi

  # Outage bookkeeping and alerts (de-duplicated; one DOWN, one RECOVERED, hourly STILL DOWN).
  # "Recovered" is only declared after a check has actually passed, never while a container is
  # merely starting or in its grace period after we restarted it.
  local since
  since="$(sget outage_since 0)"
  if (( failing )); then
    if [[ "$since" == "0" ]]; then
      sset outage_since "$NOW"
      since="$NOW"
    fi
    if [[ "$(sget alerted_down 0)" == "0" ]] && [[ "$(sget fail.gatekeeper 0)" -ge "$FAIL_THRESHOLD" || "$(sget fail.caddy 0)" -ge "$FAIL_THRESHOLD" ]]; then
      sset alerted_down 1
      alert "DOWN: health checks are failing (${REASON:-see log}). Automatic recovery is in progress."
    fi
    if (( NOW - since >= STUCK_ALERT_AFTER )) && (( NOW - $(sget stuck_alert 0) > 3600 )); then
      sset stuck_alert "$NOW"
      alert "STILL DOWN after $(( (NOW - since) / 60 )) minutes. Automatic recovery has not worked; please check the server (gatekeeper logs / gatekeeper verify)."
    fi
  elif (( unknown )); then
    : # waiting for a definitive answer; keep the current outage state
  elif [[ "$since" != "0" ]]; then
    local mins=$(( (NOW - since) / 60 ))
    log "recovered after ${mins} min"
    if [[ "$(sget alerted_down 0)" != "0" ]]; then
      alert "RECOVERED after ${mins} min. All checks pass again."
    fi
    sdel outage_since
    sdel alerted_down
    sdel stuck_alert
  fi

  # Cheap housekeeping every ten minutes.
  if (( (NOW / 60) % 10 == 0 )); then
    check_disk
  fi

  exit 0
}

# Allow tests to source the functions without running the watchdog.
if [[ -z "${GK_SOURCE_ONLY:-}" ]]; then
  main "$@"
fi
