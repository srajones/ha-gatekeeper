#!/usr/bin/env bash
# =================================================================================================
#  HA Gatekeeper - one-command VPS installer and manager
# =================================================================================================
#
#  Sets up HA Gatekeeper in Docker on a Linux server, walks you through every setting and
#  secret, keeps it alive, and checks that it all works when it is done.
#
#    sudo ./install.sh              guided install (safe to re-run: it repairs and re-applies)
#    sudo ./install.sh verify       health-check everything
#    sudo ./install.sh help         all commands and options
#
#  Or straight from GitHub, with no checkout:
#
#    curl -fsSL https://raw.githubusercontent.com/srajones/ha-gatekeeper/main/install.sh | sudo bash
#
#  What you get
#    - Docker + Docker Compose (installed for you if missing)
#    - the app in a container that restarts on crash and on reboot
#    - HTTPS through Caddy with an automatic Let's Encrypt certificate (optional)
#    - a watchdog that checks health every minute and heals the stack (deploy/watchdog.sh)
#    - daily backups, `gatekeeper` command, firewall rules, and a full post-install check
#
#  Docs: docs/DEPLOY_VPS.md
# =================================================================================================

# Started with `sh install.sh`? Hand over to bash before any bash-only syntax is parsed.
if [ -z "${BASH_VERSION:-}" ]; then
  if [ -f "$0" ] && command -v bash >/dev/null 2>&1; then
    exec bash "$0" "$@"
  fi
  echo "This installer needs bash. Run it as:  sudo bash install.sh" >&2
  exit 1
fi

if [[ -z "${GK_SOURCE_ONLY:-}" ]]; then
  set -Eeuo pipefail
fi

# -------------------------------------------------------------------------------------------------
# Constants and global state
# -------------------------------------------------------------------------------------------------

readonly GK_VERSION="1.0.0"
readonly GK_CONTAINER="ha-gatekeeper"
readonly CADDY_CONTAINER="ha-gatekeeper-caddy"
readonly SERVICE_UID=1001
readonly MIN_DISK_MB=3072
readonly BACKUP_KEEP="${GK_BACKUP_KEEP:-14}"

REPO_URL="${GK_REPO_URL:-https://github.com/srajones/ha-gatekeeper.git}"
REPO_BRANCH="${GK_BRANCH:-main}"
INSTALL_DIR="${GK_INSTALL_DIR:-/opt/ha-gatekeeper}"
STATE_DIR="${GK_STATE_DIR:-/var/lib/ha-gatekeeper}"
LOG_FILE="${GK_LOG_FILE:-/var/log/ha-gatekeeper-install.log}"
SYSTEMD_DIR="${GK_SYSTEMD_DIR:-/etc/systemd/system}"
CRON_FILE="${GK_CRON_FILE:-/etc/cron.d/ha-gatekeeper}"
BIN_LINK="${GK_BIN_LINK:-/usr/local/bin/gatekeeper}"
SWAP_FILE="${GK_SWAP_FILE:-/swapfile}"
FSTAB_FILE="${GK_FSTAB_FILE:-/etc/fstab}"
WATCHDOG_LOG="${GK_WATCHDOG_LOG:-/var/log/ha-gatekeeper-watchdog.log}"

SELF_PATH=""
SELF_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
  SELF_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
  SELF_DIR="$(dirname "$SELF_PATH")"
fi
APP_DIR=""

if [[ -n "$SELF_DIR" && -f "$SELF_DIR/deploy/lib.sh" ]]; then
  # shellcheck source=deploy/lib.sh
  source "$SELF_DIR/deploy/lib.sh"
fi

ORIG_ARGS=("$@")
COMMAND="install"
COMMAND_ARGS=()
NON_INTERACTIVE=false
RECONFIGURE=false
QUICK=false
DRILL="auto"
VERBOSE=false
QUIET=false
NO_COLOR_FLAG=false
CONFIG_FILE=""
WITH_ENV=false
ASSUME_YES=false
PURGE=false
DRY_RUN=false
KEEP_ON_FAILURE=false
[[ "${GATEKEEPER_KEEP_ON_FAILURE:-}" == 1 ]] && KEEP_ON_FAILURE=true

TMP_FILES=()
PENDING_LOG=""        # install runs log to a temp file until the plan is approved
REAL_LOG_FILE=""
DISCARD_LOG=false
WATCHDOG_PAUSED_BY_US=false
GENERATED_ADMIN_PASSWORD=""

OS_ID="unknown"
OS_LIKE=""
OS_PRETTY="unknown"
PKG=""
PKG_UPDATED=false
DOCKER_BIN=""

C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""

# -------------------------------------------------------------------------------------------------
# Output, logging and process helpers
#
# Convention: everything meant for people goes to stdout (or /dev/tty for prompts); helpers that
# *return data* print only that data on stdout and never call the UI functions.
# -------------------------------------------------------------------------------------------------

setup_colors() {
  if [[ -t 1 && -z "${NO_COLOR:-}" && "$NO_COLOR_FLAG" != true && "${TERM:-dumb}" != dumb ]]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
    C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'; C_CYAN=$'\033[36m'
  fi
}

log_file() {
  [[ -n "$LOG_FILE" ]] || return 0
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG_FILE" 2>/dev/null || true
}

say()   { $QUIET || printf '%s\n' "$*"; log_file "$*"; }
info()  { $QUIET || printf '%s[ .. ]%s %s\n' "$C_BLUE" "$C_RESET" "$*"; log_file "INFO  $*"; }
ok()    { $QUIET || printf '%s[ OK ]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; log_file "OK    $*"; }
warn()  { printf '%s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; log_file "WARN  $*"; }
err()   { printf '%s[FAIL]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; log_file "ERROR $*"; }
die()   { err "$*"; exit 1; }

hint() { # indented, dim follow-up line
  $QUIET || printf '       %s%s%s\n' "$C_DIM" "$*" "$C_RESET"
  log_file "      $*"
}

step() { # step N TOTAL "title"
  $QUIET && return 0
  printf '\n%s%s[%s/%s] %s%s\n' "$C_BOLD" "$C_CYAN" "$1" "$2" "$3" "$C_RESET"
  log_file "===== [$1/$2] $3"
}

banner() {
  $QUIET && return 0
  printf '\n%s%s' "$C_BOLD" "$C_CYAN"
  printf '=%.0s' {1..72}; printf '\n'
  printf '  %s\n' "$1"
  printf '=%.0s' {1..72}; printf '%s\n' "$C_RESET"
}

have() { command -v "$1" >/dev/null 2>&1; }

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

mktemp_tracked() { # mktemp_tracked [dir] -> path (removed on exit)
  local dir="${1:-${TMPDIR:-/tmp}}" f
  f="$(mktemp "$dir/gk.XXXXXX")"
  TMP_FILES+=("$f")
  printf '%s' "$f"
}

# EXIT trap. A failed install (error, Ctrl-C, failed final check) is rolled back here, before the
# temp files that the undo steps need are removed.
cleanup() {
  local rc=$? f
  trap - EXIT
  if $INSTALL_ACTIVE && ! $ROLLING_BACK && (( rc != 0 )); then
    if $KEEP_ON_FAILURE; then
      warn "Leaving the failed installation in place because --keep-on-failure is set."
    else
      journal_rollback || true
    fi
  fi
  for f in "${TMP_FILES[@]:-}"; do
    [[ -n "$f" ]] && rm -rf "$f" 2>/dev/null || true
  done
  if $WATCHDOG_PAUSED_BY_US; then
    resume_watchdog
  fi
  if [[ -n "$PENDING_LOG" ]]; then
    # An install that never reached the approval: keep its log only if it failed.
    if (( rc != 0 )) && ! $DISCARD_LOG; then adopt_real_log; else rm -f -- "$PENDING_LOG"; fi
  fi
  exit "$rc"
}

MAIN_PID=$$

on_error() {
  local rc=$1 line=$2
  # Command substitutions and pipelines inherit this trap; only the main shell reports.
  [[ "$BASHPID" == "$MAIN_PID" ]] || return 0
  trap - ERR
  err "Stopped unexpectedly (exit code $rc, line $line)."
  if $INSTALL_ACTIVE && ! $KEEP_ON_FAILURE; then
    hint "This run's changes are being undone now, so it is safe to run the installer again."
  else
    hint "It is safe to run this script again."
  fi
  hint "Details: ${REAL_LOG_FILE:-$LOG_FILE}"
  exit "$rc"
}

# retry TRIES DELAY cmd...   (exponential back-off)
retry() {
  local tries="$1" delay="$2" n=1
  shift 2
  until "$@"; do
    if (( n >= tries )); then
      return 1
    fi
    log_file "retry $n/$tries failed: $*"
    sleep "$delay"
    delay=$((delay * 2))
    n=$((n + 1))
  done
}

# run_logged "what we are doing" cmd args...
# Output goes to the log; on failure the tail is shown. Prints a heartbeat for slow commands.
run_logged() {
  local msg="$1" out rc=0 ticker="" start=$SECONDS
  shift
  out="$(mktemp_tracked)"
  info "$msg"
  if ! $QUIET; then
    ( exec 200>&-; while sleep 25; do printf '       ... still working (%ss)\n' "$((SECONDS - start))"; done ) &
    ticker=$!
  fi
  if $VERBOSE; then
    "$@" </dev/null 2>&1 | tee "$out" || rc=${PIPESTATUS[0]}
  else
    "$@" </dev/null >"$out" 2>&1 || rc=$?
  fi
  if [[ -n "$ticker" ]]; then
    kill "$ticker" 2>/dev/null || true
    wait "$ticker" 2>/dev/null || true
  fi
  log_file "--- output of: $*"
  cat "$out" >>"$LOG_FILE" 2>/dev/null || true
  if (( rc != 0 )); then
    err "Failed (exit $rc): $msg"
    tail -n 25 "$out" | sed 's/^/       | /'
  fi
  return "$rc"
}

# -------------------------------------------------------------------------------------------------
# Change journal and automatic rollback
#
# Every change this installer makes outside its own checkout is recorded here *before* it is made,
# together with the function that undoes it. If the install fails (an error, Ctrl-C, or the final
# health check), the entries are undone in reverse order and each undo is printed. Anything that
# was already on the server (Docker, packages, firewall rules, web servers, other containers) is
# never recorded and therefore never touched.
# -------------------------------------------------------------------------------------------------

readonly JSEP=$'\x1f'
J_DESC=(); J_FN=(); J_ARGS=(); J_KEEP=()
J_KEEP_NEXT=0          # set to 1 (as a prefix of jpush) for changes that `uninstall` does not undo
J_LAST=-1
JOURNAL_LOG=""         # append-only text copy, written once the plan is approved
JOURNAL_TMP=""         # scratch folder for the files we back up before replacing them
INSTALL_ACTIVE=false   # true from the start of an install until it is committed
ROLLING_BACK=false
RV_NOTE=""

journal_tmp() {
  if [[ -z "$JOURNAL_TMP" ]]; then
    JOURNAL_TMP="$(mktemp -d "${TMPDIR:-/tmp}/gk-journal.XXXXXX")"
    chmod 700 "$JOURNAL_TMP"
    TMP_FILES+=("$JOURNAL_TMP")
  fi
  printf '%s' "$JOURNAL_TMP"
}

# jpush "what was done (shown to the user)" undo_function [args...]
jpush() {
  $ROLLING_BACK && return 0
  local desc="$1" fn="$2" args="" a
  shift 2
  for a in "$@"; do
    [[ "$a" != *"$JSEP"* && "$a" != *$'\n'* ]] || die "internal error: a journal argument contains a separator"
    args+="$a$JSEP"
  done
  J_DESC+=("$desc"); J_FN+=("$fn"); J_ARGS+=("$args"); J_KEEP+=("$J_KEEP_NEXT")
  J_LAST=$(( ${#J_DESC[@]} - 1 ))
  if [[ -n "$JOURNAL_LOG" ]]; then
    printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$fn" "$desc" >>"$JOURNAL_LOG" 2>/dev/null || true
  fi
  log_file "JOURNAL $desc  [undo: $fn $*]"
}

# jdrop INDEX: forget an entry whose change has already been undone on the normal path.
jdrop() { J_DESC[$1]=""; J_FN[$1]=rv_noop; J_ARGS[$1]=""; J_KEEP[$1]=0; }

# Private copy of a file we are about to replace (restored if the install is rolled back).
jbackup() {
  local src="$1" dst
  dst="$(journal_tmp)/bak.${#J_DESC[@]}.$(basename "$src")"
  cp -a -- "$src" "$dst"
  printf '%s' "$dst"
}

# Paths the rollback may delete recursively: never a system directory, never anything short.
safe_rm_target() {
  local p="$1"
  [[ "$p" == /* && "$p" != *..* ]] || return 1
  case "$p" in
    /|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/media|/mnt|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/usr/local|/var|/var/lib|/var/log) return 1 ;;
  esac
  (( $(awk -F/ '{print NF - 1}' <<<"$p") >= 2 ))
}

# --- undo functions. Return 0 = undone, 1 = failed, 2 = deliberately left (RV_NOTE says why).

rv_noop() { return 0; }
rv_note() { RV_NOTE="$1"; return 2; }

rv_rm() {
  local p="$1"
  [[ "$p" == /* ]] || return 1
  if [[ -d "$p" && ! -L "$p" ]]; then RV_NOTE="$p is a folder, left alone"; return 2; fi
  rm -f -- "$p"
}

rv_restore() { # rv_restore PATH BACKUP
  local p="$1" bak="$2"
  [[ -e "$bak" || -L "$bak" ]] || { RV_NOTE="the saved copy of $p is missing"; return 1; }
  rm -f -- "$p"
  cp -a -- "$bak" "$p"
}

rv_rmdir() {
  local p="$1"
  [[ -d "$p" ]] || return 0
  if rmdir -- "$p" 2>/dev/null; then return 0; fi
  RV_NOTE="$p is not empty, left in place"
  return 2
}

rv_rmtree() {
  local p="$1"
  [[ -e "$p" || -L "$p" ]] || return 0
  safe_rm_target "$p" || { RV_NOTE="refusing to delete $p"; return 1; }
  rm -rf -- "$p"
}

rv_daemon_reload() { have_systemd && systemctl daemon-reload; return 0; }

rv_unit_disable() {
  have_systemd || return 0
  systemctl disable --now "$@" || true
}

rv_docker_boot_disable() {
  have_systemd || return 0
  systemctl disable docker.service docker.socket 2>/dev/null || true
}

rv_ufw_delete() { have ufw || return 0; ufw --force delete "$@"; }
rv_ufw_disable() { have ufw || return 0; ufw --force disable; }

rv_firewalld() { # rv_firewalld service|port|rich VALUE
  have firewall-cmd || return 0
  case "$1" in
    service) firewall-cmd --permanent --remove-service="$2" ;;
    port) firewall-cmd --permanent --remove-port="$2" ;;
    rich) firewall-cmd --permanent --remove-rich-rule="$2" ;;
  esac
  firewall-cmd --reload
}

rv_swap() { # rv_swap FILE
  swapoff "$1" 2>/dev/null || true
  rm -f -- "$1"
}

rv_fstab_line() { # rv_fstab_line FSTAB LINE
  local fstab="$1" line="$2" tmp
  [[ -f "$fstab" ]] || return 0
  tmp="$(mktemp)"
  grep -vxF -- "$line" "$fstab" >"$tmp" || true
  cat "$tmp" >"$fstab"
  rm -f "$tmp"
}

# Names of installed packages (apt only; other package managers are not rolled back).
pkg_snapshot() { # pkg_snapshot FILE
  [[ "$PKG" == apt ]] || return 1
  dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 2>/dev/null | awk '$1 ~ /^ii/ {print $2}' | LC_ALL=C sort -u >"$1"
}

# Remove exactly the packages that appeared since SNAPSHOT, but only if apt agrees that nothing
# else would go with them. Otherwise leave them and say so.
rv_pkgs_since() {
  local snap="$1" now cand sim extra
  if [[ "$PKG" != apt ]]; then RV_NOTE="installed packages were left in place (automatic removal is only done with apt)"; return 2; fi
  [[ -s "$snap" ]] || { RV_NOTE="no package snapshot to compare with"; return 2; }
  now="$(mktemp)"
  pkg_snapshot "$now"
  cand="$(LC_ALL=C comm -13 "$snap" "$now" | tr '\n' ' ')"
  rm -f "$now"
  cand="${cand% }"
  [[ -n "$cand" ]] || return 0
  # shellcheck disable=SC2086
  sim="$(apt-get -s remove --purge $cand 2>/dev/null | awk '$1 == "Remv" || $1 == "Purg" {print $2}' | LC_ALL=C sort -u)"
  extra="$(LC_ALL=C comm -13 <(tr ' ' '\n' <<<"$cand" | LC_ALL=C sort -u) <(printf '%s\n' "$sim") | tr '\n' ' ')"
  if [[ -n "${extra// /}" ]]; then
    RV_NOTE="removing $cand would also remove $extra; left installed (remove by hand if you want)"
    return 2
  fi
  wait_for_apt_lock
  # shellcheck disable=SC2086
  DEBIAN_FRONTEND=noninteractive apt-get remove --purge -y -qq -o DPkg::Lock::Timeout=120 $cand
}

# Docker Engine installed by this run: its packages, the repository definition the Docker
# installer added, and (only if they did not exist before) its data folders.
rv_docker_engine() { # rv_docker_engine PKG_SNAPSHOT FILES_BEFORE HAD_DOCKER_DIR HAD_CONTAINERD_DIR
  local snap="$1" before="$2" had_d="$3" had_c="$4" f rc=0
  rv_pkgs_since "$snap" || rc=$?
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    grep -qxF -- "$f" "$before" 2>/dev/null && continue
    case "$(basename "$f")" in *docker*|*Docker*) rm -f -- "$f" ;; esac
  done < <(find /etc/apt/sources.list.d /etc/apt/keyrings /usr/share/keyrings /etc/yum.repos.d -maxdepth 1 -type f 2>/dev/null | LC_ALL=C sort)
  if (( rc == 0 )); then
    [[ "$had_d" == 0 ]] && rm -rf /var/lib/docker
    [[ "$had_c" == 0 ]] && rm -rf /var/lib/containerd
  fi
  return "$rc"
}

rv_docker_logout() { have docker && docker logout >/dev/null 2>&1; return 0; }

# The database file(s) the app created inside a data folder that already existed.
rv_rm_db() { # rv_rm_db DATA_DIR
  local d="$1" f
  for f in ha-gatekeeper.db ha-gatekeeper.db-journal ha-gatekeeper.db-wal ha-gatekeeper.db-shm .backup-snapshot.db; do
    rm -f -- "$d/$f"
  done
}

rv_image_rm() {
  have docker && docker_ready || return 0
  local img rc=0
  for img in "$@"; do
    docker image inspect "$img" >/dev/null 2>&1 || continue
    docker rmi "$img" >/dev/null 2>&1 || rc=1
  done
  (( rc == 0 )) || RV_NOTE="some images are still in use"
  return "$rc"
}

rv_volume_rm() {
  have docker && docker_ready || return 0
  local v
  for v in "$@"; do docker volume rm "$v" >/dev/null 2>&1 || true; done
}

# Containers started by this run. When a stack was already installed, the old settings are put
# back by rv_restore_env instead, so the old containers are not removed here.
rv_stack_down() { # rv_stack_down PREEXISTING(0|1)
  [[ "$1" == 1 ]] && return 0
  have docker && docker_ready || return 0
  if [[ -f "$APP_DIR/.env" ]]; then
    ( cd "$APP_DIR" && docker compose --profile proxy down --remove-orphans ) || return 1
  else
    docker rm -f "$GK_CONTAINER" "$CADDY_CONTAINER" 2>/dev/null || true
  fi
}

# .env replaced by this run: put the previous one back, rewrite the secret files from it and, if
# the stack was already installed, start it again with the old settings.
rv_restore_env() { # rv_restore_env BACKUP STACK_PREEXISTING(0|1)
  local bak="$1" pre="$2"
  [[ -f "$bak" ]] || { RV_NOTE="the saved copy of .env is missing"; return 1; }
  cp -p -- "$bak" "$APP_DIR/.env"
  chmod 600 "$APP_DIR/.env"
  if [[ "$pre" == 1 ]] && have docker && docker_ready; then
    cfg_defaults
    cfg_load_file "$APP_DIR/.env"
    derive_config
    sync_secret_files
    dc up -d --no-build --remove-orphans --force-recreate || { RV_NOTE="the old settings are back but the stack did not start"; return 1; }
    wait_for_container "$GK_CONTAINER" 90 || { RV_NOTE="the old settings are back but the container is not healthy yet"; return 1; }
  fi
}

# Undo everything recorded so far, newest first. Never aborts half-way.
journal_rollback() { # journal_rollback [quiet]
  $ROLLING_BACK && return 0
  (( ${#J_DESC[@]} > 0 )) || return 0
  ROLLING_BACK=true
  trap - ERR
  # A dropped SSH session must not interrupt the undo: ignore the hang-up, and a closed terminal
  # (broken pipe on output) must not kill it either; everything is also written to the log.
  trap '' INT TERM HUP PIPE
  set +e
  local quiet="${1:-}" i rc fn desc parts=() failed=0 kept=0 done_n=0 sink paused=false
  sink="${LOG_FILE:-/dev/null}"
  if [[ "$quiet" != quiet ]]; then
    printf '\n%s%sUndoing what this installation changed (newest first)%s\n' "$C_BOLD" "$C_YELLOW" "$C_RESET"
    printf '%sAnything that was already on this server is left alone.%s\n' "$C_DIM" "$C_RESET"
  fi
  log_file "ROLLBACK started with ${#J_DESC[@]} entries"
  if [[ "$quiet" != quiet && -d "$STATE_DIR" && ! -e "$STATE_DIR/paused" ]]; then
    pause_watchdog 900 >/dev/null 2>&1 && paused=true
  fi

  for (( i = ${#J_DESC[@]} - 1; i >= 0; i-- )); do
    desc="${J_DESC[i]}"
    [[ -n "$desc" ]] || continue
    fn="${J_FN[i]}"
    RV_NOTE=""
    parts=()
    IFS="$JSEP" read -r -a parts <<<"${J_ARGS[i]}"
    "$fn" "${parts[@]+"${parts[@]}"}" >>"$sink" 2>&1
    rc=$?
    case "$rc" in
      0) done_n=$((done_n + 1)); [[ "$quiet" == quiet ]] || printf '  %s[undone]%s %s\n' "$C_GREEN" "$C_RESET" "$desc"; log_file "ROLLBACK undone: $desc" ;;
      2) kept=$((kept + 1)); [[ "$quiet" == quiet ]] || printf '  %s[kept]%s   %s\n           %s%s%s\n' "$C_YELLOW" "$C_RESET" "$desc" "$C_DIM" "$RV_NOTE" "$C_RESET"; log_file "ROLLBACK kept: $desc ($RV_NOTE)" ;;
      *) failed=$((failed + 1)); printf '  %s[FAILED]%s %s\n           %s%s%s\n' "$C_RED" "$C_RESET" "$desc" "$C_DIM" "${RV_NOTE:-see $sink}" "$C_RESET"; log_file "ROLLBACK FAILED: $desc ($RV_NOTE)" ;;
    esac
  done

  J_DESC=(); J_FN=(); J_ARGS=(); J_KEEP=()
  $paused && resume_watchdog
  if [[ "$quiet" != quiet ]]; then
    if (( failed == 0 && kept == 0 )); then
      printf '\n%s%sEverything this run changed has been undone.%s\n' "$C_BOLD" "$C_GREEN" "$C_RESET"
    elif (( failed == 0 )); then
      printf '\n%sUndone: %s. Left in place on purpose: %s (see above).%s\n' "$C_BOLD" "$done_n" "$kept" "$C_RESET"
    else
      printf '\n%s%s%s step(s) could not be undone automatically (listed above). Install log: %s%s\n' "$C_BOLD" "$C_RED" "$failed" "${REAL_LOG_FILE:-$LOG_FILE}" "$C_RESET"
    fi
  fi
  return "$failed"
}

# Print the journal as a list of what changed (used for the end-of-run summary).
journal_list() { # journal_list [keep-only]
  local i
  for i in "${!J_DESC[@]}"; do
    [[ -n "${J_DESC[i]}" ]] || continue
    [[ "${J_FN[i]}" == rv_noop ]] && continue
    if [[ "${1:-}" == keep-only ]]; then [[ "${J_KEEP[i]}" == 1 ]] || continue; fi
    printf '%s\n' "${J_DESC[i]}"
  done
}

# --- journaled primitives used by the install steps

# jx_mkdir DIR [tree]: create DIR (and missing parents); undo removes only what was created.
# With "tree" the undo deletes DIR with everything in it (for folders only this installer fills).
jx_mkdir() {
  local dir="$1" mode="${2:-}" p="$1" new=() n
  while [[ -n "$p" && "$p" != / && ! -e "$p" ]]; do
    new=("$p" ${new[@]+"${new[@]}"})
    p="$(dirname "$p")"
  done
  (( ${#new[@]} > 0 )) || return 0
  for n in "${new[@]}"; do
    if [[ "$n" == "$dir" && "$mode" == tree ]]; then
      jpush "Created folder $n" rv_rmtree "$n"
    else
      jpush "Created folder $n" rv_rmdir "$n"
    fi
  done
  mkdir -p "$dir"
}

# jx_install_file SRC DEST MODE: put SRC at DEST. A new file is removed on rollback, a replaced
# one is restored; an identical file is left alone and not recorded.
jx_install_file() {
  local src="$1" dest="$2" mode="$3" bak
  if [[ -e "$dest" || -L "$dest" ]]; then
    if [[ ! -L "$dest" ]] && cmp -s "$src" "$dest"; then
      chmod "$mode" "$dest"
      return 0
    fi
    bak="$(jbackup "$dest")"
    jpush "Replaced $dest (the previous version is put back on rollback)" rv_restore "$dest" "$bak"
  else
    jpush "Created $dest" rv_rm "$dest"
  fi
  rm -f -- "$dest"
  install -m "$mode" "$src" "$dest"
}

# jx_pkg_install NAME...: install packages; undo removes exactly the ones that were not there.
jx_pkg_install() {
  local snap now new idx rc=0
  snap="$(journal_tmp)/pkgs.${#J_DESC[@]}"
  if pkg_snapshot "$snap"; then
    jpush "Installed packages: $*" rv_pkgs_since "$snap"
    idx=$J_LAST
    pkg_install "$@" || rc=$?
    now="$(mktemp)"
    pkg_snapshot "$now"
    new="$(LC_ALL=C comm -13 "$snap" "$now" | tr '\n' ' ')"
    rm -f "$now"
    if [[ -z "${new// /}" ]]; then
      jdrop "$idx"               # nothing new arrived (already installed, or the install failed cleanly)
    else
      J_DESC[idx]="Installed packages: ${new% }"
      J_KEEP[idx]=1              # uninstall does not remove packages
    fi
    return "$rc"
  fi
  J_KEEP_NEXT=1 jpush "Installed packages: $*" rv_note "packages were left installed (automatic removal is only done with apt)"
  pkg_install "$@"
}

# -------------------------------------------------------------------------------------------------
# Prompts. Questions go to the terminal (/dev/tty, so they work under `curl | bash` too) and only
# the answer is printed on stdout, so callers can use   value="$(ask "Question" "default")".
# -------------------------------------------------------------------------------------------------

TTY_STATE=""

have_tty() {
  if [[ -z "$TTY_STATE" ]]; then
    if ( : </dev/tty ) 2>/dev/null; then TTY_STATE=yes; else TTY_STATE=no; fi
  fi
  [[ "$TTY_STATE" == yes ]]
}

interactive() { ! $NON_INTERACTIVE && have_tty; }

# confirm_cmd: the one confirmation for a command the user typed on purpose (restore, uninstall).
# --yes answers it; it never answers the optional destructive extras (see confirm_purge).
confirm_cmd() {
  $ASSUME_YES && return 0
  confirm "$@"
}

# confirm_purge: destructive extras (delete data, .env, images, certificates) need --purge when
# running unattended; interactively the user is asked, default no.
confirm_purge() {
  $PURGE && return 0
  interactive || return 1
  confirm "$@"
}

tty_print() { printf '%s' "$*" >/dev/tty; }

ask() { # ask "Prompt" [default]
  local prompt="$1" default="${2-}" reply=""
  if ! interactive; then
    printf '%s' "$default"
    return 0
  fi
  tty_print "$C_BOLD$prompt${default:+ [$default]}:$C_RESET "
  IFS= read -r reply </dev/tty || reply=""
  reply="$(trim "$reply")"
  printf '%s' "${reply:-$default}"
}

ask_secret() { # ask_secret "Prompt" -> hidden input
  local prompt="$1" reply=""
  if ! interactive; then
    return 0
  fi
  tty_print "$C_BOLD$prompt (input hidden):$C_RESET "
  IFS= read -rs reply </dev/tty || reply=""
  tty_print $'\n'
  printf '%s' "$reply"
}

confirm() { # confirm "Question?" [y|n default]   -> exit status 0 = yes
  local prompt="$1" default="${2:-y}" reply hintstr
  if ! interactive; then
    [[ "$default" == y ]]
    return
  fi
  if [[ "$default" == y ]]; then hintstr="Y/n"; else hintstr="y/N"; fi
  while true; do
    tty_print "$C_BOLD$prompt [$hintstr]$C_RESET "
    IFS= read -r reply </dev/tty || reply=""
    reply="$(trim "${reply:-$default}")"
    case "${reply,,}" in
      y|yes) return 0 ;;
      n|no) return 1 ;;
    esac
    tty_print $'Please answer y or n.\n'
  done
}

# -------------------------------------------------------------------------------------------------
# System detection, packages and resources
# -------------------------------------------------------------------------------------------------

detect_os() {
  local line
  if [[ -r /etc/os-release ]]; then
    line="$( . /etc/os-release; printf '%s|%s|%s|%s' "${ID:-unknown}" "${ID_LIKE:-}" "${VERSION_ID:-}" "${PRETTY_NAME:-unknown}" )"
    IFS='|' read -r OS_ID OS_LIKE _ OS_PRETTY <<<"$line"
  fi

  if have apt-get; then PKG=apt
  elif have dnf; then PKG=dnf
  elif have yum; then PKG=yum
  elif have zypper; then PKG=zypper
  elif have apk; then PKG=apk
  elif have pacman; then PKG=pacman
  else PKG=""
  fi
}

os_supported_for_docker_script() {
  case "$OS_ID $OS_LIKE" in
    *ubuntu*|*debian*|*rhel*|*centos*|*fedora*|*rocky*|*almalinux*|*sles*|*suse*|*raspbian*|*amzn*) return 0 ;;
  esac
  return 1
}

APT_LOCK_WAITED=false

# True while apt/dpkg really holds one of its locks. Never match on process names: the idle
# unattended-upgrades daemon runs permanently on stock Ubuntu and is not a lock holder.
APT_LOCK_PATHS=(/var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock)
apt_lock_held() {
  local f ino dev maj min
  if have fuser; then
    fuser "${APT_LOCK_PATHS[@]}" >/dev/null 2>&1
    return
  fi
  # Fresh Debian images ship without fuser (psmisc): ask the kernel which files are locked,
  # which is the same information fuser reads.
  [[ -r /proc/locks ]] || return 1
  for f in "${APT_LOCK_PATHS[@]}"; do
    [[ -e "$f" ]] || continue
    ino="$(stat -c %i "$f" 2>/dev/null)" || continue
    dev="$(stat -c %d "$f" 2>/dev/null)" || continue
    maj=$(( (dev >> 8) & 0xfff ))
    min=$(( (dev & 0xff) | ((dev >> 12) & 0xfff00) ))
    if grep -qF -- " $(printf '%02x:%02x:%s' "$maj" "$min" "$ino") " /proc/locks 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

wait_for_apt_lock() {
  [[ "$PKG" == apt ]] || return 0
  $APT_LOCK_WAITED && return 0
  local waited=0
  while apt_lock_held; do
    if (( waited == 0 )); then
      info "Another package operation holds the apt lock (common right after a server is created). Waiting for it..."
    fi
    if (( waited >= 300 )); then
      warn "Still locked after 5 minutes; trying anyway."
      APT_LOCK_WAITED=true
      return 0
    fi
    sleep 5
    waited=$((waited + 5))
  done
}

# Let every apt/dpkg run started by the Docker installer wait for the lock instead of failing.
APT_LOCK_CONF="${GK_APT_CONF:-/etc/apt/apt.conf.d/99gatekeeper-lock}"
APT_CONF_IDX=-1
apt_lock_conf_on() {
  [[ "$PKG" == apt && -d "$(dirname "$APT_LOCK_CONF")" ]] || return 0
  jpush "Temporarily created $APT_LOCK_CONF while Docker installs" rv_rm "$APT_LOCK_CONF"
  APT_CONF_IDX=$J_LAST
  printf 'DPkg::Lock::Timeout "300";\nAPT::Get::Assume-Yes "true";\n' >"$APT_LOCK_CONF" 2>/dev/null || true
}
apt_lock_conf_off() {
  rm -f "$APT_LOCK_CONF" 2>/dev/null || true
  if (( APT_CONF_IDX >= 0 )); then jdrop "$APT_CONF_IDX"; APT_CONF_IDX=-1; fi
  return 0
}

pkg_refresh() {
  $PKG_UPDATED && return 0
  case "$PKG" in
    apt) wait_for_apt_lock; retry 4 10 apt-get update -qq -o DPkg::Lock::Timeout=300 </dev/null >>"$LOG_FILE" 2>&1 || true ;;
    dnf|yum) : ;;
    zypper) retry 3 5 zypper --non-interactive refresh >>"$LOG_FILE" 2>&1 || true ;;
    apk) retry 3 5 apk update >>"$LOG_FILE" 2>&1 || true ;;
    pacman) : ;;
  esac
  PKG_UPDATED=true
}

pkg_install() { # pkg_install name...   (names are identical across the supported families)
  [[ -n "$PKG" ]] || return 1
  pkg_refresh
  case "$PKG" in
    apt)
      wait_for_apt_lock
      DEBIAN_FRONTEND=noninteractive retry 3 10 apt-get install -y -qq --no-install-recommends \
        -o DPkg::Lock::Timeout=300 "$@" </dev/null >>"$LOG_FILE" 2>&1
      ;;
    dnf|yum) retry 3 10 "$PKG" install -y -q "$@" </dev/null >>"$LOG_FILE" 2>&1 ;;
    zypper) retry 3 10 zypper --non-interactive install "$@" </dev/null >>"$LOG_FILE" 2>&1 ;;
    apk) retry 3 10 apk add --no-cache "$@" </dev/null >>"$LOG_FILE" 2>&1 ;;
    pacman) retry 3 10 pacman -S --noconfirm --needed "$@" </dev/null >>"$LOG_FILE" 2>&1 ;;
  esac
}

# Packages the installer still needs on this server (read-only: installs nothing).
P_PKGS=()
compute_missing_prereqs() {
  P_PKGS=()
  have curl    || P_PKGS+=(curl)
  have openssl || P_PKGS+=(openssl)
  have git     || P_PKGS+=(git)
  have jq      || P_PKGS+=(jq)
  have flock   || P_PKGS+=(util-linux)
  have tar     || P_PKGS+=(tar)
  have gzip    || P_PKGS+=(gzip)
  # fuser (psmisc) lets the installer tell a busy apt lock from a stale one; minimal images lack it.
  if [[ "$PKG" == apt ]]; then have fuser || P_PKGS+=(psmisc); fi
  [[ -e /etc/ssl/certs/ca-certificates.crt || -d /etc/pki/tls/certs || -e /etc/ssl/cert.pem ]] || P_PKGS+=(ca-certificates)
  return 0
}

# A package install that has to happen before the full plan can be shown (for example curl, to test
# Home Assistant while asking the questions). Asks first; --yes answers it.
consent_install_tools() { # consent_install_tools "why" PKG...
  local why="$1"
  shift
  say ""
  say "${C_BOLD}$why${C_RESET}"
  say "  This needs the package(s): $*   (installed with ${PKG:-the package manager}; it is the only change made before you see the full plan)"
  if $DRY_RUN; then
    warn "Dry run: not installing $*; some checks are skipped."
    return 1
  fi
  if ! $ASSUME_YES; then
    interactive || die "Cannot ask for permission without a terminal. Install $* yourself, or re-run with --yes."
    confirm "Install $* now?" n || die "Cancelled. Nothing was changed."
  fi
  jx_pkg_install "$@" || die "Could not install: $*. Install them manually and re-run."
}

ensure_prereqs() {
  compute_missing_prereqs
  local need=("${P_PKGS[@]+"${P_PKGS[@]}"}")

  if (( ${#need[@]} == 0 )); then
    ok "Required tools present (curl, openssl, git, jq, flock, tar)"
    return 0
  fi

  info "Installing required tools: ${need[*]}"
  if ! jx_pkg_install "${need[@]}"; then
    die "Could not install: ${need[*]}. Install them manually (for example: apt-get install ${need[*]}) and re-run."
  fi

  local missing=() t
  for t in curl openssl git jq flock tar gzip; do have "$t" || missing+=("$t"); done
  (( ${#missing[@]} == 0 )) || die "Still missing after install: ${missing[*]}"
  ok "Installed required tools"
}

mem_mb()  { awk '/^MemTotal:/ {printf "%d", $2/1024}' /proc/meminfo; }
swap_mb() { awk '/^SwapTotal:/ {printf "%d", $2/1024}' /proc/meminfo; }
disk_free_mb() { df -Pm "$1" 2>/dev/null | awk 'NR==2 {print $4}'; }

# Decides (without changing anything) whether a swap file is needed and wanted; sets P_SWAP_MB.
P_SWAP_MB=0
swap_plan() {
  P_SWAP_MB=0
  local mem swap total size free path="$SWAP_FILE"
  mem="$(mem_mb)"; swap="$(swap_mb)"; total=$((mem + swap))
  (( total >= 1800 )) && return 0

  if [[ -e "$path" ]]; then
    warn "Only ${mem} MB RAM and ${swap} MB swap, and $path already exists but is not active; leaving it alone."
    return 0
  fi
  size=$((2048 - total))
  (( size < 1024 )) && size=1024
  (( size > 2048 )) && size=2048
  free="$(disk_free_mb /)"
  if (( free < size + 2048 )); then
    warn "Only ${mem} MB RAM, and not enough free disk (${free} MB) to add a ${size} MB swap file safely; skipping."
    return 0
  fi
  if [[ "${GATEKEEPER_SWAP:-}" == 0 ]]; then
    warn "Only ${mem} MB RAM and ${swap} MB swap (GATEKEEPER_SWAP=0: no swap file will be added). The image build can run out of memory."
    return 0
  fi

  warn "Only ${mem} MB RAM and ${swap} MB swap. Building the image can run out of memory on a server this small."
  if [[ "${GATEKEEPER_SWAP:-}" != 1 ]] && interactive && ! $DRY_RUN; then
    if ! confirm "Add a ${size} MB swap file so the build cannot run out of memory?" y; then
      warn "Skipping swap. If the build gets 'Killed', re-run and accept the swap file."
      return 0
    fi
  fi
  P_SWAP_MB=$size
}

create_swap() {
  (( P_SWAP_MB > 0 )) || return 0
  local path="$SWAP_FILE" size="$P_SWAP_MB" line idx
  info "Creating a ${size} MB swap file at $path"
  jpush "Created a ${size} MB swap file at $path" rv_swap "$path"
  idx=$J_LAST
  J_KEEP[idx]=1
  if ! { fallocate -l "${size}M" "$path" 2>/dev/null || dd if=/dev/zero of="$path" bs=1M count="$size" status=none; }; then
    rm -f "$path"; jdrop "$idx"; warn "Could not create the swap file; continuing without it."; return 0
  fi
  chmod 600 "$path"
  if mkswap "$path" >>"$LOG_FILE" 2>&1 && swapon "$path" >>"$LOG_FILE" 2>&1; then
    line="$path none swap sw 0 0"
    if ! grep -qs "^$path " "$FSTAB_FILE"; then
      jpush "Added the line '$line' to $FSTAB_FILE" rv_fstab_line "$FSTAB_FILE" "$line"
      J_KEEP[J_LAST]=1
      printf '%s\n' "$line" >>"$FSTAB_FILE"
    fi
    ok "Swap enabled (${size} MB) and set to persist across reboots"
  else
    swapoff "$path" 2>/dev/null || true
    rm -f "$path"
    jdrop "$idx"
    warn "This server does not allow swap (common on some virtualization types); continuing without it."
  fi
}

check_resources() {
  local mem free arch
  mem="$(mem_mb)"
  free="$(disk_free_mb /)"
  arch="$(uname -m)"

  ok "$OS_PRETTY, $arch, $(nproc 2>/dev/null || echo '?') CPU, ${mem} MB RAM, ${free} MB free disk"

  case "$arch" in
    x86_64|amd64|aarch64|arm64) ;;
    *) warn "Unusual CPU architecture ($arch). The Docker images used here are built for amd64 and arm64." ;;
  esac

  if (( free < MIN_DISK_MB )); then
    die "Only ${free} MB of free disk space. At least ${MIN_DISK_MB} MB is needed for the image build. Free some space and re-run."
  fi
  (( free < 5120 )) && warn "Free disk is getting low (${free} MB). Consider a bigger disk."
  (( mem < 900 )) && warn "Under 1 GB of RAM: it will work, but a swap file is important (offered below)."
  return 0
}

check_internet() {
  local url code reachable=0 failed=()
  for url in https://github.com https://registry-1.docker.io/v2/ https://registry.npmjs.org/; do
    code="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 8 --max-time 15 "$url" 2>/dev/null || true)"
    if [[ -n "$code" && "$code" != 000 ]]; then
      reachable=$((reachable + 1))
    else
      failed+=("$url")
    fi
  done

  if (( reachable == 0 )); then
    err "This server cannot reach the internet (tried GitHub, Docker Hub and npm)."
    hint "Check DNS (cat /etc/resolv.conf), the provider's firewall/network settings, and that the server has a public IP."
    exit 1
  fi
  if (( ${#failed[@]} > 0 )); then
    warn "Could not reach: ${failed[*]}"
    hint "The install may still work (mirrors are used for Docker images), but the build downloads packages from npm."
  else
    ok "Internet access (GitHub, Docker Hub, npm)"
  fi
}

# -------------------------------------------------------------------------------------------------
# Validation helpers (pure functions: no output, no side effects)
# -------------------------------------------------------------------------------------------------

is_ipv4() {
  local ip="$1" a b c d
  [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  a=$((10#${BASH_REMATCH[1]})); b=$((10#${BASH_REMATCH[2]}))
  c=$((10#${BASH_REMATCH[3]})); d=$((10#${BASH_REMATCH[4]}))
  (( a <= 255 && b <= 255 && c <= 255 && d <= 255 ))
}

is_domain() {
  local d="${1,,}"
  [[ -n "$d" && ${#d} -le 253 ]] || return 1
  is_ipv4 "$d" && return 1
  [[ "$d" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+([a-z]{2,63}|xn--[a-z0-9-]{1,59})$ ]]
}

is_email() { [[ "$1" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; }

# Deliberately excludes quotes, backslashes, $, backticks and whitespace: these URLs are written
# into config files and curl config.
is_safe_url() {
  local re='^https?://[][A-Za-z0-9._~:/?#@!&()*+,;=%-]+$'
  [[ "$1" =~ $re ]]
}

is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }

url_scheme() { printf '%s' "${1%%://*}"; }

url_authority() {
  local u="${1#*://}"
  u="${u%%/*}"
  printf '%s' "${u##*@}"
}

url_host() {
  local a
  a="$(url_authority "$1")"
  if [[ "$a" == \[* ]]; then
    a="${a%%]*}"
    a="${a#[}"
  else
    a="${a%%:*}"
  fi
  printf '%s' "${a,,}"
}

url_port() {
  local a
  a="$(url_authority "$1")"
  if [[ "$a" == \[*\]:* ]]; then
    printf '%s' "${a##*]:}"
  elif [[ "$a" != \[* && "$a" == *:* ]]; then
    printf '%s' "${a##*:}"
  fi
}

# normalize_ha_url INPUT -> canonical http(s)://host[:port][/path], or exit 1
normalize_ha_url() {
  local raw scheme rest auth path host port
  raw="$(trim "$1")"
  [[ -n "$raw" ]] || return 1

  if [[ "$raw" != *://* ]]; then
    host="$(url_host "http://$raw")"
    port="$(url_port "http://$raw")"
    if [[ "$host" == *.nabu.casa || "$port" == 443 ]]; then raw="https://$raw"; else raw="http://$raw"; fi
  fi

  scheme="$(url_scheme "$raw")"
  case "$scheme" in http|https) ;; *) return 1 ;; esac

  raw="${raw%%#*}"
  raw="${raw%%\?*}"
  rest="${raw#*://}"
  auth="${rest%%/*}"
  path=""
  [[ "$rest" == */* ]] && path="/${rest#*/}"

  # People paste the address of a dashboard page; keep only the base.
  path="$(sed -E 's#^/(lovelace|config|dashboard-[^/]*|developer-tools|profile|history|logbook|map|energy|api)(/.*)?$##' <<<"$path")"
  path="${path%/}"

  [[ -n "$auth" && "$auth" != *@* ]] || return 1
  if [[ "$scheme" == http && "$auth" != *:* ]]; then
    auth="$auth:8123"
  elif [[ "$scheme" == http && "$auth" == \[*\] ]]; then
    auth="$auth:8123"
  fi

  printf '%s://%s%s' "$scheme" "$auth" "$path"
}

# ha_url_class URL -> local | mdns | private | vpn | public
ha_url_class() {
  local host
  host="$(url_host "$1")"
  case "$host" in
    localhost|127.*|::1|0.0.0.0|host.docker.internal) echo local; return ;;
    *.local) echo mdns; return ;;
  esac
  if is_ipv4 "$host"; then
    if [[ "$host" =~ ^(10\.|192\.168\.|169\.254\.|172\.(1[6-9]|2[0-9]|3[01])\.) ]]; then echo private; return; fi
    if [[ "$host" =~ ^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\. ]]; then echo vpn; return; fi
  elif [[ "$host" != *.* ]]; then
    echo mdns
    return
  fi
  echo public
}

# ha_url_rewrite_local URL -> same URL with the host replaced by host.docker.internal
ha_url_rewrite_local() {
  local scheme rest auth path port
  scheme="$(url_scheme "$1")"
  rest="${1#*://}"
  auth="${rest%%/*}"
  path=""
  [[ "$rest" == */* ]] && path="/${rest#*/}"
  port="$(url_port "$1")"
  printf '%s://host.docker.internal%s%s' "$scheme" "${port:+:$port}" "$path"
}

# The address the *host* can use to test a URL that is written for the container.
ha_url_for_host_test() {
  if [[ "$(url_host "$1")" == host.docker.internal ]]; then
    local port
    port="$(url_port "$1")"
    printf '%s://127.0.0.1%s%s' "$(url_scheme "$1")" "${port:+:$port}" "$(sed -E 's#^[a-z]+://[^/]*##' <<<"$1")"
  else
    printf '%s' "$1"
  fi
}

# token_problem TOKEN -> prints why it is unsuitable (nothing if fine)
token_problem() {
  local t="$1"
  [[ -n "$t" ]] || { printf 'it is empty'; return; }
  if [[ ! "$t" =~ ^[A-Za-z0-9._~+/=-]+$ ]]; then
    printf 'it contains unexpected characters (Home Assistant tokens use letters, numbers, dots, dashes and underscores; did extra text get pasted?)'
    return
  fi
  (( ${#t} >= 20 )) || printf 'it is too short to be a long-lived access token'
}

# password_problem PW -> prints why it is unsuitable (nothing if fine)
password_problem() {
  local p="$1"
  if (( ${#p} < 8 )); then printf 'it must be at least 8 characters'; return; fi
  if [[ "$p" != "$(trim "$p")" ]]; then printf 'it must not start or end with a space (the server trims it)'; return; fi
  if LC_ALL=C grep -q '[^ -~]' <<<"$p"; then printf 'use printable ASCII characters only (letters, numbers, symbols)'; return; fi
}

# normalize_ip_list "1.2.3.4, 10.0.0.0/8" -> "1.2.3.4 10.0.0.0/8", or exit 1
normalize_ip_list() {
  local items item addr prefix out=()
  read -ra items <<<"${1//,/ }"
  for item in "${items[@]}"; do
    addr="${item%%/*}"
    prefix=""
    [[ "$item" == */* ]] && prefix="${item#*/}"
    if is_ipv4 "$addr"; then
      [[ -z "$prefix" || ( "$prefix" =~ ^[0-9]{1,2}$ && "$prefix" -le 32 ) ]] || return 1
    elif [[ "$addr" =~ ^[0-9A-Fa-f:]+$ && "$addr" == *:*:* ]]; then
      [[ -z "$prefix" || ( "$prefix" =~ ^[0-9]{1,3}$ && "$prefix" -le 128 ) ]] || return 1
    else
      return 1
    fi
    out+=("$item")
  done
  (( ${#out[@]} > 0 )) || return 1
  printf '%s' "${out[*]}"
}

# Random bytes come straight from the kernel, so no extra tool is needed to ask the questions.
gen_alnum() { # gen_alnum LENGTH
  local len="$1" raw=""
  while (( ${#raw} < len )); do
    raw+="$(head -c $((len * 3)) /dev/urandom | base64 | tr -dc 'A-Za-z0-9')"
  done
  printf '%s' "${raw:0:len}"
}

# 32 random bytes, standard base64: what the README asks for (`openssl rand -base64 32`).
gen_session_secret() { head -c 32 /dev/urandom | base64 | tr -d '\n'; }
gen_hash_secret() { head -c 48 /dev/urandom | base64 | tr -d '\n' | tr '+/' '-_' | tr -d '='; }

# -------------------------------------------------------------------------------------------------
# Configuration model
#
# Precedence, lowest to highest: built-in defaults < existing .env < --config FILE < environment
# variables named like the keys below < answers typed in the wizard.
# -------------------------------------------------------------------------------------------------

CFG_KEYS=(
  COMPOSE_PROJECT_NAME COMPOSE_PROFILES COMPOSE_FILE
  GATEKEEPER_MODE GATEKEEPER_DOMAIN ACME_EMAIL GATEKEEPER_PUBLIC_URL
  GATEKEEPER_PORT GATEKEEPER_BIND GATEKEEPER_DATA_DIR
  HA_BASE_URL HA_TOKEN ADMIN_PASSWORD ADMIN_SESSION_SECRET API_KEY_HASH_SECRET
  CORS_ORIGIN TRUST_PROXY AUDIT_LOG_RETENTION_DAYS LOG_LEVEL HA_CA_CERT
  ADMIN_ALLOWED_IPS ALERT_WEBHOOK_URL
)

# Only these may come from the process environment. Deliberately not COMPOSE_*, LOG_LEVEL or
# PORT: those are commonly exported in a shell for unrelated tools and must not hijack an install.
ENV_ACCEPTED_KEYS=(
  GATEKEEPER_MODE GATEKEEPER_DOMAIN ACME_EMAIL HA_BASE_URL HA_TOKEN ADMIN_PASSWORD
  ADMIN_SESSION_SECRET API_KEY_HASH_SECRET AUDIT_LOG_RETENTION_DAYS
  ADMIN_ALLOWED_IPS ALERT_WEBHOOK_URL GATEKEEPER_PORT GATEKEEPER_DATA_DIR GATEKEEPER_PUBLIC_URL
)

# Keys that are only meaningful inside the compose project itself; empty ones are not written.
COMPOSE_CONTROL_KEYS=(COMPOSE_PROFILES COMPOSE_FILE)

declare -gA CFG=()

cfg_defaults() {
  local key
  CFG=()
  for key in "${CFG_KEYS[@]}"; do CFG[$key]=""; done
  CFG[COMPOSE_PROJECT_NAME]="ha-gatekeeper"
  CFG[GATEKEEPER_PORT]="8080"
  CFG[GATEKEEPER_BIND]="127.0.0.1"
  CFG[GATEKEEPER_DATA_DIR]="./data"
  CFG[AUDIT_LOG_RETENTION_DAYS]="90"
  CFG[LOG_LEVEL]="info"
}

cfg_load_file() { # cfg_load_file FILE
  local file="$1" key value
  [[ -r "$file" ]] || return 0
  for key in "${CFG_KEYS[@]}"; do
    if value="$(env_file_get "$file" "$key")"; then
      CFG[$key]="$value"
    fi
  done
}

GATEKEEPER_PORT_REQUESTED=""   # set when the user asked for a specific port (then it is never changed silently)
cfg_load_environment() {
  local key
  for key in "${ENV_ACCEPTED_KEYS[@]}"; do
    if [[ -n "${!key:-}" ]]; then
      CFG[$key]="${!key}"
    fi
  done
  if [[ -n "${GATEKEEPER_PORT:-}" ]]; then GATEKEEPER_PORT_REQUESTED=1; fi
}

cfg_get() { printf '%s' "${CFG[$1]:-}"; }

is_compose_control_key() {
  local k
  for k in "${COMPOSE_CONTROL_KEYS[@]}"; do [[ "$k" == "$1" ]] && return 0; done
  return 1
}

data_dir_abs() {
  local d="${CFG[GATEKEEPER_DATA_DIR]:-./data}"
  if [[ "$d" == /* ]]; then printf '%s' "$d"; else printf '%s/%s' "$APP_DIR" "${d#./}"; fi
}

# Fills in everything that follows from the choices above (mode, domain, HA address).
derive_config() {
  local mode="${CFG[GATEKEEPER_MODE]:-local}" host="${CFG[GATEKEEPER_DOMAIN]:-}" port="${CFG[GATEKEEPER_PORT]:-8080}"
  CFG[GATEKEEPER_MODE]="$mode"

  case "$mode" in
    domain|selfsigned)
      CFG[COMPOSE_PROFILES]="proxy"
      CFG[TRUST_PROXY]="1"
      CFG[GATEKEEPER_PUBLIC_URL]="https://$host"
      ;;
    *)
      CFG[COMPOSE_PROFILES]=""
      CFG[GATEKEEPER_DOMAIN]=""
      local pub="${CFG[GATEKEEPER_PUBLIC_URL]:-}"
      if [[ "$pub" == https://* ]] && is_safe_url "$pub"; then
        # Behind a web server you already run (nginx, Apache...): it terminates HTTPS and forwards
        # to 127.0.0.1, one proxy hop, so client IPs are read from X-Forwarded-For.
        CFG[GATEKEEPER_PUBLIC_URL]="https://$(url_authority "$pub")"
        CFG[TRUST_PROXY]="1"
      else
        CFG[GATEKEEPER_PUBLIC_URL]="http://localhost:$port"
        CFG[TRUST_PROXY]=""
      fi
      ;;
  esac
  CFG[CORS_ORIGIN]="${CFG[GATEKEEPER_PUBLIC_URL]}"

  # "localhost" inside the container is the container itself, so an HA on this same server has to
  # be addressed as host.docker.internal (enabled through a small compose override).
  if [[ -n "${CFG[HA_BASE_URL]:-}" && "$(ha_url_class "${CFG[HA_BASE_URL]}")" == local ]]; then
    CFG[HA_BASE_URL]="$(ha_url_rewrite_local "${CFG[HA_BASE_URL]}")"
  fi
  if [[ "$(url_host "${CFG[HA_BASE_URL]:-}")" == host.docker.internal ]]; then
    CFG[COMPOSE_FILE]="docker-compose.yml:deploy/compose.host-access.yml"
  else
    CFG[COMPOSE_FILE]=""
  fi
}

ensure_secrets() {
  # Existing secrets are never replaced: API_KEY_HASH_SECRET signs every issued token.
  if [[ -z "${CFG[ADMIN_SESSION_SECRET]:-}" ]]; then
    CFG[ADMIN_SESSION_SECRET]="$(gen_session_secret)"
  fi
  if [[ -z "${CFG[API_KEY_HASH_SECRET]:-}" ]]; then
    CFG[API_KEY_HASH_SECRET]="$(gen_hash_secret)"
  fi
}

# config_problems -> prints one problem per line (nothing if the configuration is valid)
config_problems() {
  local mode="${CFG[GATEKEEPER_MODE]:-}" p
  case "$mode" in
    domain)
      is_domain "${CFG[GATEKEEPER_DOMAIN]:-}" || echo "GATEKEEPER_DOMAIN is not a valid domain name"
      [[ -z "${CFG[ACME_EMAIL]:-}" ]] || is_email "${CFG[ACME_EMAIL]}" || echo "ACME_EMAIL is not a valid e-mail address"
      ;;
    selfsigned)
      is_ipv4 "${CFG[GATEKEEPER_DOMAIN]:-}" || is_domain "${CFG[GATEKEEPER_DOMAIN]:-}" || echo "GATEKEEPER_DOMAIN must be this server's IP address (or a host name)"
      ;;
    local) ;;
    *) echo "GATEKEEPER_MODE must be domain, selfsigned or local (got '${mode}')" ;;
  esac

  if [[ -z "${CFG[HA_BASE_URL]:-}" ]]; then
    echo "HA_BASE_URL is missing"
  elif ! is_safe_url "${CFG[HA_BASE_URL]}"; then
    echo "HA_BASE_URL must be a plain http(s) URL"
  fi

  p="$(token_problem "${CFG[HA_TOKEN]:-}")"
  [[ -z "$p" ]] || echo "HA_TOKEN: $p"

  p="$(password_problem "${CFG[ADMIN_PASSWORD]:-}")"
  [[ -z "$p" ]] || echo "ADMIN_PASSWORD: $p"

  local sess="${CFG[ADMIN_SESSION_SECRET]:-}" hash="${CFG[API_KEY_HASH_SECRET]:-}"
  (( ${#sess} >= 8 )) || echo "ADMIN_SESSION_SECRET is missing or too short"
  (( ${#hash} >= 16 )) || echo "API_KEY_HASH_SECRET is missing or too short (min 16)"

  is_uint "${CFG[AUDIT_LOG_RETENTION_DAYS]:-}" || echo "AUDIT_LOG_RETENTION_DAYS must be a whole number (0 keeps everything)"
  case "${CFG[LOG_LEVEL]:-info}" in trace|debug|info|warn|error|fatal) ;; *) echo "LOG_LEVEL must be trace, debug, info, warn, error or fatal" ;; esac
  local port="${CFG[GATEKEEPER_PORT]:-}"
  if ! is_uint "$port" || (( port < 1 || port > 65535 )); then echo "GATEKEEPER_PORT must be 1-65535"; fi

  if [[ -n "${CFG[ALERT_WEBHOOK_URL]:-}" ]] && ! is_safe_url "${CFG[ALERT_WEBHOOK_URL]}"; then
    echo "ALERT_WEBHOOK_URL must be a plain http(s) URL"
  fi
  if [[ -n "${CFG[ADMIN_ALLOWED_IPS]:-}" ]] && ! normalize_ip_list "${CFG[ADMIN_ALLOWED_IPS]}" >/dev/null; then
    echo "ADMIN_ALLOWED_IPS must be a list of IPs/CIDRs"
  fi
  return 0
}

cfg_is_complete() { [[ -z "$(config_problems)" ]]; }

# Writes .env atomically with mode 600. Keys the installer does not know are preserved verbatim.
write_env_file() {
  local file="$APP_DIR/.env" prev="$APP_DIR/.env.previous" tmp key line extras=() bak
  if [[ -f "$file" ]]; then
    bak="$(jbackup "$file")"
    jpush "Updated $file (the previous settings are put back on rollback)" rv_restore_env "$bak" "$STACK_PRE"
    if [[ -e "$prev" ]]; then
      jpush "Replaced $prev" rv_restore "$prev" "$(jbackup "$prev")"
    else
      jpush "Created $prev (copy of the old settings)" rv_rm "$prev"
    fi
    cp -p "$file" "$prev" 2>/dev/null || true
    chmod 600 "$prev" 2>/dev/null || true
    while IFS= read -r line; do
      if [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*= ]]; then
        key="${BASH_REMATCH[2]}"
        local known=false k
        for k in "${CFG_KEYS[@]}"; do [[ "$k" == "$key" ]] && known=true; done
        $known || extras+=("$line")
      fi
    done <"$file"
  fi

  tmp="$(mktemp "$APP_DIR/.env.XXXXXX")"
  {
    echo "# HA Gatekeeper configuration. Generated by install.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)."
    echo "# Re-run  sudo ./install.sh  to change settings. Keep this file private: it holds secrets."
    printf '%s\n' '# Values are double-quoted; inside quotes write  \\  for a backslash,  \"  for a quote,  \$  for a dollar sign.'
    echo "# BACK THIS FILE UP: API_KEY_HASH_SECRET cannot be recovered and every issued token depends on it."
    echo
    for key in "${CFG_KEYS[@]}"; do
      if is_compose_control_key "$key" && [[ -z "${CFG[$key]:-}" ]]; then
        printf '# %s is not set\n' "$key"
      else
        printf '%s=%s\n' "$key" "$(env_quote "${CFG[$key]:-}")"
      fi
    done
    if (( ${#extras[@]} > 0 )); then
      echo
      echo "# Preserved custom settings (not managed by install.sh)"
      printf '%s\n' "${extras[@]}"
    fi
  } >"$tmp"
  chmod 600 "$tmp"
  [[ -f "$file" ]] || jpush "Created $file (your settings and secrets, mode 600)" rv_rm "$file"
  mv -f "$tmp" "$file"
}

# The container reads its secrets from files, not environment variables (those show up in
# `docker inspect` and /proc). .env stays the master copy; these files are rewritten from it
# before every start. The folder is root-only; each file is readable by the app's user only.
SECRETS_CHANGED=false   # a secret file was (re)written: a running container must be recreated to see it
SECRET_FILE_MAP=(HA_TOKEN:ha_token ADMIN_PASSWORD:admin_password ADMIN_SESSION_SECRET:admin_session_secret API_KEY_HASH_SECRET:api_key_hash_secret)
sync_secret_files() {
  local dir="$APP_DIR/secrets" pair key name val path tmp dir_new=false
  [[ -d "$dir" ]] || dir_new=true
  jx_mkdir "$dir" tree
  chown root:root "$dir" 2>/dev/null || true
  chmod 700 "$dir"
  for pair in "${SECRET_FILE_MAP[@]}"; do
    key="${pair%%:*}"; name="${pair#*:}"
    val="${CFG[$key]:-}"
    if [[ -z "$val" ]]; then
      err "$key is empty, so secrets/$name cannot be written."
      return 1
    fi
    path="$dir/$name"
    # A missing bind-mount source makes Docker create an (empty) folder in its place.
    if [[ -d "$path" && ! -L "$path" ]]; then
      rmdir "$path" 2>/dev/null || { err "$path is a folder and not empty; remove it and re-run."; return 1; }
    fi
    if [[ ! -f "$path" || "$(cat "$path" 2>/dev/null)" != "$val" ]]; then
      $dir_new || [[ -e "$path" ]] || jpush "Created $path" rv_rm "$path"
      tmp="$(mktemp "$dir/.s.XXXXXX")"
      printf '%s' "$val" >"$tmp"
      mv -f "$tmp" "$path"
      SECRETS_CHANGED=true
    fi
    chmod 400 "$path"
    chown "$SERVICE_UID:$SERVICE_UID" "$path" 2>/dev/null || chmod 444 "$path"
  done
}

# -------------------------------------------------------------------------------------------------
# Home Assistant connection test (from this host; verify repeats it from inside the container)
# -------------------------------------------------------------------------------------------------

HA_HTTP_CODE=""
HA_CURL_RC=0
HA_CURL_ERR=""
HA_VERSION=""
HA_LOCATION=""

# ha_probe URL TOKEN [CACERT]  -> sets HA_* globals; returns 0 only for an authenticated 200
ha_probe() {
  local url="${1%/}" token="$2" cacert="${3:-}" cfg body errf rc=0
  HA_HTTP_CODE=""; HA_CURL_RC=0; HA_CURL_ERR=""; HA_VERSION=""; HA_LOCATION=""

  cfg="$(mktemp_tracked)"; body="$(mktemp_tracked)"; errf="$(mktemp_tracked)"
  chmod 600 "$cfg"
  printf 'header = "Authorization: Bearer %s"\nurl = "%s/api/config"\n' "$token" "$url" >"$cfg"

  local args=(-sS --connect-timeout 8 --max-time 20 -o "$body" -w '%{http_code}' -K "$cfg")
  [[ -z "$cacert" ]] || args+=(--cacert "$cacert")

  HA_HTTP_CODE="$(curl "${args[@]}" 2>"$errf")" || rc=$?
  HA_CURL_RC=$rc
  HA_CURL_ERR="$(tr -d '\r' <"$errf" | head -n 1)" || true

  if [[ "$HA_HTTP_CODE" == 200 ]]; then
    HA_VERSION="$(jq -r '.version // empty' "$body" 2>/dev/null || true)"
    HA_LOCATION="$(jq -r '.location_name // empty' "$body" 2>/dev/null || true)"
    rm -f "$cfg" "$body" "$errf"
    return 0
  fi
  rm -f "$cfg" "$body" "$errf"
  return 1
}

ha_explain_failure() { # ha_explain_failure URL
  local url="$1" host cls
  host="$(url_host "$url")"
  cls="$(ha_url_class "$url")"

  case "$HA_CURL_RC" in
    0) ;;
    6)
      err "Cannot resolve '$host'."
      [[ "$cls" == mdns ]] && hint "Names like homeassistant.local only work on your home network; a VPS cannot see them."
      hint "Use an address that resolves from the internet (Nabu Casa, DuckDNS, your own domain) or a VPN IP."
      return ;;
    7)
      err "Connection refused by $host."
      hint "Home Assistant is not listening there (wrong port? HA defaults to 8123), or a firewall rejects the connection."
      return ;;
    28)
      err "Timed out connecting to $host."
      case "$cls" in
        private|mdns) hint "That looks like a home-network address. A VPS cannot reach it unless you connect the two with a VPN (Tailscale or WireGuard)." ;;
        *) hint "Check that the port is open to this server's IP and that Home Assistant is reachable from the internet." ;;
      esac
      return ;;
    35|51|58|60|77|83)
      err "TLS/certificate problem talking to $host: ${HA_CURL_ERR:-see log}"
      hint "If Home Assistant uses a self-signed or private-CA certificate, re-run and provide its CA file under advanced options."
      hint "Otherwise check that the certificate is valid for '$host' and not expired."
      return ;;
    *)
      err "Could not connect to $url (curl exit $HA_CURL_RC): ${HA_CURL_ERR:-no details}"
      return ;;
  esac

  case "$HA_HTTP_CODE" in
    401|403) err "Home Assistant answered, but rejected the token (HTTP $HA_HTTP_CODE)."
             hint "Create a fresh long-lived access token: Home Assistant -> your profile -> Security -> Long-lived access tokens." ;;
    404) err "Got HTTP 404 from $url/api/config."
         hint "That does not look like the root of a Home Assistant instance. Use just the base address (no /lovelace, /config...)." ;;
    5??) err "Home Assistant (or the proxy in front of it) returned HTTP $HA_HTTP_CODE. Is it fully started?" ;;
    *)   err "Unexpected HTTP status '${HA_HTTP_CODE:-none}' from $url/api/config." ;;
  esac
}

# -------------------------------------------------------------------------------------------------
# Network helpers
# -------------------------------------------------------------------------------------------------

public_ip() { # public_ip 4|6
  local family="$1" url ip
  for url in https://api.ipify.org https://ipv4.icanhazip.com https://checkip.amazonaws.com https://ifconfig.me/ip; do
    [[ "$family" == 6 ]] && url="${url/api.ipify.org/api6.ipify.org}" && url="${url/ipv4.icanhazip/ipv6.icanhazip}"
    ip="$(curl "-$family" -fsS --connect-timeout 5 --max-time 8 "$url" 2>/dev/null | tr -d '[:space:]')" || continue
    if [[ "$family" == 4 ]] && is_ipv4 "$ip"; then printf '%s' "$ip"; return 0; fi
    if [[ "$family" == 6 && "$ip" == *:* && "$ip" =~ ^[0-9A-Fa-f:]+$ ]]; then printf '%s' "$ip"; return 0; fi
  done
  return 1
}

dns_records() { # dns_records HOST 4|6 -> one address per line
  local host="$1" family="$2"
  getent "ahostsv$family" "$host" 2>/dev/null | awk '{print $1}' | sort -u || true
}

# port_in_use PORT -> 0 if something is listening on that TCP port (any address)
port_in_use() {
  local hex f files=()
  hex="$(printf '%04X' "$1")"
  # Only pass files that exist: awk aborts before END when handed a missing one, and
  # /proc/net/tcp6 is absent on hosts with IPv6 disabled.
  for f in /proc/net/tcp /proc/net/tcp6; do
    [[ -r "$f" ]] && files+=("$f")
  done
  (( ${#files[@]} > 0 )) || return 1
  awk -v hex="$hex" '
    FNR > 1 && $4 == "0A" { n = split($2, a, ":"); if (toupper(a[n]) == hex) found = 1 }
    END { exit !found }' "${files[@]}"
}

port_owner() { # best-effort name of the process listening on PORT
  local port="$1" line=""
  if have ss; then
    line="$(ss -H -ltnp "sport = :$port" 2>/dev/null | head -n 1)" || true
    if [[ "$line" =~ users:\(\(\"([^\"]+)\",pid=([0-9]+) ]]; then
      printf '%s (pid %s)' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
      return 0
    fi
  fi
  return 1
}

# stack_publishes_port PORT -> 0 if our own Caddy container is what holds that port
stack_publishes_port() {
  docker_up || return 1
  docker inspect --type container --format '{{json .NetworkSettings.Ports}}' "$CADDY_CONTAINER" 2>/dev/null \
    | grep -q "\"$1/tcp\""
}

# -------------------------------------------------------------------------------------------------
# Docker and Docker Compose
# -------------------------------------------------------------------------------------------------

have_systemd() { have systemctl && [[ -d /run/systemd/system ]]; }
docker_ready() { timeout 20 docker info >/dev/null 2>&1; }
compose_ok() { docker compose version >/dev/null 2>&1; }

# True only when the Docker daemon is ALREADY running. Unlike docker_ready it never wakes a
# stopped daemon: with systemd socket activation, merely running a docker command would start it.
docker_up() {
  have docker || return 1
  if have_systemd && systemctl cat docker.service >/dev/null 2>&1; then
    systemctl is-active --quiet docker.service || return 1
  fi
  docker_ready
}

compose_version_ok() {
  local v major
  v="$(docker compose version --short 2>/dev/null || true)"
  v="${v#v}"
  major="${v%%.*}"
  [[ "$major" =~ ^[0-9]+$ ]] && (( major >= 2 ))
}

# What has to happen to Docker (read-only):  ok | install | start
P_DOCKER=ok
P_COMPOSE_NEEDED=false
P_DOCKER_BOOT=false
docker_plan() {
  P_DOCKER=ok; P_COMPOSE_NEEDED=false; P_DOCKER_BOOT=false
  if ! have docker; then
    P_DOCKER=install
    return 0
  fi
  if have_systemd && systemctl cat docker.service >/dev/null 2>&1; then
    local state i
    state="$(systemctl is-active docker.service 2>/dev/null || true)"
    if [[ "$state" == activating ]]; then
      for i in $(seq 1 15); do
        sleep 2
        state="$(systemctl is-active docker.service 2>/dev/null || true)"
        [[ "$state" == activating ]] || break
      done
    fi
    [[ "$state" == active ]] || P_DOCKER=start
    systemctl is-enabled --quiet docker.service 2>/dev/null || P_DOCKER_BOOT=true
  fi
  if [[ "$P_DOCKER" == ok ]] && ! docker_ready; then P_DOCKER=start; fi
  if ! { compose_ok && compose_version_ok; }; then P_COMPOSE_NEEDED=true; fi
  return 0
}

# Docker is installed but stopped: starting it also starts every other container with a restart
# policy, so this needs an explicit yes (unattended: GATEKEEPER_START_DOCKER=1).
decide_docker_start() {
  [[ "$P_DOCKER" == start ]] || return 0
  $DRY_RUN && return 0
  say ""
  warn "Docker is installed on this server but not running."
  say "  Starting it will ALSO START every other container here that has a restart policy (your other apps)."
  if [[ "${GATEKEEPER_START_DOCKER:-}" == 1 ]]; then
    say "  GATEKEEPER_START_DOCKER=1 is set, so that is allowed."
  elif interactive; then
    confirm "Start the Docker service now?" n || die "Cancelled. Nothing was changed. Start Docker yourself when you are ready, then run the installer again."
  else
    die "Docker is installed but stopped, and starting it would also start your other containers. Start it yourself, or set GATEKEEPER_START_DOCKER=1 to allow it. Nothing was changed."
  fi
}

install_docker() {
  local script snap before had_d=0 had_c=0
  script="$(mktemp_tracked)"
  info "Installing Docker Engine (official installer from get.docker.com)"
  if ! retry 3 5 curl -fsSL --connect-timeout 10 --max-time 90 https://get.docker.com -o "$script"; then
    err "Could not download the Docker installer from get.docker.com"
    return 1
  fi
  [[ -d /var/lib/docker ]] && had_d=1
  [[ -d /var/lib/containerd ]] && had_c=1
  snap="$(journal_tmp)/pkgs.docker"
  before="$(journal_tmp)/files.docker"
  pkg_snapshot "$snap" || : >"$snap"
  find /etc/apt/sources.list.d /etc/apt/keyrings /usr/share/keyrings /etc/yum.repos.d -maxdepth 1 -type f 2>/dev/null | LC_ALL=C sort >"$before" || true
  J_KEEP_NEXT=1 jpush "Installed Docker Engine (docker-ce, containerd and the Compose plugin, from get.docker.com)" rv_docker_engine "$snap" "$before" "$had_d" "$had_c"
  wait_for_apt_lock
  apt_lock_conf_on
  if run_logged "Running the Docker installer (takes a minute or two)" sh "$script"; then
    apt_lock_conf_off
    return 0
  fi
  apt_lock_conf_off

  warn "The official installer failed; trying the distribution's own Docker package."
  case "$PKG" in
    apt) pkg_install docker.io ;;
    zypper) pkg_install docker ;;
    apk) pkg_install docker docker-cli-compose ;;
    pacman) pkg_install docker docker-compose ;;
    *) return 1 ;;
  esac
}

# Start the Docker service. Callers have the user's consent (or the user asked for it).
start_docker() {
  docker_ready && return 0
  info "Starting the Docker service"
  if have_systemd; then
    systemctl enable --now docker >>"$LOG_FILE" 2>&1 || true
  elif have service; then
    service docker start >>"$LOG_FILE" 2>&1 || true
  fi
  local i
  for i in $(seq 1 30); do
    docker_ready && return 0
    sleep 2
  done
  die "The Docker daemon is not responding. Check: systemctl status docker  and  journalctl -u docker -n 50"
}

ensure_compose() {
  if compose_ok && compose_version_ok; then
    ok "Docker Compose $(docker compose version --short 2>/dev/null)"
    return 0
  fi

  info "Docker Compose v2 not found; installing it"
  jx_pkg_install docker-compose-plugin >/dev/null 2>&1 || jx_pkg_install docker-compose-v2 >/dev/null 2>&1 || true
  if compose_ok && compose_version_ok; then
    ok "Docker Compose $(docker compose version --short 2>/dev/null)"
    return 0
  fi

  local arch dest url
  case "$(uname -m)" in
    x86_64|amd64) arch=x86_64 ;;
    aarch64|arm64) arch=aarch64 ;;
    armv7l) arch=armv7 ;;
    *) die "No Docker Compose build for CPU '$(uname -m)'. Install the Compose v2 plugin manually and re-run." ;;
  esac
  dest=/usr/local/lib/docker/cli-plugins
  url="https://github.com/docker/compose/releases/latest/download/docker-compose-linux-$arch"
  jx_mkdir "$dest"
  info "Downloading the Docker Compose plugin from GitHub"
  [[ -e "$dest/docker-compose" ]] || { J_KEEP_NEXT=1 jpush "Downloaded the Docker Compose plugin to $dest/docker-compose" rv_rm "$dest/docker-compose"; }
  retry 3 5 curl -fsSL --connect-timeout 10 --max-time 180 -o "$dest/docker-compose" "$url" \
    || die "Could not download Docker Compose from $url"
  chmod +x "$dest/docker-compose"
  if ! compose_ok || ! compose_version_ok; then
    die "Docker Compose still does not work after installing it. See $LOG_FILE"
  fi
  ok "Docker Compose $(docker compose version --short 2>/dev/null) installed"
}

ensure_docker() {
  if [[ "$P_DOCKER" == install ]]; then
    have curl || die "curl is required to install Docker"
    install_docker || die "Docker could not be installed automatically. Install Docker Engine (https://docs.docker.com/engine/install/) and re-run this script."
    have docker || die "Docker was installed but the 'docker' command is not on PATH."
    ok "Docker installed"
  else
    ok "Docker found: $(docker --version 2>/dev/null | head -n 1)"
  fi
  DOCKER_BIN="$(command -v docker)"
  if [[ "$P_DOCKER" == start ]]; then
    J_KEEP_NEXT=1 jpush "Started the Docker service (it was stopped; this also started your other containers)" rv_note "Docker was left running: stopping it would stop your other containers too"
    start_docker
  else
    start_docker
  fi
  ensure_compose

  if have_systemd; then
    if systemctl is-enabled docker >/dev/null 2>&1; then
      ok "Docker starts automatically at boot"
    else
      jpush "Enabled the Docker service at boot" rv_docker_boot_disable
      J_KEEP[J_LAST]=1
      if systemctl enable docker >>"$LOG_FILE" 2>&1; then
        ok "Enabled Docker at boot"
      else
        jdrop "$J_LAST"
        warn "Could not enable Docker at boot (systemctl enable docker failed)."
      fi
    fi
  fi
}

dc() { ( cd "$APP_DIR" && docker compose "$@" ); }

caddy_image() {
  local img
  img="$(env_file_get "$APP_DIR/.env" CADDY_IMAGE 2>/dev/null || true)"
  printf '%s' "${img:-caddy:2-alpine}"
}

proxy_enabled() { [[ ",${CFG[COMPOSE_PROFILES]:-}," == *,proxy,* ]]; }

# Base images named in the Dockerfile's FROM lines (skips references to earlier build stages).
dockerfile_images() {
  awk '
    toupper($1) == "FROM" {
      img = ""
      for (i = 2; i <= NF; i++) { if ($i ~ /^--/) continue; img = $i; break }
      if (img != "" && !(tolower(img) in stage)) print img
      for (i = 2; i <= NF; i++) if (toupper($i) == "AS") stage[tolower($(i + 1))] = 1
    }' "$APP_DIR/Dockerfile" | sort -u
}

needed_images() {
  dockerfile_images
  if proxy_enabled; then caddy_image; echo; fi
}

# Docker Hub rate-limits anonymous pulls per IP, which shared VPS networks hit regularly. The
# official images are also served by other registries, so fall back to those and retag.
pull_with_fallback() {
  local image="$1" name mirror first
  local idx
  if docker image inspect "$image" >/dev/null 2>&1; then
    log_file "image already present: $image"
    return 0
  fi
  J_KEEP_NEXT=1 jpush "Downloaded the Docker image $image" rv_image_rm "$image"
  idx=$J_LAST
  if retry 3 6 docker pull -q "$image" >>"$LOG_FILE" 2>&1; then
    return 0
  fi
  jdrop "$idx"

  first="${image%%/*}"
  if [[ "$image" == */* && ( "$first" == *.* || "$first" == *:* ) ]]; then
    return 1 # not a Docker Hub image: no mirror to try
  fi
  name="$image"
  [[ "$image" == */* ]] || name="library/$image"
  for mirror in mirror.gcr.io public.ecr.aws/docker; do
    warn "Pulling $image from Docker Hub failed; trying $mirror"
    J_KEEP_NEXT=1 jpush "Downloaded the Docker image $image (via $mirror)" rv_image_rm "$image" "$mirror/$name"
    idx=$J_LAST
    if docker pull -q "$mirror/$name" >>"$LOG_FILE" 2>&1 && docker tag "$mirror/$name" "$image"; then
      ok "Got $image via $mirror"
      return 0
    fi
    jdrop "$idx"
  done
  return 1
}

offer_docker_login() {
  interactive || return 1
  confirm "Log in to Docker Hub now (a free account removes the limit)?" y || return 1
  local user pass
  user="$(ask "Docker Hub username")"
  pass="$(ask_secret "Password or access token")"
  [[ -n "$user" && -n "$pass" ]] || return 1
  printf '%s' "$pass" | docker login -u "$user" --password-stdin >>"$LOG_FILE" 2>&1
}

prepull_images() {
  local img failed=()
  while IFS= read -r img; do
    [[ -n "$img" ]] || continue
    info "Fetching base image $img"
    pull_with_fallback "$img" || failed+=("$img")
  done < <(needed_images)

  (( ${#failed[@]} == 0 )) && return 0

  err "Could not download: ${failed[*]}"
  if tail -n 40 "$LOG_FILE" | grep -qi 'toomanyrequests\|rate limit'; then
    hint "Docker Hub is rate-limiting this server's IP address (common on shared VPS networks)."
  fi
  if offer_docker_login; then
    failed=()
    while IFS= read -r img; do
      [[ -n "$img" ]] || continue
      pull_with_fallback "$img" || failed+=("$img")
    done < <(needed_images)
    (( ${#failed[@]} == 0 )) && return 0
  fi
  hint "Fix: create a free account at hub.docker.com, run  docker login -u <username>  (use an access token), then re-run this script."
  return 1
}

diagnose_build_failure() {
  local tail_text
  tail_text="$(tail -n 200 "$LOG_FILE" 2>/dev/null)"
  if grep -qiE 'exit code: 137|Killed|heap out of memory|ENOMEM|cannot allocate memory' <<<"$tail_text"; then
    hint "The build ran out of memory. Add swap (re-run this script and accept the swap offer) or use a server with at least 1 GB RAM."
  elif grep -qiE 'no space left on device' <<<"$tail_text"; then
    hint "The disk is full. Free space (docker system prune -f; apt clean) and re-run."
  elif grep -qiE 'ECONNRESET|ETIMEDOUT|EAI_AGAIN|ENOTFOUND|Temporary failure in name resolution|TLS|certificate' <<<"$tail_text"; then
    hint "A download failed (network or DNS). Check connectivity from this server and re-run; it resumes from cache."
  fi
}

compose_build() {
  local attempt
  if ! docker image inspect ha-gatekeeper:local >/dev/null 2>&1; then
    jpush "Built the Docker image ha-gatekeeper:local" rv_image_rm ha-gatekeeper:local
  fi
  for attempt in 1 2 3; do
    if run_logged "Building the Gatekeeper image (attempt $attempt/3; the first build takes a few minutes)" dc build gatekeeper; then
      return 0
    fi
    if (( attempt < 3 )); then
      warn "Build failed. This is usually a network blip while downloading packages; retrying in 10s."
      sleep 10
    fi
  done
  diagnose_build_failure
  return 1
}

# wait_for_container NAME SECONDS -> 0 once running (and healthy, if it has a health check)
wait_for_container() {
  local name="$1" limit="$2" start=$SECONDS state health restarts
  while (( SECONDS - start < limit )); do
    state="$(docker inspect --type container -f '{{.State.Status}}' "$name" 2>/dev/null || echo missing)"
    health="$(docker inspect --type container -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$name" 2>/dev/null || echo none)"
    restarts="$(docker inspect --type container -f '{{.RestartCount}}' "$name" 2>/dev/null || echo 0)"
    case "$state/$health" in
      running/healthy|running/none) return 0 ;;
      exited/*|dead/*|missing/*) return 1 ;;
    esac
    (( restarts >= 3 )) && return 1
    sleep 2
  done
  return 1
}

fix_data_permissions() {
  local data
  data="$(data_dir_abs)"
  jx_mkdir "$data" tree
  [[ -e "$data/ha-gatekeeper.db" ]] || jpush "Created the database in $data (when the app first starts)" rv_rm_db "$data"
  if chown -R "$SERVICE_UID:$SERVICE_UID" "$data" 2>>"$LOG_FILE"; then
    chmod 750 "$data"
  else
    warn "Could not chown $data to uid $SERVICE_UID (unusual filesystem); making it writable for everyone instead."
    chmod -R a+rwX "$data"
  fi
}

# diagnose_gatekeeper -> prints the likely cause and returns 10 if it fixed something worth retrying
diagnose_gatekeeper() {
  local logs oom
  logs="$(docker logs --tail 200 "$GK_CONTAINER" 2>&1 || true)"
  oom="$(docker inspect --type container -f '{{.State.OOMKilled}}' "$GK_CONTAINER" 2>/dev/null || echo false)"

  if grep -qiE 'unable to open database file|P1003|SQLITE_READONLY|readonly database|EACCES|permission denied' <<<"$logs"; then
    warn "The database folder is not writable by the container user (uid $SERVICE_UID). Fixing permissions."
    fix_data_permissions
    return 10
  fi
  if [[ "$oom" == true ]]; then
    err "The container was killed for running out of memory."
    hint "Add swap or use a larger server, then re-run."
    return 0
  fi
  if grep -qE 'ZodError|invalid_string|too_small|Invalid enum value|Required' <<<"$logs"; then
    err "The app rejected its configuration."
    hint "Re-run with --reconfigure, or check .env. Problem details:"
    { grep -E '"message"|path|Invalid|too_small' <<<"$logs" | head -n 8 | sed 's/^/       | /'; } || true
    return 0
  fi
  if grep -q 'EADDRINUSE' <<<"$logs"; then
    err "The port inside the container is already in use."
    return 0
  fi
  if grep -qE 'P3009|P3018|P3005|migration.*failed' <<<"$logs"; then
    err "A database migration failed."
    hint "Your data was not modified by this step. Check the details below; a backup is in $APP_DIR/backups/ if one exists."
  else
    err "The container did not become healthy. Last log lines:"
  fi
  tail -n 15 <<<"$logs" | sed 's/^/       | /'
  return 0
}

# Record that this run is about to (re)start the containers, and which Docker volumes it creates.
STACK_PRE=0            # 1 when the stack was already installed before this run
journal_stack_start() {
  local proj="${CFG[COMPOSE_PROJECT_NAME]:-ha-gatekeeper}" v names="$GK_CONTAINER"
  proxy_enabled && names="$names, $CADDY_CONTAINER"
  if proxy_enabled; then
    for v in caddy_data caddy_config; do
      docker volume inspect "${proj}_$v" >/dev/null 2>&1 && continue
      if [[ "${CFG[GATEKEEPER_MODE]:-}" == domain ]]; then
        jpush "Created the Docker volume ${proj}_$v (HTTPS certificates)" rv_note "kept the HTTPS certificate volume ${proj}_$v because Let's Encrypt limits how often certificates can be re-issued; remove it with: docker volume rm ${proj}_$v"
      else
        jpush "Created the Docker volume ${proj}_$v" rv_volume_rm "${proj}_$v"
      fi
    done
  fi
  jpush "Started the containers: $names" rv_stack_down "$STACK_PRE"
}

remove_proxy_if_disabled() {
  proxy_enabled && return 0
  if docker inspect --type container "$CADDY_CONTAINER" >/dev/null 2>&1; then
    info "The HTTPS proxy is switched off in these settings: removing the Caddy container"
    dc --profile proxy rm -sf caddy >>"$LOG_FILE" 2>&1 || true
  fi
}

# start_stack -> builds if needed, starts, waits for health; auto-repairs the common failures
start_stack() {
  remove_proxy_if_disabled
  sync_secret_files || return 1
  journal_stack_start
  local attempt had_container=false
  docker inspect --type container "$GK_CONTAINER" >/dev/null 2>&1 && had_container=true
  for attempt in 1 2; do
    if run_logged "Starting the containers" dc up -d --remove-orphans \
      && { ! $SECRETS_CHANGED || ! $had_container || dc up -d --force-recreate --no-deps gatekeeper >>"$LOG_FILE" 2>&1; }; then
      if wait_for_container "$GK_CONTAINER" 120; then
        ok "Gatekeeper container is running and healthy"
        return 0
      fi
    fi
    diagnose_gatekeeper
    if [[ $? -eq 10 && $attempt -lt 2 ]]; then
      info "Retrying after the fix"
      dc restart gatekeeper >>"$LOG_FILE" 2>&1 || true
      continue
    fi
    return 1
  done
  return 1
}

# -------------------------------------------------------------------------------------------------
# Caddy (HTTPS reverse proxy)
# -------------------------------------------------------------------------------------------------

render_caddyfile() {
  local mode="${CFG[GATEKEEPER_MODE]}" host="${CFG[GATEKEEPER_DOMAIN]}" email="${CFG[ACME_EMAIL]:-}" allow
  allow="$(normalize_ip_list "${CFG[ADMIN_ALLOWED_IPS]:-}" 2>/dev/null || true)"

  echo "# Generated by install.sh. Change settings in .env and re-run  sudo ./install.sh  instead of editing this file."
  {
    echo "{"
    # Without this the health check's admin-API calls flood the logs every 30 seconds.
    printf '\tlog {\n\t\tlevel WARN\n\t}\n'
    if [[ "$mode" == selfsigned ]]; then
      # Browsers send no SNI when you open a bare IP, and behind a cloud's 1:1 NAT the local
      # address is not the public one, so name the certificate to use explicitly.
      printf '\tskip_install_trust\n\tdefault_sni %s\n' "$host"
    else
      [[ -z "$email" ]] || printf '\temail %s\n' "$email"
    fi
    echo "}"
  }
  echo
  if [[ "$mode" == selfsigned ]]; then
    printf 'https://%s {\n\ttls internal\n' "$host"
  else
    printf '%s {\n' "$host"
  fi
  printf '\tencode zstd gzip\n'
  if [[ -n "$allow" ]]; then
    printf '\n\t# Only these addresses may use the admin API (ADMIN_ALLOWED_IPS in .env).\n'
    printf '\t@admin_blocked {\n\t\tpath /admin/*\n\t\tnot remote_ip %s\n\t}\n' "$allow"
    printf '\trespond @admin_blocked "Forbidden" 403\n\n'
  fi
  printf '\treverse_proxy gatekeeper:8080\n}\n'
}

validate_caddyfile() { # validate_caddyfile FILE -> checks it with the real Caddy image
  docker run --rm --network none -v "$1:/tmp/Caddyfile:ro,z" "$(caddy_image)" \
    caddy validate --config /tmp/Caddyfile --adapter caddyfile >>"$LOG_FILE" 2>&1
}

CADDY_CHANGED=false
write_caddyfile() {
  local dir="$APP_DIR/deploy/caddy" tmp
  jx_mkdir "$dir"
  if ! proxy_enabled; then
    return 0
  fi
  tmp="$(mktemp "$dir/.Caddyfile.XXXXXX")"
  TMP_FILES+=("$tmp")
  render_caddyfile >"$tmp"
  chmod 644 "$tmp"
  if ! validate_caddyfile "$tmp"; then
    err "The generated Caddy configuration did not validate. Details are in $LOG_FILE"
    tail -n 8 "$LOG_FILE" | sed 's/^/       | /'
    return 1
  fi
  if [[ -f "$dir/Caddyfile" ]] && cmp -s "$tmp" "$dir/Caddyfile"; then
    CADDY_CHANGED=false
  else
    jx_install_file "$tmp" "$dir/Caddyfile" 644
    CADDY_CHANGED=true
  fi
}

# -------------------------------------------------------------------------------------------------
# Firewall
# -------------------------------------------------------------------------------------------------

ufw_active() { have ufw && ufw status 2>/dev/null | grep -q '^Status: active'; }
firewalld_active() { have firewall-cmd && firewall-cmd --state >/dev/null 2>&1; }

# SSH ports this server really listens on (so enabling a firewall can never lock you out).
ssh_ports() {
  local ports=""
  if have sshd; then
    ports="$(sshd -T 2>/dev/null | awk '/^port /{print $2}' | sort -un | tr '\n' ' ')" || true
  fi
  if [[ -z "${ports// /}" && -n "${SSH_CONNECTION:-}" ]]; then
    ports="${SSH_CONNECTION##* }"
  fi
  printf '%s' "${ports% }"
}

# host_is_self HOST -> 0 when HOST is (or resolves to) one of this server's own addresses.
host_is_self() {
  local h="$1" a own
  [[ -n "$h" ]] || return 1
  own=" $( { hostname -I 2>/dev/null; ip -o addr show 2>/dev/null | awk '{sub(/\/.*/,"",$4); print $4}'; } | tr '\n' ' ') "
  if is_ipv4 "$h"; then
    [[ "$own" == *" $h "* ]]; return
  fi
  [[ "$h" == *.* ]] || return 1
  while read -r a _; do
    [[ -n "$a" && "$own" == *" $a "* ]] && return 0
  done < <(getent ahostsv4 "$h" 2>/dev/null || true)
  return 1
}

# Home Assistant on this same server (by localhost or by the server's own address): the container
# reaches it through the Docker bridge, which a default-deny host firewall blocks. Allow just that
# port from the Docker networks.
ha_local_port() {
  local lh
  lh="$(url_host "${CFG[HA_BASE_URL]:-}")"
  [[ "$lh" == host.docker.internal ]] || host_is_self "$lh" || return 1
  local port
  port="$(url_port "${CFG[HA_BASE_URL]}")"
  [[ -n "$port" ]] || { [[ "$(url_scheme "${CFG[HA_BASE_URL]}")" == https ]] && port=443 || port=80; }
  printf '%s' "$port"
}

# Does ufw already have this rule (ignoring the comment)? Rules that already exist are never
# re-added, never recorded, and therefore never removed by a rollback.
ufw_has_rule() { # ufw_has_rule "allow 80/tcp"
  have ufw || return 1
  ufw show added 2>/dev/null | sed -E "s/ comment '.*'$//" | grep -qxF "ufw $1"
}

# fw_ufw_allow COMMENT SPEC...   e.g.  fw_ufw_allow 'HA Gatekeeper HTTP' 80/tcp
fw_ufw_allow() {
  local comment="$1"
  shift
  ufw_has_rule "allow $*" && return 0
  jpush "Added the ufw rule: allow $*" rv_ufw_delete allow "$@"
  ufw allow "$@" comment "$comment" >>"$LOG_FILE" 2>&1
}

# Decide (without changing anything) whether to switch ufw on. Turning on a firewall blocks every
# port that is not allowed, so it is always an explicit choice: never implied by --yes.
P_UFW_ENABLE=false
P_UFW_SSH_PORTS=""
ufw_decide() {
  P_UFW_ENABLE=false
  P_UFW_SSH_PORTS=""
  have ufw || return 0
  ufw_active && return 0
  [[ "${CFG[GATEKEEPER_MODE]}" == local ]] && return 0
  [[ "${GATEKEEPER_UFW:-}" == 0 ]] && return 0
  local ports
  ports="$(ssh_ports)"
  if [[ -z "$ports" ]]; then
    hint "The host firewall (ufw) is off. It could not be enabled safely because the SSH port could not be detected."
    return 0
  fi
  if [[ "${GATEKEEPER_UFW:-}" != 1 ]]; then
    interactive || return 0
    $DRY_RUN && return 0
    say ""
    say "  The server firewall (ufw) is switched off, so anything else listening on this server is reachable."
    say "  ${C_DIM}I can turn it on allowing only: SSH (port $ports), 80, 443. Other services on this server would be blocked.${C_RESET}"
    confirm "Turn the firewall on now?" n || return 0
  fi
  P_UFW_ENABLE=true
  P_UFW_SSH_PORTS="$ports"
}

enable_ufw() {
  $P_UFW_ENABLE || return 0
  local p
  for p in $P_UFW_SSH_PORTS; do
    J_KEEP_NEXT=1 fw_ufw_allow 'SSH (HA Gatekeeper installer)' "$p/tcp" || return 0
  done
  fw_ufw_allow 'HA Gatekeeper HTTP' 80/tcp || true
  fw_ufw_allow 'HA Gatekeeper HTTPS' 443/tcp || true
  fw_ufw_allow 'HA Gatekeeper HTTP/3' 443/udp || true
  J_KEEP_NEXT=1 jpush "Turned on the ufw firewall (it was off)" rv_ufw_disable
  if ufw --force enable >>"$LOG_FILE" 2>&1; then
    ok "Firewall (ufw) enabled: SSH ($P_UFW_SSH_PORTS), 80 and 443 allowed"
  else
    jdrop "$J_LAST"
    warn "Could not enable ufw."
  fi
}

# firewalld equivalents; only what is missing is added and recorded.
fw_firewalld_add() { # fw_firewalld_add service|port|rich VALUE
  local kind="$1" value="$2"
  case "$kind" in
    service) firewall-cmd --permanent --query-service="$value" >/dev/null 2>&1 && return 0; jpush "Added the firewalld service: $value" rv_firewalld service "$value"; firewall-cmd --permanent --add-service="$value" >>"$LOG_FILE" 2>&1 ;;
    port) firewall-cmd --permanent --query-port="$value" >/dev/null 2>&1 && return 0; jpush "Added the firewalld port: $value" rv_firewalld port "$value"; firewall-cmd --permanent --add-port="$value" >>"$LOG_FILE" 2>&1 ;;
    rich) firewall-cmd --permanent --query-rich-rule="$value" >/dev/null 2>&1 && return 0; jpush "Added the firewalld rule: $value" rv_firewalld rich "$value"; firewall-cmd --permanent --add-rich-rule="$value" >>"$LOG_FILE" 2>&1 ;;
  esac
}

open_firewall() {
  local touched=false hp
  hp="$(ha_local_port || true)"

  if [[ "${GATEKEEPER_UFW:-}" == 0 ]]; then
    hint "GATEKEEPER_UFW=0: the host firewall was not touched."
    [[ "${CFG[GATEKEEPER_MODE]}" == local ]] || hint "If you use one, allow inbound TCP 80 and 443 yourself."
    [[ -z "$hp" ]] || hint "Home Assistant is on this server: allow the Docker networks to reach it, for example: ufw allow from 172.16.0.0/12 to any port $hp proto tcp"
    return 0
  fi

  if [[ "${CFG[GATEKEEPER_MODE]}" != local ]]; then
    enable_ufw
    if ufw_active; then
      if fw_ufw_allow 'HA Gatekeeper HTTP' 80/tcp \
        && fw_ufw_allow 'HA Gatekeeper HTTPS' 443/tcp \
        && fw_ufw_allow 'HA Gatekeeper HTTP/3' 443/udp; then
        ok "ufw firewall: ports 80 and 443 are open"
      else
        warn "Could not add ufw rules. Run: ufw allow 80/tcp && ufw allow 443/tcp && ufw allow 443/udp"
      fi
      touched=true
    fi
    if firewalld_active; then
      if fw_firewalld_add service http && fw_firewalld_add service https \
        && fw_firewalld_add port 443/udp && firewall-cmd --reload >>"$LOG_FILE" 2>&1; then
        ok "firewalld: http/https are open"
      else
        warn "Could not update firewalld. Allow the http and https services manually."
      fi
      touched=true
    fi
    $touched || hint "No active host firewall found (ufw/firewalld), nothing to open."
    hint "If your VPS provider has its own firewall in its control panel, allow inbound TCP 80 and 443 there too."
  fi

  if [[ -n "$hp" ]]; then
    if ufw_active; then
      if fw_ufw_allow 'HA Gatekeeper -> Home Assistant' from 172.16.0.0/12 to any port "$hp" proto tcp; then
        ok "ufw: the Gatekeeper container may reach Home Assistant on port $hp (Docker networks only)"
      else
        warn "Could not add the ufw rule. Run: ufw allow from 172.16.0.0/12 to any port $hp proto tcp"
      fi
    fi
    if firewalld_active; then
      if fw_firewalld_add rich "rule family=ipv4 source address=172.16.0.0/12 port port=$hp protocol=tcp accept" \
        && firewall-cmd --reload >>"$LOG_FILE" 2>&1; then
        ok "firewalld: the Gatekeeper container may reach Home Assistant on port $hp"
      else
        warn "Could not add the firewalld rule for Home Assistant port $hp."
      fi
    fi
  fi
  return 0
}

# Remove the web / Home Assistant rules this installer added (matched by their comments) when they
# no longer apply. The SSH rule is deliberately never touched: removing it could lock you out.
remove_firewall_rules() {
  ufw_active || return 0
  local nums n
  nums="$(ufw status numbered 2>/dev/null | grep -E '# HA Gatekeeper (HTTP|HTTPS|HTTP/3|->)' | sed -E 's/^\[ *([0-9]+)\].*/\1/' | sort -rn)" || true
  for n in $nums; do ufw --force delete "$n" >>"$LOG_FILE" 2>&1 || true; done
}

# -------------------------------------------------------------------------------------------------
# Auto-restart and watchdog wiring (systemd units, or cron where there is no systemd)
# -------------------------------------------------------------------------------------------------

pause_watchdog() { # pause_watchdog SECONDS|forever
  mkdir -p "$STATE_DIR"
  if [[ "$1" == forever ]]; then
    printf 'forever' >"$STATE_DIR/paused"
  else
    printf '%s' "$(( $(date +%s) + $1 ))" >"$STATE_DIR/paused"
  fi
}

resume_watchdog() { rm -f "$STATE_DIR/paused" 2>/dev/null || true; }

pause_watchdog_for_maintenance() {
  pause_watchdog 1800
  WATCHDOG_PAUSED_BY_US=true
}

write_unit() { # write_unit NAME   (unit text on stdin)
  local tmp
  tmp="$(mktemp)"
  cat >"$tmp"
  jx_install_file "$tmp" "$SYSTEMD_DIR/$1" 644
  rm -f "$tmp"
}

install_systemd_units() {
  if [[ "$APP_DIR" =~ [[:space:]\"\'\\%$] ]]; then
    die "The install path must not contain spaces or special characters: $APP_DIR"
  fi
  jx_mkdir "$SYSTEMD_DIR"
  jpush "Reloaded the systemd configuration" rv_daemon_reload

  write_unit ha-gatekeeper.service <<EOF
[Unit]
Description=HA Gatekeeper (Docker Compose stack)
Documentation=https://github.com/srajones/ha-gatekeeper
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target
# 'gatekeeper stop' must stay stopped across a reboot.
ConditionPathExists=!$STATE_DIR/paused

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$APP_DIR
ExecStart=$DOCKER_BIN compose up -d --remove-orphans
TimeoutStartSec=900

[Install]
WantedBy=multi-user.target
EOF

  write_unit ha-gatekeeper-watchdog.service <<EOF
[Unit]
Description=HA Gatekeeper watchdog (health check and self-healing)
After=docker.service

[Service]
Type=oneshot
ExecStart=$APP_DIR/deploy/watchdog.sh
TimeoutStartSec=300
Nice=10
EOF

  write_unit ha-gatekeeper-watchdog.timer <<EOF
[Unit]
Description=Run the HA Gatekeeper watchdog every minute

[Timer]
OnCalendar=*-*-* *:*:00
AccuracySec=5s
Unit=ha-gatekeeper-watchdog.service

[Install]
WantedBy=timers.target
EOF

  write_unit ha-gatekeeper-backup.service <<EOF
[Unit]
Description=HA Gatekeeper daily backup
After=docker.service

[Service]
Type=oneshot
ExecStart=$APP_DIR/install.sh backup --quiet
TimeoutStartSec=600
Nice=10
EOF

  write_unit ha-gatekeeper-backup.timer <<EOF
[Unit]
Description=Daily HA Gatekeeper backup

[Timer]
OnCalendar=*-*-* 03:30:00
RandomizedDelaySec=300
Persistent=true
Unit=ha-gatekeeper-backup.service

[Install]
WantedBy=timers.target
EOF

  local u
  for u in ha-gatekeeper.service ha-gatekeeper-watchdog.timer ha-gatekeeper-backup.timer; do
    systemctl is-enabled --quiet "$u" 2>/dev/null || jpush "Enabled and started $u" rv_unit_disable "$u"
  done
  systemctl daemon-reload
  systemctl enable ha-gatekeeper.service ha-gatekeeper-watchdog.timer ha-gatekeeper-backup.timer >>"$LOG_FILE" 2>&1
  systemctl restart ha-gatekeeper-watchdog.timer ha-gatekeeper-backup.timer >>"$LOG_FILE" 2>&1
  systemctl start ha-gatekeeper.service >>"$LOG_FILE" 2>&1 || true
  ok "systemd: boot service, watchdog timer (every minute) and daily backup timer enabled"
}

install_cron_fallback() {
  local dir
  dir="$(dirname "$CRON_FILE")"
  if [[ ! -d "$dir" ]]; then
    info "No systemd on this server: installing cron for the watchdog"
    jx_pkg_install cron >/dev/null 2>&1 || jx_pkg_install cronie >/dev/null 2>&1 || true
  fi
  if [[ ! -d "$dir" ]]; then
    warn "There is neither systemd nor cron, so the watchdog cannot be scheduled automatically."
    hint "Run it every minute yourself: $APP_DIR/deploy/watchdog.sh"
    return 1
  fi

  local tmp
  tmp="$(mktemp)"
  cat >"$tmp" <<EOF
# HA Gatekeeper: watchdog every minute, start at boot, daily backup. Managed by install.sh.
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
* * * * * root $APP_DIR/deploy/watchdog.sh >/dev/null 2>&1
@reboot root sleep 30 && cd $APP_DIR && $DOCKER_BIN compose up -d --remove-orphans >/dev/null 2>&1
30 3 * * * root $APP_DIR/install.sh backup --quiet >/dev/null 2>&1
EOF
  jx_install_file "$tmp" "$CRON_FILE" 644
  rm -f "$tmp"

  if have service; then
    service cron start >>"$LOG_FILE" 2>&1 || service crond start >>"$LOG_FILE" 2>&1 || true
  fi
  ok "cron: watchdog every minute, start at boot, daily backup ($CRON_FILE)"
}

# The folder for the watchdog's state (heartbeat, pause flag); created once per server.
ensure_state_dir() {
  jx_mkdir "$STATE_DIR" tree
  chmod 700 "$STATE_DIR"
}

install_automation() {
  chmod +x "$APP_DIR/install.sh" "$APP_DIR/deploy/watchdog.sh"
  ensure_state_dir
  [[ -e "$WATCHDOG_LOG" ]] || jpush "Created the watchdog log $WATCHDOG_LOG (filled in by the watchdog)" rv_rm "$WATCHDOG_LOG"

  if have_systemd; then
    if [[ -e "$CRON_FILE" ]]; then
      jpush "Removed the old cron file $CRON_FILE (systemd is used instead)" rv_restore "$CRON_FILE" "$(jbackup "$CRON_FILE")"
      rm -f "$CRON_FILE" 2>/dev/null || true
    fi
    install_systemd_units
  else
    install_cron_fallback || true
  fi

  if [[ -L "$BIN_LINK" && "$(readlink "$BIN_LINK")" == "$APP_DIR/install.sh" ]]; then
    ok "The 'gatekeeper' command is installed ($BIN_LINK)"
  else
    if [[ -e "$BIN_LINK" || -L "$BIN_LINK" ]]; then
      jpush "Replaced $BIN_LINK (the previous one is put back on rollback)" rv_restore "$BIN_LINK" "$(jbackup "$BIN_LINK")"
    else
      jpush "Created the 'gatekeeper' command $BIN_LINK (a link to $APP_DIR/install.sh)" rv_rm "$BIN_LINK"
    fi
    if ln -sf "$APP_DIR/install.sh" "$BIN_LINK" 2>/dev/null; then
      ok "Installed the 'gatekeeper' command ($BIN_LINK): try  gatekeeper status"
    else
      jdrop "$J_LAST"
      warn "Could not create $BIN_LINK; run $APP_DIR/install.sh directly."
    fi
  fi
}

# -------------------------------------------------------------------------------------------------
# Verification: is everything actually running well?
# -------------------------------------------------------------------------------------------------

V_PASS=0
V_WARN=0
V_FAIL=0
V_FAIL_DEFERRED=0      # failures that only mean "not ready yet" (a certificate still being issued)
JUST_INSTALLED=false

HTTP_COOKIE=""
HTTP_BEARER=""
LAST_CODE=""
LAST_BODY=""
LAST_HEADERS=""
LAST_ERR=""
COOKIE_ATTRS=""
FD_BASE=""
FD_ARGS=(--globoff)

vsection() { $QUIET || printf '\n%s%s%s\n' "$C_BOLD" "$1" "$C_RESET"; log_file "--- $1"; }
vpass() { V_PASS=$((V_PASS + 1)); $QUIET || printf '  %s[ OK ]%s %s\n' "$C_GREEN" "$C_RESET" "$1"; log_file "PASS  $1"; }
vwarn() {
  V_WARN=$((V_WARN + 1))
  printf '  %s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$1"
  [[ -z "${2:-}" ]] || printf '         %s-> %s%s\n' "$C_DIM" "$2" "$C_RESET"
  log_file "WARN  $1 | ${2:-}"
}
vfail_deferred() { V_FAIL_DEFERRED=$((V_FAIL_DEFERRED + 1)); vfail "$@"; }
vfail() {
  V_FAIL=$((V_FAIL + 1))
  printf '  %s[FAIL]%s %s\n' "$C_RED" "$C_RESET" "$1"
  [[ -z "${2:-}" ]] || printf '         %s-> %s%s\n' "$C_DIM" "$2" "$C_RESET"
  log_file "FAIL  $1 | ${2:-}"
}

local_url() {
  local bind="${CFG[GATEKEEPER_BIND]:-127.0.0.1}"
  case "$bind" in ""|0.0.0.0|"::") bind=127.0.0.1 ;; esac
  printf 'http://%s:%s' "$bind" "${CFG[GATEKEEPER_PORT]:-8080}"
}

# http_do METHOD URL [JSON_BODY] [extra curl args...]
# Sets LAST_CODE / LAST_BODY / LAST_HEADERS / LAST_ERR. Returns 0 if an HTTP response arrived.
# Credentials come from HTTP_COOKIE / HTTP_BEARER and reach curl through a private config file,
# so they never appear in the process list.
http_do() {
  local method="$1" url="$2" body="${3:-}" cfg hdrs out errf rc=0
  shift 3
  cfg="$(mktemp_tracked)"; hdrs="$(mktemp_tracked)"; out="$(mktemp_tracked)"; errf="$(mktemp_tracked)"
  chmod 600 "$cfg"
  {
    [[ -z "$HTTP_COOKIE" ]] || printf 'header = "Cookie: %s"\n' "$HTTP_COOKIE"
    [[ -z "$HTTP_BEARER" ]] || printf 'header = "Authorization: Bearer %s"\n' "$HTTP_BEARER"
  } >"$cfg"

  local args=(-sS --connect-timeout 8 --max-time 30 -X "$method" -D "$hdrs" -o "$out" -w '%{http_code}' -K "$cfg")
  if [[ -n "$body" ]]; then
    args+=(-H 'Content-Type: application/json' --data-binary @-)
  fi

  LAST_CODE="$(printf '%s' "$body" | curl "${args[@]}" "$@" "$url" 2>"$errf")" || rc=$?
  LAST_BODY="$(cat "$out")"
  LAST_HEADERS="$(tr -d '\r' <"$hdrs")"
  LAST_ERR="$(head -n 1 "$errf")"
  rm -f "$cfg" "$hdrs" "$out" "$errf"
  return "$rc"
}

# admin_login BASE [curl args...] -> sets HTTP_COOKIE. 0 ok | 1 no response | 2 rejected | 3 no cookie
admin_login() {
  local base="$1" payload
  shift
  payload="$(ADMIN_PW="${CFG[ADMIN_PASSWORD]}" jq -n '{password: env.ADMIN_PW}')"
  HTTP_COOKIE=""
  http_do POST "$base/admin/login" "$payload" "$@" || return 1
  [[ "$LAST_CODE" == 200 ]] || return 2
  COOKIE_ATTRS="$(awk -F': ' 'tolower($1) == "set-cookie" { print $2; exit }' <<<"$LAST_HEADERS")"
  HTTP_COOKIE="${COOKIE_ATTRS%%;*}"
  [[ -n "$HTTP_COOKIE" ]] || return 3
}

# The way a user's browser reaches the app: through Caddy when it is enabled, else directly.
front_door() {
  FD_ARGS=(--globoff)
  if proxy_enabled; then
    local host="${CFG[GATEKEEPER_DOMAIN]}"
    if is_ipv4 "$host"; then
      # --resolve does not apply to IP literals: connect to loopback, present the right Host, and
      # let default_sni choose the certificate.
      FD_BASE="https://127.0.0.1"
      FD_ARGS+=(-H "Host: $host")
    else
      FD_BASE="https://$host"
      FD_ARGS+=(--resolve "$host:443:127.0.0.1")
    fi
    [[ "${CFG[GATEKEEPER_MODE]}" == selfsigned ]] && FD_ARGS+=(-k)
  else
    FD_BASE="$(local_url)"
  fi
}

container_field() { docker inspect --type container -f "$2" "$1" 2>/dev/null || true; }

verify_host() {
  vsection "Server"
  local free mem swap
  free="$(disk_free_mb /)"
  if (( free < 512 )); then
    vfail "Disk almost full: ${free} MB free" "Free space (docker system prune -f, apt clean, remove old logs)."
  elif (( free < 2048 )); then
    vwarn "Disk space is low: ${free} MB free" "The watchdog prunes unused images below 1 GB, but consider a bigger disk."
  else
    vpass "Disk space: ${free} MB free"
  fi

  mem="$(mem_mb)"; swap="$(swap_mb)"
  if (( mem + swap < 1024 )); then
    vwarn "Little memory: ${mem} MB RAM, ${swap} MB swap" "Add swap so a memory spike cannot kill the app."
  else
    vpass "Memory: ${mem} MB RAM, ${swap} MB swap"
  fi

  if have timedatectl && have_systemd; then
    if [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" == yes ]]; then
      vpass "Clock is synchronised (needed for TLS certificates)"
    else
      vwarn "Clock is not synchronised" "Wrong time breaks HTTPS. Enable NTP: timedatectl set-ntp true"
    fi
  fi

  if [[ -f "$APP_DIR/.env" ]]; then
    if [[ "$(stat -c '%a %u' "$APP_DIR/.env")" == "600 0" ]]; then
      vpass ".env is private (mode 600, owned by root)"
    else
      vwarn ".env permissions are $(stat -c '%a' "$APP_DIR/.env") (owner uid $(stat -c '%u' "$APP_DIR/.env"))" "It holds secrets: chmod 600 $APP_DIR/.env && chown root:root $APP_DIR/.env"
    fi
  else
    vfail "No $APP_DIR/.env" "Run: sudo $APP_DIR/install.sh"
  fi
}

verify_docker() {
  vsection "Docker"
  if docker_up; then
    vpass "Docker daemon is responding ($(docker version --format '{{.Server.Version}}' 2>/dev/null))"
  else
    vfail "Docker daemon is not responding" "systemctl status docker; journalctl -u docker -n 50"
    return 1
  fi
  if compose_ok && compose_version_ok; then
    vpass "Docker Compose $(docker compose version --short 2>/dev/null)"
  else
    vfail "Docker Compose v2 is missing" "Re-run the installer to install it."
  fi
  if have_systemd; then
    if systemctl is-enabled docker >/dev/null 2>&1; then
      vpass "Docker starts automatically at boot"
    else
      vfail "Docker is not enabled at boot" "systemctl enable docker"
    fi
  fi
}

verify_one_container() { # verify_one_container NAME LABEL
  local name="$1" label="$2" state health policy restarts started img
  if ! docker inspect --type container "$name" >/dev/null 2>&1; then
    vfail "$label container does not exist" "Run: sudo $APP_DIR/install.sh"
    return 1
  fi
  state="$(container_field "$name" '{{.State.Status}}')"
  health="$(container_field "$name" '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}')"
  policy="$(container_field "$name" '{{.HostConfig.RestartPolicy.Name}}')"
  restarts="$(container_field "$name" '{{.RestartCount}}')"
  started="$(container_field "$name" '{{.State.StartedAt}}')"

  if [[ "$state" == running && ( "$health" == healthy || "$health" == none ) ]]; then
    vpass "$label is running and healthy (up since ${started%%.*})"
  elif [[ "$state" == running && "$health" == starting ]]; then
    vwarn "$label is still starting" "Give it a minute and run verify again."
  else
    vfail "$label is $state (health: $health)" "gatekeeper logs"
    return 1
  fi

  if [[ "$policy" == unless-stopped || "$policy" == always ]]; then
    vpass "$label restart policy: $policy (restarts after crashes and reboots)"
  else
    vfail "$label restart policy is '$policy'" "Expected unless-stopped. Re-run the installer to re-apply the compose file."
  fi

  if [[ "$restarts" =~ ^[0-9]+$ ]] && (( restarts >= 5 )); then
    vwarn "$label has restarted $restarts times since it was created" "It may be crash-looping: gatekeeper logs"
  fi
  img="$(container_field "$name" '{{.Config.Image}}')"
  log_file "$label image: $img"
}

verify_containers() {
  vsection "Containers"
  verify_one_container "$GK_CONTAINER" "Gatekeeper" || return 0

  local bound
  bound="$(docker port "$GK_CONTAINER" 8080/tcp 2>/dev/null | head -n 1)" || true
  if [[ "$bound" == 0.0.0.0:* || "$bound" == "[::]:"* ]]; then
    if proxy_enabled; then
      vfail "The plain-HTTP app port is open to the internet ($bound)" "It bypasses HTTPS. Remove GATEKEEPER_BIND from .env (it must be 127.0.0.1) and re-run the installer."
    else
      vwarn "The app port is reachable from other machines ($bound), over plain HTTP" "Admin login needs HTTPS (secure cookie). Prefer 127.0.0.1 plus an SSH tunnel or the HTTPS proxy."
    fi
  else
    vpass "App port is bound to loopback only (${bound:-none})"
  fi

  if proxy_enabled; then
    verify_one_container "$CADDY_CONTAINER" "HTTPS proxy (Caddy)" || true
  fi
}

verify_ha_from_container() {
  local out status errf
  errf="$(mktemp_tracked)"
  out="$(docker exec "$GK_CONTAINER" node -e '
    const base = (process.env.HA_BASE_URL || "").replace(/\/$/, "");
    const token = process.env.HA_TOKEN || require("fs").readFileSync(process.env.HA_TOKEN_FILE, "utf8").trim();
    fetch(base + "/api/config", { headers: { Authorization: "Bearer " + token }, signal: AbortSignal.timeout(15000) })
      .then(async (r) => {
        const j = r.ok ? await r.json().catch(() => ({})) : {};
        console.log(JSON.stringify({ status: r.status, version: j.version, name: j.location_name }));
        process.exit(r.ok ? 0 : 1);
      })
      .catch((e) => {
        console.log(JSON.stringify({ error: (e.cause && (e.cause.code || e.cause.message)) || e.message }));
        process.exit(2);
      });' 2>"$errf")" || true
  out="$(tail -n 1 <<<"$out")" # Node may print warnings; the JSON result is the last stdout line
  status="$(jq -r '.status // empty' <<<"$out" 2>/dev/null || true)"

  if [[ "$status" == 200 ]]; then
    vpass "Home Assistant $(jq -r '.version // "?"' <<<"$out") (\"$(jq -r '.name // "?"' <<<"$out")\") reachable from inside the container"
  elif [[ "$status" == 401 || "$status" == 403 ]]; then
    vfail "Home Assistant rejected the token (HTTP $status)" "Create a new long-lived token in Home Assistant and re-run: sudo $APP_DIR/install.sh --reconfigure"
  elif [[ -n "$status" ]]; then
    vfail "Home Assistant answered HTTP $status to /api/config" "Check HA_BASE_URL in .env."
  else
    local why
    why="$(jq -r '.error // empty' <<<"$out" 2>/dev/null || true)"
    [[ -n "$why" ]] || why="$(head -n 1 "$errf" 2>/dev/null || true)"
    case "$why" in
      ENOTFOUND|EAI_AGAIN) vfail "Container cannot resolve the Home Assistant host ($why)" "Use a name that resolves from the internet, or an IP over a VPN." ;;
      ECONNREFUSED)        vfail "Home Assistant refused the connection from the container" "Wrong port, or HA only listens on localhost. If HA runs on this server it must listen on 0.0.0.0 and the host firewall must allow the Docker network (172.16.0.0/12) to that port$(have ufw && echo ', e.g. ufw allow from 172.16.0.0/12 to any port 8123')." ;;
      ETIMEDOUT|UND_ERR_CONNECT_TIMEOUT|TimeoutError)
        if ha_local_port >/dev/null 2>&1; then
          local fwhint
          if have ufw; then
            fwhint="ufw allow from 172.16.0.0/12 to any port $(ha_local_port) proto tcp (re-running the installer adds this for you)."
          else
            fwhint="allow the Docker networks (172.16.0.0/12) to reach TCP port $(ha_local_port) in your host firewall."
          fi
          vfail "Timed out reaching Home Assistant on this server from the container" "A host firewall is probably blocking the Docker network: $fwhint"
        else
          vfail "Timed out reaching Home Assistant from the container" "Home LAN addresses are unreachable from a VPS without a VPN (Tailscale/WireGuard); for a public address check the port is open to this server."
        fi ;;
      *CERT*|*SELF_SIGNED*|*certificate*) vfail "TLS certificate problem talking to Home Assistant ($why)" "Provide the CA file for a private certificate: sudo $APP_DIR/install.sh --reconfigure (advanced options)." ;;
      *) vfail "Container could not reach Home Assistant (${why:-no details})" "gatekeeper logs" ;;
    esac
  fi
}

verify_secrets() {
  vsection "Secrets"
  local env_json key leaked=() dir="$APP_DIR/secrets"
  env_json="$(docker inspect --type container -f '{{json .Config.Env}}' "$GK_CONTAINER" 2>/dev/null || true)"
  if [[ -n "$env_json" ]]; then
    for key in HA_TOKEN ADMIN_PASSWORD ADMIN_SESSION_SECRET API_KEY_HASH_SECRET; do
      if grep -qF "\"$key=" <<<"$env_json"; then leaked+=("$key"); fi
    done
    if (( ${#leaked[@]} > 0 )); then
      vfail "These secrets are visible in the container's environment (docker inspect): ${leaked[*]}" "Re-run the installer to recreate the container: sudo $APP_DIR/install.sh"
    else
      vpass "No secret is in the container's environment (docker inspect and /proc/1/environ show none)"
    fi
  fi
  if [[ -d "$dir" ]]; then
    if [[ "$(stat -c '%a %u' "$dir")" == "700 0" ]]; then
      vpass "The secrets folder is private (mode 700, owned by root)"
    else
      vwarn "The secrets folder permissions are $(stat -c '%a' "$dir") (owner uid $(stat -c '%u' "$dir"))" "chmod 700 $dir && chown root:root $dir"
    fi
  else
    vfail "No $dir folder" "Run: sudo $APP_DIR/install.sh"
  fi
}

# Private mode behind your own web server: check that the public address really reaches the app.
verify_behind_proxy() {
  [[ "${CFG[GATEKEEPER_MODE]}" == local && "${CFG[GATEKEEPER_PUBLIC_URL]:-}" == https://* ]] || return 0
  vsection "Your web server"
  local url="${CFG[GATEKEEPER_PUBLIC_URL]}"
  HTTP_COOKIE=""; HTTP_BEARER=""
  if http_do GET "$url/healthz" "" --max-time 15 && [[ "$LAST_CODE" == 200 && "$LAST_BODY" == *'"ok":true'* ]]; then
    vpass "$url reaches Gatekeeper through your web server"
  else
    vwarn "$url does not reach Gatekeeper yet (${LAST_ERR:-HTTP ${LAST_CODE:-none}})" "Forward it to http://127.0.0.1:${CFG[GATEKEEPER_PORT]} (the summary shows an nginx example), reload your web server, then run: gatekeeper verify"
  fi
}

# The server keeps one websocket to Home Assistant for all API keys (see docs/HOME_ASSISTANT_CONNECTION.md).
verify_live_connection() {
  http_do GET "$FD_BASE/admin/connection" "" "${FD_ARGS[@]}" || true
  if [[ "$LAST_CODE" != 200 ]]; then
    vwarn "Could not read the Home Assistant connection status (HTTP ${LAST_CODE:-none})" "gatekeeper logs"
    return 0
  fi
  local source running connected watched i
  source="$(jq -r '.settings.stateSource // empty' <<<"$LAST_BODY" 2>/dev/null || true)"
  if [[ "$source" != subscription ]]; then
    vpass "Live subscription is switched off in Settings (reads ask Home Assistant, shared briefly)"
    return 0
  fi
  # A freshly started server needs a moment to open the websocket.
  for i in 1 2 3 4 5 6; do
    running="$(jq -r '.live.running' <<<"$LAST_BODY" 2>/dev/null || echo false)"
    connected="$(jq -r '.live.connected' <<<"$LAST_BODY" 2>/dev/null || echo false)"
    watched="$(jq -r '.live.subscribed' <<<"$LAST_BODY" 2>/dev/null || echo 0)"
    if [[ "$connected" == true ]] || { [[ "$running" == true ]] && [[ "$watched" == 0 ]]; }; then break; fi
    sleep 2
    http_do GET "$FD_BASE/admin/connection" "" "${FD_ARGS[@]}" || true
  done
  if [[ "$connected" == true ]]; then
    vpass "One live websocket to Home Assistant is up ($watched entities watched; API reads never reach Home Assistant)"
  elif [[ "$running" == true && "$watched" == 0 ]]; then
    vpass "Live subscription is ready: no API key can read an entity yet, so nothing is watched (and no traffic is sent)"
  else
    vwarn "The live websocket to Home Assistant is not up ($(jq -r '.live.lastError // "still connecting"' <<<"$LAST_BODY" 2>/dev/null))" "Reads fall back to asking Home Assistant, so nothing breaks. gatekeeper logs"
  fi
}

verify_app() {
  vsection "Application"
  local base code t
  base="$(local_url)"

  if ! http_do GET "$base/healthz" ""; then
    vfail "The app does not answer on $base/healthz" "gatekeeper logs"
    return 0
  fi
  if [[ "$LAST_CODE" == 200 && "$LAST_BODY" == *'"ok":true'* ]]; then
    vpass "Health endpoint answers ($base/healthz)"
  else
    vfail "Health endpoint returned HTTP $LAST_CODE" "gatekeeper logs"
    return 0
  fi

  HTTP_COOKIE=""; HTTP_BEARER=""
  http_do GET "$base/api/states/sun.sun" "" || true
  if [[ "$LAST_CODE" == 401 ]]; then vpass "Public API rejects requests without a token (401)"; else vfail "Public API answered HTTP $LAST_CODE without a token (expected 401)"; fi
  http_do GET "$base/admin/clients" "" || true
  if [[ "$LAST_CODE" == 401 ]]; then vpass "Admin API rejects requests without a session (401)"; else vfail "Admin API answered HTTP $LAST_CODE without a session (expected 401)"; fi

  # Log in the way a browser would: through the HTTPS front door when there is one.
  front_door
  local fd_note="" rc=0
  admin_login "$FD_BASE" "${FD_ARGS[@]}" || rc=$?
  if (( rc == 2 )) && [[ "$LAST_CODE" == 403 ]] && proxy_enabled && [[ -n "${CFG[ADMIN_ALLOWED_IPS]:-}" ]]; then
    vwarn "Admin API through HTTPS is blocked for this server itself (ADMIN_ALLOWED_IPS is set)" "Expected: only your allow-listed addresses can use it. Testing over loopback instead."
    FD_BASE="$base"; FD_ARGS=(--globoff); fd_note=" (over loopback)"
    rc=0
    admin_login "$FD_BASE" || rc=$?
  fi

  case "$rc" in
    0) vpass "Admin login works with the configured password${fd_note:- via $FD_BASE}" ;;
    1) vfail "No response from $FD_BASE/admin/login" "${LAST_ERR:-check Caddy and the app logs}"; return 0 ;;
    2) vfail "Admin login was rejected (HTTP $LAST_CODE)" "The password in .env does not match what the running container has. Re-run: sudo $APP_DIR/install.sh"; return 0 ;;
    *) vfail "Admin login succeeded but no session cookie was set"; return 0 ;;
  esac

  if [[ "$COOKIE_ATTRS" == *HttpOnly* && "$COOKIE_ATTRS" == *Secure* && "$COOKIE_ATTRS" == *SameSite* ]]; then
    vpass "Session cookie is HttpOnly, Secure and SameSite"
  else
    vwarn "Session cookie is missing a protection flag" "Got: ${COOKIE_ATTRS#*;}"
  fi

  http_do GET "$FD_BASE/admin/me" "" "${FD_ARGS[@]}" || true
  if [[ "$LAST_BODY" == *'"authenticated":true'* ]]; then
    vpass "Session is accepted on the next request (cookie round-trip works)"
  else
    vfail "The session cookie was not accepted on the next request" "Behind HTTPS this usually means the proxy is not forwarding correctly. gatekeeper logs; docker logs $CADDY_CONTAINER"
  fi

  local saved_cookie="$HTTP_COOKIE" bad_payload
  bad_payload="$(ADMIN_PW="wrong-password-$$" jq -n '{password: env.ADMIN_PW}')"
  HTTP_COOKIE=""
  http_do POST "$FD_BASE/admin/login" "$bad_payload" "${FD_ARGS[@]}" || true
  if [[ "$LAST_CODE" == 401 ]]; then vpass "A wrong password is rejected (401)"; else vfail "A wrong password got HTTP $LAST_CODE (expected 401)"; fi
  HTTP_COOKIE="$saved_cookie"

  verify_ha_from_container
  verify_live_connection

  http_do GET "$FD_BASE/admin/ha/entities" "" "${FD_ARGS[@]}" || true
  local count entity other
  if [[ "$LAST_CODE" == 200 ]]; then
    count="$(jq -r '.entities | length' <<<"$LAST_BODY" 2>/dev/null || echo 0)"
    vpass "The app reads $count entities from Home Assistant"
    entity="$(jq -r '[.entities[].entityId] | (if index("sun.sun") then "sun.sun" else .[0] end) // empty' <<<"$LAST_BODY" 2>/dev/null || true)"
    other="$(jq -r --arg e "$entity" '[.entities[].entityId | select(. != $e)] | .[0] // empty' <<<"$LAST_BODY" 2>/dev/null || true)"
  else
    vfail "The app could not list Home Assistant entities (HTTP $LAST_CODE)" "See the Home Assistant check above."
    return 0
  fi

  if $QUICK; then
    return 0
  fi
  verify_token_flow "$entity" "$other"
}

# Creates a temporary read-only token, uses it through the public API, deletes it. Always cleans up.
verify_token_flow() { # verify_token_flow ALLOWED_ENTITY [OTHER_ENTITY]
  local entity="$1" other="${2:-}" payload id="" key
  if [[ -z "$entity" ]]; then
    vwarn "Skipped the token test: Home Assistant has no entities to read"
    return 0
  fi

  payload="$(jq -n --arg e "$entity" '{name: "gatekeeper-installer-selftest", permissions: [{kind: "state", entityIds: [$e]}]}')"
  http_do POST "$FD_BASE/admin/clients" "$payload" "${FD_ARGS[@]}" || true
  if [[ "$LAST_CODE" != 200 ]]; then
    vfail "Could not create a temporary test token (HTTP $LAST_CODE)" "The database may not be writable: gatekeeper logs"
    return 0
  fi
  id="$(jq -r '.client.id // empty' <<<"$LAST_BODY" 2>/dev/null || true)"
  key="$(jq -r '.apiKey // empty' <<<"$LAST_BODY" 2>/dev/null || true)"
  vpass "Created a temporary scoped token (database write works)"

  local saved_cookie="$HTTP_COOKIE"
  HTTP_COOKIE=""; HTTP_BEARER="$key"
  http_do GET "$FD_BASE/api/states/$entity" "" "${FD_ARGS[@]}" || true
  if [[ "$LAST_CODE" == 200 ]]; then
    vpass "Public API with that token reads '$entity' from Home Assistant end to end"
  else
    vfail "Public API with a valid token returned HTTP $LAST_CODE for '$entity'" "gatekeeper logs"
  fi

  if [[ -n "$other" ]]; then
    http_do GET "$FD_BASE/api/states/$other" "" "${FD_ARGS[@]}" || true
    if [[ "$LAST_CODE" == 403 ]]; then
      vpass "Permissions are enforced: '$other' is refused for that token (403)"
    else
      vfail "A token scoped to '$entity' got HTTP $LAST_CODE for '$other' (expected 403)" "Permission enforcement is not working; do not expose this instance."
    fi
  fi
  HTTP_BEARER=""; HTTP_COOKIE="$saved_cookie"

  if [[ -n "$id" ]]; then
    http_do DELETE "$FD_BASE/admin/clients/$id" "" "${FD_ARGS[@]}" || true
    if [[ "$LAST_CODE" == 200 ]]; then
      HTTP_COOKIE=""; HTTP_BEARER="$key"
      http_do GET "$FD_BASE/api/states/$entity" "" "${FD_ARGS[@]}" || true
      HTTP_BEARER=""; HTTP_COOKIE="$saved_cookie"
      if [[ "$LAST_CODE" == 401 ]]; then
        vpass "Deleted the temporary token; it no longer works (401)"
      else
        vfail "The deleted token still works (HTTP $LAST_CODE)"
      fi
    else
      vwarn "Could not delete the temporary test token '$id' (HTTP $LAST_CODE)" "Delete 'gatekeeper-installer-selftest' in the admin dashboard."
    fi
  fi
}

caddy_tls_hint() {
  local logs
  logs="$(docker logs --tail 300 "$CADDY_CONTAINER" 2>&1 || true)"
  if grep -qiE 'NXDOMAIN|no valid A records|DNS problem|no such host' <<<"$logs"; then
    hint "Let's Encrypt could not find DNS for ${CFG[GATEKEEPER_DOMAIN]}: the A record must point to this server's public IP."
  elif grep -qiE 'Timeout during connect|Connection refused|could not connect|firewall' <<<"$logs"; then
    hint "Let's Encrypt could not reach this server: open inbound TCP 80 and 443 (host firewall and your provider's control panel)."
  elif grep -qiE 'rateLimited|too many (certificates|failed)|rate limit' <<<"$logs"; then
    hint "Let's Encrypt is rate-limiting this domain. Wait an hour (failed attempts) or a week (certificates) and it will retry by itself."
  elif grep -qiE 'unauthorized|Invalid response|wrong' <<<"$logs"; then
    hint "Something other than Caddy answered on port 80 (another web server?). This installer never stops other services: use private mode (3) behind that server instead."
  else
    hint "Last proxy log lines:"
    tail -n 6 <<<"$logs" | sed 's/^/       | /'
  fi
}

verify_public() {
  vsection "HTTPS front door"
  local host="${CFG[GATEKEEPER_DOMAIN]}" mode="${CFG[GATEKEEPER_MODE]}" i ok=false extra=()
  front_door
  extra=("${FD_ARGS[@]}")

  local tries=1
  [[ "$mode" == domain ]] && tries=24 # Caddy may still be obtaining the certificate
  for ((i = 1; i <= tries; i++)); do
    if http_do GET "$FD_BASE/healthz" "" "${extra[@]}" && [[ "$LAST_CODE" == 200 && "$LAST_BODY" == *'"ok":true'* ]]; then ok=true; break; fi
    if (( i == 1 && tries > 1 )); then info "Waiting for the HTTPS certificate (usually under a minute)..."; fi
    (( i < tries )) && sleep 5
  done

  if $ok && [[ "$mode" == domain ]]; then
    vpass "https://$host answers with a valid, trusted certificate"
  elif $ok; then
    vpass "https://$host answers (self-signed certificate: browsers warn once)"
  else
    if [[ "$mode" == domain ]]; then
      vfail_deferred "HTTPS does not work yet for $host (${LAST_ERR:-HTTP $LAST_CODE})" "The app itself is fine; the proxy has no certificate yet. It keeps retrying by itself."
    else
      vfail "HTTPS does not work for $host (${LAST_ERR:-HTTP $LAST_CODE})" "The app itself is fine; the proxy is not answering."
    fi
    caddy_tls_hint
    return 0
  fi

  local cert end days issuer
  cert="$(printf '' | openssl s_client -connect 127.0.0.1:443 -servername "$host" 2>/dev/null | openssl x509 -noout -enddate -issuer 2>/dev/null || true)"
  end="$(sed -n 's/^notAfter=//p' <<<"$cert")"
  issuer="$(sed -n 's/^issuer=//p' <<<"$cert")"
  if [[ -n "$end" && "$mode" == domain ]]; then
    days=$(( ( $(date -d "$end" +%s 2>/dev/null || echo 0) - $(date +%s) ) / 86400 ))
    if (( days < 14 )); then
      vwarn "The certificate expires in $days days ($end)" "Caddy renews automatically; if it stays this low, check: docker logs $CADDY_CONTAINER"
    else
      vpass "Certificate valid for $days more days (${issuer:-unknown issuer})"
    fi
  fi

  local scheme_host="$host"
  http_do GET "http://127.0.0.1/healthz" "" -H "Host: $scheme_host" || true
  if [[ "$LAST_CODE" =~ ^30[1278]$ && "$LAST_HEADERS" == *[Ll]ocation:*https://* ]]; then
    vpass "Plain HTTP on port 80 redirects to HTTPS"
  else
    vwarn "Port 80 did not redirect to HTTPS (HTTP ${LAST_CODE:-none})" "Harmless for the app, but browsers typing http:// will not upgrade."
  fi

  if [[ "$mode" == domain ]]; then
    http_do GET "https://$host/healthz" "" --max-time 15 || true
    if [[ "$LAST_CODE" == 200 ]]; then
      vpass "Reachable through public DNS from this server as well"
    else
      vwarn "Works locally but not through public DNS (${LAST_ERR:-HTTP $LAST_CODE})" "Usually DNS that has not propagated yet, or the A record points elsewhere. Try again in a few minutes."
    fi
  fi

  if [[ -n "${CFG[ADMIN_ALLOWED_IPS]:-}" ]]; then
    vpass "Admin API is restricted to: ${CFG[ADMIN_ALLOWED_IPS]}"
  fi
}

verify_automation() {
  vsection "Auto-restart and watchdog"
  local hb age waited=0

  if have_systemd; then
    if systemctl is-enabled ha-gatekeeper.service >/dev/null 2>&1; then
      vpass "Boot service ha-gatekeeper.service is enabled (brings the stack up after a reboot)"
    else
      vfail "Boot service is not enabled" "Re-run: sudo $APP_DIR/install.sh"
    fi
    if systemctl is-active ha-gatekeeper-watchdog.timer >/dev/null 2>&1; then
      vpass "Watchdog timer is active (checks every minute)"
    else
      vfail "Watchdog timer is not running" "systemctl enable --now ha-gatekeeper-watchdog.timer"
    fi
    if systemctl is-active ha-gatekeeper-backup.timer >/dev/null 2>&1; then
      vpass "Daily backup timer is active"
    else
      vwarn "Daily backup timer is not running" "systemctl enable --now ha-gatekeeper-backup.timer"
    fi
  elif [[ -f "$CRON_FILE" ]]; then
    vpass "Watchdog, boot start and backup are scheduled through cron ($CRON_FILE)"
    pgrep -x cron >/dev/null 2>&1 || pgrep -x crond >/dev/null 2>&1 || vwarn "The cron daemon does not appear to be running" "service cron start"
  else
    vfail "Nothing schedules the watchdog (no systemd timer, no cron file)" "Re-run: sudo $APP_DIR/install.sh"
  fi

  hb="$(cat "$STATE_DIR/heartbeat" 2>/dev/null || echo 0)"
  while $JUST_INSTALLED && [[ ! "$hb" =~ ^[0-9]+$ || $(( $(date +%s) - hb )) -gt 120 ]] && (( waited < 90 )); do
    (( waited == 0 )) && info "Waiting for the watchdog's first run (it runs at the top of each minute)..."
    sleep 5; waited=$((waited + 5))
    hb="$(cat "$STATE_DIR/heartbeat" 2>/dev/null || echo 0)"
  done
  if [[ "$hb" =~ ^[0-9]+$ ]] && (( hb > 0 )); then
    age=$(( $(date +%s) - hb ))
    if (( age <= 150 )); then
      vpass "Watchdog ran ${age}s ago"
    else
      vfail "Watchdog last ran $((age / 60)) minutes ago" "Is the timer/cron running? journalctl -u ha-gatekeeper-watchdog -n 20"
    fi
  else
    vfail "The watchdog has never run" "journalctl -u ha-gatekeeper-watchdog -n 20 (or check $CRON_FILE)"
  fi

  if [[ -f "$STATE_DIR/paused" ]]; then
    vwarn "The watchdog is paused ($(cat "$STATE_DIR/paused"))" "Resume it with: gatekeeper start"
  fi
}

# Path of the most recent backup archive (nothing if there is none).
newest_backup() {
  find "$APP_DIR/backups" -maxdepth 1 -name 'ha-gatekeeper-*.tar.gz' -printf '%T@ %p\n' 2>/dev/null \
    | sort -nr | head -n 1 | cut -d' ' -f2- || true
}

verify_data() {
  vsection "Data"
  local data db owner newest age
  data="$(data_dir_abs)"
  db="$data/ha-gatekeeper.db"
  if [[ -s "$db" ]]; then
    owner="$(stat -c %u "$db")"
    if [[ "$owner" == "$SERVICE_UID" ]]; then
      vpass "Database exists ($(du -h "$db" | cut -f1), owned by the app user)"
    else
      vwarn "Database is owned by uid $owner, not $SERVICE_UID" "chown -R $SERVICE_UID:$SERVICE_UID $data"
    fi
  else
    vfail "Database file $db is missing or empty" "gatekeeper logs"
  fi

  if docker inspect --type container "$GK_CONTAINER" >/dev/null 2>&1; then
    local mig
    mig="$(docker exec "$GK_CONTAINER" npx --no-install prisma migrate status 2>&1 || true)"
    if grep -qi 'up to date' <<<"$mig"; then
      vpass "Database migrations are all applied"
    elif grep -qi 'have not yet been applied\|not yet been applied\|failed' <<<"$mig"; then
      vfail "Pending or failed database migrations" "gatekeeper logs"
    else
      vwarn "Could not read the migration status" "$(tail -n 1 <<<"$mig")"
    fi
  fi

  newest="$(newest_backup)"
  if [[ -n "$newest" ]]; then
    age=$(( ( $(date +%s) - $(stat -c %Y "$newest") ) / 3600 ))
    if (( age <= 36 )); then
      vpass "Latest backup is ${age}h old ($(basename "$newest"))"
    else
      vwarn "Latest backup is ${age}h old" "The daily timer should refresh it; run: gatekeeper backup"
    fi
  else
    vwarn "No backup yet" "The first one runs tonight; make one now with: gatekeeper backup"
  fi
}

# Crash-recovery drill: proves Docker's restart policy and the watchdog really work here.
run_drill() {
  vsection "Crash-recovery drill"
  local pid before after t0 ok=false tmp
  if ! docker inspect --type container "$GK_CONTAINER" >/dev/null 2>&1; then
    vfail "Skipped: the Gatekeeper container does not exist"
    return 0
  fi

  pause_watchdog 600
  WATCHDOG_PAUSED_BY_US=true

  # 1) A real crash: SIGKILL from outside Docker, exactly what an out-of-memory kill looks like.
  #    (`docker kill` is not a crash: Docker treats it as a manual stop and will not restart.)
  before="$(container_field "$GK_CONTAINER" '{{.State.StartedAt}}')"
  pid="$(container_field "$GK_CONTAINER" '{{.State.Pid}}')"
  if [[ "$pid" =~ ^[0-9]+$ ]] && (( pid > 1 )); then
    info "Simulating a crash (SIGKILL to the app's main process)..."
    kill -9 "$pid" 2>/dev/null || true
    t0=$SECONDS
    for _ in $(seq 1 45); do
      after="$(container_field "$GK_CONTAINER" '{{.State.StartedAt}}')"
      if [[ "$after" != "$before" ]] && http_do GET "$(local_url)/healthz" "" && [[ "$LAST_CODE" == 200 ]]; then ok=true; break; fi
      sleep 2
    done
    if $ok; then
      vpass "Docker restarted the crashed container by itself in $((SECONDS - t0))s"
    else
      vfail "The container did not come back after a simulated crash" "Check the restart policy: docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' $GK_CONTAINER"
    fi
  else
    vwarn "Skipped the crash test: could not determine the container's process id"
  fi
  wait_for_container "$GK_CONTAINER" 90 >/dev/null 2>&1 || true

  # 2) Someone stops it (Docker will NOT restart that): only the watchdog can help. Run the real
  #    watchdog once with a short fuse and an isolated state directory.
  info "Stopping the container the way an operator would (Docker will not restart it)..."
  docker stop "$GK_CONTAINER" >/dev/null 2>&1 || true
  tmp="$(mktemp -d)"
  TMP_FILES+=("$tmp")
  GK_STATE_DIR="$tmp" GK_WATCHDOG_LOG="$tmp/watchdog.log" GK_FAIL_THRESHOLD=1 GK_GRACE_SECONDS=0 \
    "$APP_DIR/deploy/watchdog.sh" >/dev/null 2>&1 || true
  ok=false
  t0=$SECONDS
  for _ in $(seq 1 45); do
    if http_do GET "$(local_url)/healthz" "" && [[ "$LAST_CODE" == 200 ]]; then ok=true; break; fi
    sleep 2
  done
  if $ok; then
    vpass "The watchdog brought the stopped container back in $((SECONDS - t0))s"
  else
    vfail "The watchdog could not bring the stopped container back" "Run it by hand: $APP_DIR/deploy/watchdog.sh ; then: cat $tmp/watchdog.log"
    dc up -d --no-build >>"$LOG_FILE" 2>&1 || true
  fi
  wait_for_container "$GK_CONTAINER" 90 >/dev/null 2>&1 || true

  resume_watchdog
  WATCHDOG_PAUSED_BY_US=false
}

verify_summary() {
  local total=$((V_PASS + V_WARN + V_FAIL))
  printf '\n'
  if (( V_FAIL == 0 && V_WARN == 0 )); then
    printf '%s%sEverything is running well.%s  %s checks passed.\n' "$C_BOLD" "$C_GREEN" "$C_RESET" "$V_PASS"
  elif (( V_FAIL == 0 )); then
    printf '%s%sRunning, with %s warning(s) worth a look.%s  %s of %s checks passed.\n' "$C_BOLD" "$C_YELLOW" "$V_WARN" "$C_RESET" "$V_PASS" "$total"
  else
    printf '%s%s%s problem(s) found.%s  %s passed, %s warning(s), %s failed. See the [FAIL] lines above.\n' "$C_BOLD" "$C_RED" "$V_FAIL" "$C_RESET" "$V_PASS" "$V_WARN" "$V_FAIL"
    printf '%sHandy: gatekeeper logs | gatekeeper status | %s%s\n' "$C_DIM" "$LOG_FILE" "$C_RESET"
  fi
  log_file "verify: $V_PASS passed, $V_WARN warnings, $V_FAIL failed"
  return 0
}

verify_all() { # verify_all [with-drill]
  V_PASS=0; V_WARN=0; V_FAIL=0
  local drill="${1:-}"
  V_FAIL_DEFERRED=0
  verify_host
  verify_docker || { verify_summary; return 1; }
  verify_containers
  verify_secrets
  verify_app
  if proxy_enabled; then verify_public; else verify_behind_proxy; fi
  verify_automation
  verify_data
  if [[ "$drill" == with-drill ]]; then run_drill; fi
  if [[ "${GK_FAIL_AT:-}" == verify ]]; then vfail "Forced failure (GK_FAIL_AT=verify, a test hook)"; fi
  verify_summary
  (( V_FAIL == 0 )) || return 1
  return 0
}

# -------------------------------------------------------------------------------------------------
# Guided configuration
# -------------------------------------------------------------------------------------------------

PUBLIC_IPV4=""
FRESH_INSTALL=true

container_publishes_host_port() { # container_publishes_host_port NAME PORT
  docker_up || return 1
  docker inspect --type container --format '{{json .NetworkSettings.Ports}}' "$1" 2>/dev/null \
    | grep -q "\"HostPort\":\"$2\""
}

pick_app_port() {
  local p="${CFG[GATEKEEPER_PORT]:-8080}" tries=0 owner
  while port_in_use "$p" && ! container_publishes_host_port "$GK_CONTAINER" "$p"; do
    owner="$(port_owner "$p" || true)"
    if [[ -n "${GATEKEEPER_PORT_REQUESTED:-}" ]]; then
      die "The port you asked for (GATEKEEPER_PORT=$p) is already in use${owner:+ by $owner}. Pick another port, or free it yourself. Nothing was changed."
    fi
    warn "Local port $p is already in use${owner:+ by $owner}; trying the next one."
    p=$((p + 1))
    tries=$((tries + 1))
    (( tries < 50 )) || die "Could not find a free local port near ${CFG[GATEKEEPER_PORT]}."
  done
  CFG[GATEKEEPER_PORT]="$p"
}

# Ports 80/443 that something else already uses (our own proxy container does not count).
web_ports_taken() { # prints "80 (nginx (pid 12))" style lines
  local p owner
  for p in 80 443; do
    if port_in_use "$p" && ! stack_publishes_port "$p"; then
      owner="$(port_owner "$p" || true)"
      printf '%s%s\n' "$p" "${owner:+ ($owner)}"
    fi
  done
  return 0
}

# HTTPS modes (1 and 2) need ports 80 and 443 for themselves. If another server (nginx, Apache...)
# owns them, refuse: this installer never stops, reconfigures or works around another service.
check_web_ports() {
  proxy_enabled || return 0
  local taken
  taken="$(web_ports_taken)"
  if [[ -n "$taken" ]]; then
    err "Port(s) already in use by another program: $(tr '\n' ' ' <<<"$taken")"
    say "  HTTPS options 1 and 2 need ports 80 and 443 for themselves, and this installer never stops or changes"
    say "  another web server. Nothing was changed. Your choices:"
    say "    - Choose option 3 (private) and let your existing web server forward HTTPS to Gatekeeper at"
    say "      http://127.0.0.1:${CFG[GATEKEEPER_PORT]:-8080}  (the summary shows a ready-made nginx snippet), or"
    say "    - free ports 80 and 443 yourself, then run this installer again."
    return 1
  fi
  ok "Ports 80 and 443 are free for the HTTPS proxy"
}

install_ha_ca() { # install_ha_ca HOSTFILE
  local src="$1"
  if have openssl && ! openssl x509 -in "$src" -noout >/dev/null 2>&1; then
    err "$src is not a PEM-encoded certificate."
    return 1
  fi
  jx_mkdir "$APP_DIR/deploy/certs"
  jx_install_file "$src" "$APP_DIR/deploy/certs/ha-ca.pem" 644
  CFG[HA_CA_CERT]="/certs/ha-ca.pem"
}

# HA_CA_FILE (environment or --config) is a host path to the CA that signed Home Assistant's
# certificate. Deliberately not NODE_EXTRA_CA_CERTS: that standard Node variable is often exported
# for unrelated reasons and must not be adopted silently.
apply_ca_input() {
  local src="${HA_CA_FILE:-}"
  if [[ -z "$src" && -n "$CONFIG_FILE" ]]; then
    src="$(env_file_get "$CONFIG_FILE" HA_CA_FILE 2>/dev/null || true)"
  fi
  [[ -n "$src" ]] || return 0
  [[ -f "$src" ]] || { err "HA_CA_FILE points to '$src', which is not a file."; return 1; }
  install_ha_ca "$src"
}

ha_ca_hostfile() {
  if [[ "${CFG[HA_CA_CERT]:-}" == /certs/* && -f "$APP_DIR/deploy/certs/${CFG[HA_CA_CERT]#/certs/}" ]]; then
    printf '%s' "$APP_DIR/deploy/certs/${CFG[HA_CA_CERT]#/certs/}"
  fi
}

dns_wait() { # dns_wait DOMAIN IP -> 0 once it resolves to IP (max 5 min)
  local domain="$1" ip="$2" waited=0
  info "Waiting for DNS (checking every 15s, up to 5 minutes; fix the record in another tab)..."
  while (( waited < 300 )); do
    if dns_records "$domain" 4 | grep -qx -- "$ip"; then
      ok "DNS now points to this server"
      return 0
    fi
    sleep 15
    waited=$((waited + 15))
  done
  warn "DNS still does not match after 5 minutes."
  return 1
}

dns_check() { # dns_check DOMAIN
  local domain="$1" ip a aaaa ip6 choice
  ip="${PUBLIC_IPV4:-}"
  [[ -n "$ip" ]] || ip="$(public_ip 4 || true)"
  if [[ -z "$ip" ]]; then
    warn "Could not detect this server's public IP, so DNS cannot be checked automatically."
    return 0
  fi

  while true; do
    a="$(dns_records "$domain" 4)"
    if grep -qx -- "$ip" <<<"$a"; then
      ok "DNS: $domain points to this server ($ip)"
      break
    fi
    if [[ -z "$a" ]]; then
      warn "DNS: $domain has no A record (yet)."
    else
      warn "DNS: $domain points to $(tr '\n' ' ' <<<"$a")but this server's address is $ip."
    fi
    hint "At your DNS provider, create an A record:  $domain  ->  $ip   (it can take a few minutes to propagate)."
    if ! interactive; then
      warn "Continuing anyway (non-interactive). The certificate is requested automatically once DNS is right."
      break
    fi
    choice="$(ask "[w]ait for it (up to 5 min), [r]echeck now, [c]ontinue anyway, [a]bort" "w")"
    case "${choice,,}" in
      w*) dns_wait "$domain" "$ip" && break ;;
      r*) continue ;;
      c*) break ;;
      a*) die "Stopped. Re-run this script once the DNS record exists." ;;
    esac
  done

  aaaa="$(dns_records "$domain" 6)"
  if [[ -n "$aaaa" ]]; then
    ip6="$(public_ip 6 || true)"
    if [[ -z "$ip6" ]] || ! grep -qx -- "$ip6" <<<"$aaaa"; then
      warn "$domain also has an IPv6 (AAAA) record that is not this server: $(tr '\n' ' ' <<<"$aaaa")"
      hint "Let's Encrypt tries IPv6 first, so the certificate would fail. Delete the AAAA record or point it here."
    fi
  fi
}

wizard_mode() {
  local ip choice default cur="${CFG[GATEKEEPER_MODE]:-}" taken
  have curl && ip="$(public_ip 4 || true)" || ip=""
  PUBLIC_IPV4="$ip"
  case "$cur" in domain) default=1 ;; selfsigned) default=2 ;; local) default=3 ;; *) default=2 ;; esac
  taken="$(web_ports_taken)"
  [[ -z "$taken" ]] || default=3

  say ""
  say "${C_BOLD}How do you want to reach HA Gatekeeper (admin page and API)?${C_RESET}"
  say ""
  say "  1) HTTPS with a domain name      ${C_DIM}Recommended. Free, trusted certificate from Let's Encrypt.${C_RESET}"
  say "                                   ${C_DIM}Needs a domain (or a free one from duckdns.org) with an A record${C_RESET}"
  say "                                   ${C_DIM}pointing to this server${ip:+ ($ip)}.${C_RESET}"
  say "  2) HTTPS on this server's IP     ${C_DIM}Works right away, no domain. Self-signed certificate: browsers${C_RESET}"
  say "                                   ${C_DIM}warn once, and API clients must be told to trust it.${C_RESET}"
  say "  3) Private (SSH tunnel only)     ${C_DIM}Nothing is exposed to the internet; you connect with ssh -L.${C_RESET}"
  say ""
  if [[ -n "$taken" ]]; then
    say "  ${C_YELLOW}Ports 80/443 are already used by another program here ($(tr '\n' ' ' <<<"$taken")).${C_RESET}"
    say "  ${C_DIM}Options 1 and 2 need those ports and this installer never stops another web server, so they are unavailable.${C_RESET}"
    say "  ${C_DIM}Choose 3 and let your existing web server forward HTTPS to Gatekeeper (you will be asked for its address).${C_RESET}"
  else
    say "  ${C_DIM}Not sure? Choose 2: it works immediately with just the server's IP address. You can switch to a${C_RESET}"
    say "  ${C_DIM}domain later by running  sudo gatekeeper install --reconfigure .${C_RESET}"
  fi
  say ""
  while true; do
    choice="$(ask "Choose 1, 2 or 3" "$default")"
    case "$choice" in
      1|2)
        if [[ -n "$taken" ]]; then warn "Ports 80/443 are in use by another program. Please choose 3."; continue; fi
        if [[ "$choice" == 1 ]]; then CFG[GATEKEEPER_MODE]=domain; else CFG[GATEKEEPER_MODE]=selfsigned; fi
        return ;;
      3) CFG[GATEKEEPER_MODE]=local; return ;;
    esac
    warn "Please type 1, 2 or 3."
  done
}

# Private mode: an HTTPS web server you already run (nginx, Apache, Traefik...) may forward to us.
wizard_behind_proxy() {
  local v cur="${CFG[GATEKEEPER_PUBLIC_URL]:-}"
  [[ "$cur" == https://* ]] || cur=""
  say ""
  say "${C_BOLD}Do you already run a web server with HTTPS in front of this (nginx, Apache, Traefik...)?${C_RESET}"
  say "  ${C_DIM}If yes, enter the public address it uses, for example https://ha.example.com. I will not touch that server;${C_RESET}"
  say "  ${C_DIM}the summary at the end shows what to add to it. If no, press Enter and use an SSH tunnel.${C_RESET}"
  while true; do
    v="$(ask "Public https:// address of that web server (Enter for none)" "$cur")"
    v="${v%/}"
    if [[ -z "$v" ]]; then CFG[GATEKEEPER_PUBLIC_URL]=""; return 0; fi
    if [[ "$v" == https://* ]] && is_safe_url "$v" && [[ "$(url_authority "$v")" == "${v#https://}" ]]; then
      CFG[GATEKEEPER_PUBLIC_URL]="$v"
      return 0
    fi
    warn "Please enter an address like https://ha.example.com (https only, no path)."
  done
}

wizard_domain() {
  local domain email
  while true; do
    domain="$(ask "Domain name for HA Gatekeeper (for example gatekeeper.example.com)" "${CFG[GATEKEEPER_DOMAIN]:-}")"
    domain="${domain,,}"; domain="${domain#https://}"; domain="${domain#http://}"; domain="${domain%%/*}"
    if is_domain "$domain"; then break; fi
    warn "'$domain' is not a valid domain name (it needs at least one dot, e.g. name.duckdns.org)."
  done
  CFG[GATEKEEPER_DOMAIN]="$domain"

  while true; do
    email="$(ask "E-mail for certificate expiry notices (optional, press Enter to skip)" "${CFG[ACME_EMAIL]:-}")"
    if [[ -z "$email" ]] || is_email "$email"; then break; fi
    warn "That does not look like an e-mail address."
  done
  CFG[ACME_EMAIL]="$email"
  dns_check "$domain"
}

wizard_selfsigned() {
  local ip cur="${CFG[GATEKEEPER_DOMAIN]:-}"
  is_ipv4 "$cur" || cur="${PUBLIC_IPV4:-}"
  while true; do
    ip="$(ask "This server's public IP address" "$cur")"
    if is_ipv4 "$ip"; then break; fi
    warn "That is not a valid IPv4 address."
  done
  CFG[GATEKEEPER_DOMAIN]="$ip"
  CFG[ACME_EMAIL]=""
}

wizard_home_assistant() {
  local url token cacert host_url choice cafile problem
  local ask_url=true ask_token=true first=true
  say ""
  say "${C_BOLD}Home Assistant connection${C_RESET}"
  say "  Gatekeeper runs on this server, so it has to reach Home Assistant from here."
  say "  ${C_DIM}Works:${C_RESET}  Nabu Casa (https://xxxx.ui.nabu.casa) | your own public HTTPS address |"
  say "         a VPN address (Tailscale/WireGuard, e.g. http://100.x.y.z:8123) |"
  say "         http://localhost:8123 when Home Assistant runs on this same server."
  say "  ${C_DIM}Does not work:${C_RESET} home-network addresses (192.168.x.x, homeassistant.local) unless a VPN links them."

  url="$(ha_url_for_host_test "${CFG[HA_BASE_URL]:-}")"
  token="${CFG[HA_TOKEN]:-}"
  cacert="$(ha_ca_hostfile)"

  while true; do
    if $ask_url; then
      while true; do
        url="$(ask "Home Assistant URL" "$url")"
        if host_url="$(normalize_ha_url "$url")" && is_safe_url "$host_url"; then
          [[ "$host_url" == "$url" ]] || info "Using $host_url"
          url="$host_url"
          break
        fi
        warn "Please enter an address like https://xxxx.ui.nabu.casa or http://192.168.1.10:8123"
      done
      case "$(ha_url_class "$url")" in
        mdns)    warn "'$(url_host "$url")' is a home-network name. It will not resolve from a VPS unless a VPN is in place." ;;
        private) warn "$(url_host "$url") is a private address. A VPS can only reach it through a VPN (Tailscale/WireGuard)." ;;
      esac
      ask_url=false
    fi

    if $ask_token && $first && [[ -n "$token" ]] && confirm "Keep the saved Home Assistant token?" y; then
      ask_token=false
    fi
    if $ask_token || [[ -z "$token" ]]; then
      say "  ${C_DIM}Create a token in Home Assistant: your profile (bottom-left) > Security > Long-lived access tokens > Create token.${C_RESET}"
      while true; do
        token="$(ask_secret "Paste the long-lived access token")"
        token="$(trim "$token")"
        problem="$(token_problem "$token")"
        [[ -z "$problem" ]] && break
        warn "That token cannot be used: $problem."
      done
      ask_token=false
    fi
    first=false

    if ! have curl; then
      warn "Not testing the Home Assistant connection: curl is not installed (dry run). The final check tests it."
      break
    fi
    info "Testing the connection to Home Assistant..."
    if ha_probe "$url" "$token" "$cacert"; then
      ok "Home Assistant ${HA_VERSION:-?}${HA_LOCATION:+ (\"$HA_LOCATION\")} is reachable and the token works"
      break
    fi
    ha_explain_failure "$url"

    while true; do
      choice="$(ask "What now? [r]etry, [u]rl change, [t]oken change, [k] private CA file, [c]ontinue anyway, [a]bort" "r")"
      case "${choice,,}" in
        r*) break ;;
        u*) ask_url=true; break ;;
        t*) ask_token=true; break ;;
        k*)
          cafile="$(ask "Path to the CA certificate file (PEM) that signed Home Assistant's certificate")"
          if [[ -f "$cafile" ]] && install_ha_ca "$cafile"; then
            cacert="$(ha_ca_hostfile)"
            ok "Will trust that CA for Home Assistant"
            break
          fi
          warn "Could not use that file."
          ;;
        c*)
          warn "Continuing with unverified Home Assistant settings."
          CFG[HA_BASE_URL]="$url"
          CFG[HA_TOKEN]="$token"
          return 0
          ;;
        a*) die "Stopped. Nothing was changed." ;;
      esac
    done
  done

  CFG[HA_BASE_URL]="$url"
  CFG[HA_TOKEN]="$token"
}

wizard_admin_password() {
  local choice pw pw2 problem
  say ""
  say "${C_BOLD}Admin dashboard password${C_RESET}"
  if [[ -n "${CFG[ADMIN_PASSWORD]:-}" ]] && confirm "Keep the current admin password?" y; then
    return 0
  fi
  choice="$(ask "[T]ype your own password, or [G]enerate a strong random one" "T")"
  case "${choice,,}" in
    t*)
      while true; do
        pw="$(ask_secret "Admin password (at least 8 characters, 12 or more recommended)")"
        problem="$(password_problem "$pw")"
        if [[ -n "$problem" ]]; then warn "That password cannot be used: $problem."; continue; fi
        pw2="$(ask_secret "Repeat the password")"
        if [[ "$pw" != "$pw2" ]]; then warn "The two entries differ."; continue; fi
        if (( ${#pw} < 12 )) && ! confirm "That is short for an internet-facing login. Use it anyway?" n; then continue; fi
        break
      done
      CFG[ADMIN_PASSWORD]="$pw"
      GENERATED_ADMIN_PASSWORD=""
      ;;
    *)
      CFG[ADMIN_PASSWORD]="$(gen_alnum 24)"
      GENERATED_ADMIN_PASSWORD=1
      ;;
  esac
}

wizard_advanced() {
  local v hintip
  say ""
  say "${C_BOLD}Advanced options${C_RESET}"

  while true; do
    v="$(ask "Keep audit-log entries for how many days? (0 keeps everything)" "${CFG[AUDIT_LOG_RETENTION_DAYS]:-90}")"
    is_uint "$v" && break
    warn "Please enter a whole number."
  done
  CFG[AUDIT_LOG_RETENTION_DAYS]="$v"

  while true; do
    v="$(ask "Alert webhook for down/recovered notices (Slack, Discord, Mattermost or generic; Enter to skip)" "${CFG[ALERT_WEBHOOK_URL]:-}")"
    if [[ -z "$v" ]] || is_safe_url "$v"; then break; fi
    warn "Please enter a plain http(s) URL without spaces or quotes."
  done
  CFG[ALERT_WEBHOOK_URL]="$v"
  if [[ -n "$v" ]] && confirm "Send a test alert now?" y; then
    if send_webhook "$v" "[HA Gatekeeper @ $(hostname)] Test alert from the installer. Alerts are working."; then
      ok "Test alert sent. Check your channel."
    else
      warn "The webhook did not accept the test message. Check the URL."
    fi
  fi

  if [[ "${CFG[GATEKEEPER_MODE]}" != local ]]; then
    hintip="${SSH_CLIENT:-}"
    hintip="${hintip%% *}"
    say "  ${C_DIM}Restrict the admin API to your own addresses (the public token API stays open). Leave empty for no restriction.${C_RESET}"
    [[ -z "$hintip" ]] || say "  ${C_DIM}You appear to be connected from $hintip. Your browser probably shares that address.${C_RESET}"
    while true; do
      v="$(ask "Allowed IPs/CIDRs for the admin API (space or comma separated)" "${CFG[ADMIN_ALLOWED_IPS]:-}")"
      if [[ -z "$v" ]]; then CFG[ADMIN_ALLOWED_IPS]=""; break; fi
      if v="$(normalize_ip_list "$v")"; then
        CFG[ADMIN_ALLOWED_IPS]="$v"
        warn "If your address changes you will be locked out of the admin page: edit ADMIN_ALLOWED_IPS in $APP_DIR/.env and re-run the installer."
        break
      fi
      warn "Those do not look like IP addresses or CIDR ranges (for example 203.0.113.5 or 10.0.0.0/8)."
    done
  fi
}

mode_description() {
  case "${CFG[GATEKEEPER_MODE]}" in
    domain) printf 'HTTPS with a Let'"'"'s Encrypt certificate at https://%s' "${CFG[GATEKEEPER_DOMAIN]}" ;;
    selfsigned) printf 'HTTPS on the IP address %s (self-signed certificate)' "${CFG[GATEKEEPER_DOMAIN]}" ;;
    *)
      if [[ "${CFG[GATEKEEPER_PUBLIC_URL]:-}" == https://* ]]; then
        printf 'private on this server (127.0.0.1:%s); your own web server serves it at %s' "${CFG[GATEKEEPER_PORT]}" "${CFG[GATEKEEPER_PUBLIC_URL]}"
      else
        printf 'private: only on this server (127.0.0.1:%s), reached through an SSH tunnel' "${CFG[GATEKEEPER_PORT]}"
      fi ;;
  esac
}

show_settings() {
  say ""
  say "${C_BOLD}Settings${C_RESET}"
  say "  Access             : $(mode_description)"
  say "  Home Assistant     : ${CFG[HA_BASE_URL]}  (token ${C_DIM}$(mask "${CFG[HA_TOKEN]}")${C_RESET})"
  if [[ -n "$GENERATED_ADMIN_PASSWORD" ]]; then
    say "  Admin password     : generated (shown at the end)"
  else
    say "  Admin password     : set"
  fi
  say "  Audit log kept for : ${CFG[AUDIT_LOG_RETENTION_DAYS]} days"
  say "  Alerts             : ${CFG[ALERT_WEBHOOK_URL]:+webhook configured}${CFG[ALERT_WEBHOOK_URL]:-none}"
  if [[ "${CFG[GATEKEEPER_MODE]}" != local ]]; then
    say "  Admin API limited to: ${CFG[ADMIN_ALLOWED_IPS]:-anyone with the password}"
  fi
  say "  Data folder        : $(data_dir_abs)"
  say "  Secrets            : session and token-hash secrets $([[ -f "$APP_DIR/.env" ]] && echo 'kept/generated' || echo 'generated')"
}

mask() {
  local s="$1"
  if (( ${#s} <= 8 )); then printf '****'; else printf '%s****%s' "${s:0:3}" "${s: -2}"; fi
}

run_wizard() {
  wizard_mode
  case "${CFG[GATEKEEPER_MODE]}" in
    domain) wizard_domain ;;
    selfsigned) wizard_selfsigned ;;
    local) wizard_behind_proxy ;;
  esac
  wizard_home_assistant
  wizard_admin_password
  if confirm "Configure advanced options (alerts, admin IP allow-list, log retention)?" n; then
    wizard_advanced
  fi
  ensure_secrets
  derive_config
  show_settings
}

# Non-interactive: everything comes from --config, environment variables, the existing .env and defaults.
noninteractive_config() {
  local problems
  if [[ -z "${CFG[GATEKEEPER_MODE]:-}" ]]; then
    if is_domain "${CFG[GATEKEEPER_DOMAIN]:-}"; then CFG[GATEKEEPER_MODE]=domain; else CFG[GATEKEEPER_MODE]=local; fi
  fi
  if [[ "${CFG[GATEKEEPER_MODE]}" == selfsigned && -z "${CFG[GATEKEEPER_DOMAIN]:-}" ]]; then
    have curl && PUBLIC_IPV4="$(public_ip 4 || true)" || PUBLIC_IPV4=""
    CFG[GATEKEEPER_DOMAIN]="$PUBLIC_IPV4"
  fi
  if [[ -n "${CFG[HA_BASE_URL]:-}" ]]; then
    CFG[HA_BASE_URL]="$(normalize_ha_url "$(ha_url_for_host_test "${CFG[HA_BASE_URL]}")" || printf '%s' "${CFG[HA_BASE_URL]}")"
  fi
  if [[ -z "${CFG[ADMIN_PASSWORD]:-}" ]]; then
    CFG[ADMIN_PASSWORD]="$(gen_alnum 24)"
    GENERATED_ADMIN_PASSWORD=1
  fi
  apply_ca_input || die "The CA file could not be used."

  ensure_secrets
  derive_config

  problems="$(config_problems)"
  if [[ -n "$problems" ]]; then
    err "The configuration is incomplete or invalid:"
    while IFS= read -r line; do say "       - $line"; done <<<"$problems"
    hint "Provide the values as environment variables (sudo -E, or sudo VAR=... ./install.sh), with --config FILE, or run interactively."
    hint "See deploy/env.example for every setting."
    exit 1
  fi

  if [[ -n "${GK_SKIP_HA_CHECK:-}" ]]; then
    warn "Skipping the Home Assistant connection test (GK_SKIP_HA_CHECK is set)."
  elif ! have curl; then
    warn "Not testing the Home Assistant connection: curl is not installed (dry run). The final check tests it."
  elif ha_probe "$(ha_url_for_host_test "${CFG[HA_BASE_URL]}")" "${CFG[HA_TOKEN]}" "$(ha_ca_hostfile)"; then
    ok "Home Assistant ${HA_VERSION:-?}${HA_LOCATION:+ (\"$HA_LOCATION\")} is reachable and the token works"
  else
    ha_explain_failure "${CFG[HA_BASE_URL]}"
    die "Cannot continue without a working Home Assistant connection. (Set GK_SKIP_HA_CHECK=1 to override.)"
  fi

  if [[ "${CFG[GATEKEEPER_MODE]}" == domain ]] && have curl; then dns_check "${CFG[GATEKEEPER_DOMAIN]}"; fi
}

configure() {
  cfg_defaults
  cfg_load_file "$APP_DIR/.env"
  [[ -z "$CONFIG_FILE" ]] || cfg_load_file "$CONFIG_FILE"
  cfg_load_environment
  [[ -f "$APP_DIR/.env" ]] && FRESH_INSTALL=false || FRESH_INSTALL=true

  local keep=false
  if [[ -f "$APP_DIR/.env" ]] && ! $RECONFIGURE; then
    derive_config
    if cfg_is_complete; then
      show_settings
      say ""
      if ! interactive || confirm "Existing settings found. Keep them and just re-apply/repair the installation?" y; then
        keep=true
      fi
    fi
  fi

  if $keep; then
    ensure_secrets
    derive_config
    apply_ca_input || true
    ok "Keeping the existing settings"
    return 0
  fi

  if interactive; then
    run_wizard
  else
    info "Non-interactive mode: using environment variables, --config and defaults"
    noninteractive_config
  fi
}

# -------------------------------------------------------------------------------------------------
# Install
# -------------------------------------------------------------------------------------------------

apply_and_start() {
  write_env_file
  fail_point after-env
  jx_mkdir "$APP_DIR/backups" tree
  chmod 700 "$APP_DIR/backups"
  jx_mkdir "$APP_DIR/deploy/certs"
  jx_mkdir "$APP_DIR/deploy/caddy"
  fix_data_permissions
  sync_secret_files || die "Could not write the secret files."
  ok "Settings saved to $APP_DIR/.env (private, mode 600); secrets are mounted as files, not environment variables"

  prepull_images || die "Could not download the required container images."
  write_caddyfile || die "Could not create a valid Caddy configuration."
  compose_build || die "The image build failed. Full log: $LOG_FILE"
  fail_point after-build

  pause_watchdog_for_maintenance
  start_stack || die "The Gatekeeper container did not become healthy. Full log: $LOG_FILE"

  if proxy_enabled; then
    if $CADDY_CHANGED && docker inspect --type container "$CADDY_CONTAINER" >/dev/null 2>&1; then
      dc exec -T caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile >>"$LOG_FILE" 2>&1 \
        || dc restart caddy >>"$LOG_FILE" 2>&1 || true
    fi
    if wait_for_container "$CADDY_CONTAINER" 60; then
      ok "HTTPS proxy (Caddy) is running"
    else
      warn "The HTTPS proxy is not healthy yet; the verification below shows details."
    fi
  fi
  resume_watchdog
  WATCHDOG_PAUSED_BY_US=false
}

export_caddy_root() {
  local out="$APP_DIR/gatekeeper-root-ca.crt" i
  for i in $(seq 1 15); do
    if dc cp caddy:/data/caddy/pki/authorities/local/root.crt "$out" >>"$LOG_FILE" 2>&1; then
      chmod 644 "$out"
      return 0
    fi
    sleep 2
  done
  return 1
}

should_drill() {
  case "$DRILL" in
    yes) return 0 ;;
    no) return 1 ;;
  esac
  if $FRESH_INSTALL; then
    interactive || return 0
    confirm "Run a crash-recovery drill? (briefly kills and stops the app, ~1 minute, proves auto-restart works)" y
  else
    interactive && confirm "Run a crash-recovery drill? (briefly interrupts the running app)" n
  fi
}

print_summary() { # print_summary [failed]
  local url="${CFG[GATEKEEPER_PUBLIC_URL]}" ip
  if [[ "${1:-}" == failed ]]; then
    banner "HA Gatekeeper is installed, but $V_FAIL check(s) FAILED: it is not fully working yet"
    say "  ${C_YELLOW}Scroll up to the [FAIL] lines above for what to fix, then run:  gatekeeper verify${C_RESET}"
  else
    banner "HA Gatekeeper is installed"
  fi
  say ""
  say "  Admin dashboard : ${C_BOLD}$url${C_RESET}"
  if [[ -n "$GENERATED_ADMIN_PASSWORD" ]]; then
    say "  Admin password  : ${C_BOLD}${CFG[ADMIN_PASSWORD]}${C_RESET}   ${C_DIM}(shown once; also saved in $APP_DIR/.env)${C_RESET}"
  else
    say "  Admin password  : the one you chose (saved in $APP_DIR/.env)"
  fi
  say "  API base URL    : $url   ${C_DIM}(GATEKEEPER_BASE_URL for agents and the MCP adapter)${C_RESET}"

  case "${CFG[GATEKEEPER_MODE]}" in
    local)
      if [[ "$url" == https://* ]]; then
        say ""
        say "  Gatekeeper listens only on 127.0.0.1:${CFG[GATEKEEPER_PORT]}. Your own web server serves HTTPS at $url."
        say "  This installer does not touch that server. If it does not forward yet, add this to its site (nginx example):"
        say "      ${C_BOLD}location / {${C_RESET}"
        say "      ${C_BOLD}    proxy_pass http://127.0.0.1:${CFG[GATEKEEPER_PORT]};${C_RESET}"
        say "      ${C_BOLD}    proxy_set_header Host \$host;${C_RESET}"
        say "      ${C_BOLD}    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;${C_RESET}"
        say "      ${C_BOLD}    proxy_set_header X-Forwarded-Proto \$scheme;${C_RESET}"
        say "      ${C_BOLD}}${C_RESET}"
        say "  ${C_DIM}then reload it (nginx -t && systemctl reload nginx) and run: gatekeeper verify${C_RESET}"
      else
        ip="$(public_ip 4 || echo '<server-ip>')"
        say ""
        say "  Private mode: nothing is exposed. From your own computer run:"
        say "      ${C_BOLD}ssh -L ${CFG[GATEKEEPER_PORT]}:127.0.0.1:${CFG[GATEKEEPER_PORT]} root@${ip}${C_RESET}"
        say "  and open http://localhost:${CFG[GATEKEEPER_PORT]}  ${C_DIM}(Chrome, Firefox or Edge; Safari refuses secure cookies on plain-HTTP localhost)${C_RESET}"
      fi
      ;;
    selfsigned)
      say ""
      say "  Self-signed certificate: the browser warns once; choose 'Advanced > Proceed'."
      if export_caddy_root; then
        say "  To remove the warning, install this file as a trusted root on your computer:"
        say "      ${C_BOLD}$APP_DIR/gatekeeper-root-ca.crt${C_RESET}   (copy it with scp)"
        say "  For agents/MCP over Node, set  NODE_EXTRA_CA_CERTS=/path/to/gatekeeper-root-ca.crt"
      fi
      ;;
  esac

  say ""
  say "${C_BOLD}Next steps${C_RESET}"
  say "  1. Open the dashboard and sign in."
  say "  2. Use Quick Start to choose the exact entities and services an agent may use, and create its token."
  say "  3. Give agents only that token. They never see your Home Assistant token."
  say ""
  say "${C_BOLD}It looks after itself${C_RESET}"
  say "  - Docker restarts it after a crash and after a reboot."
  say "  - A watchdog checks it every minute and heals hangs, stopped/deleted containers and a dead Docker daemon."
  say "  - The database and .env are backed up daily to $APP_DIR/backups (kept: $BACKUP_KEEP)."
  [[ -z "${CFG[ALERT_WEBHOOK_URL]:-}" ]] && say "  - Want a message when it goes down? Re-run with --reconfigure and set an alert webhook."
  say ""
  say "  Manage it:   ${C_BOLD}gatekeeper status | verify | logs -f | update | backup | restart${C_RESET}"
  say "  Install log: $LOG_FILE"
  say ""
  warn "Copy $APP_DIR/.env to a safe place. It holds API_KEY_HASH_SECRET: without it every issued token stops working."
}

# -------------------------------------------------------------------------------------------------
# The plan: everything that will change, shown and approved BEFORE anything is changed
# -------------------------------------------------------------------------------------------------

# Test hook: GK_FAIL_AT=<point> makes the install fail on purpose at that point (to prove rollback).
fail_point() {
  if [[ "${GK_FAIL_AT:-}" == "$1" ]]; then
    die "Test hook GK_FAIL_AT=$1: stopping here on purpose."
  fi
  return 0
}

# A container named like ours that belongs to something else must never be replaced.
check_container_conflicts() {
  docker_up || return 0
  local name wd
  for name in "$GK_CONTAINER" "$CADDY_CONTAINER"; do
    docker inspect --type container "$name" >/dev/null 2>&1 || continue
    wd="$(docker inspect --type container -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$name" 2>/dev/null || true)"
    if [[ "$wd" != "$APP_DIR" ]]; then
      die "A container named '$name' already exists and does not belong to $APP_DIR (${wd:+it was started from $wd}${wd:-it was not started by this installer}). This installer will not touch it. Nothing was changed."
    fi
    STACK_PRE=1
  done
  return 0
}

# Read-only analysis (plus the few questions that decide what the plan contains).
decide_changes() {
  STACK_PRE=0
  compute_missing_prereqs
  docker_plan
  decide_docker_start
  swap_plan
  ufw_decide
  check_container_conflicts
  pick_app_port
  check_web_ports || die "Nothing was changed."
}

PLAN_SOFTWARE=(); PLAN_SYSTEM=(); PLAN_NETWORK=(); PLAN_APPDIR=(); PLAN_KEEP=()

build_plan() {
  PLAN_SOFTWARE=(); PLAN_SYSTEM=(); PLAN_NETWORK=(); PLAN_APPDIR=(); PLAN_KEEP=()
  local mode="${CFG[GATEKEEPER_MODE]}" hp owner p units fw_active=false

  # --- software
  if (( ${#P_PKGS[@]} > 0 )); then
    PLAN_SOFTWARE+=("Install ${#P_PKGS[@]} small system package(s) with ${PKG}: ${P_PKGS[*]}")
  else
    PLAN_KEEP+=("The tools the installer needs (curl, git, jq, openssl...) are already installed: no packages are added")
  fi
  case "$P_DOCKER" in
    install) PLAN_SOFTWARE+=("Install Docker Engine with Docker's official script (get.docker.com): adds Docker's package repository, installs docker-ce, containerd and the Compose plugin, enables Docker at boot and starts it") ;;
    start)   PLAN_SOFTWARE+=("START the Docker service. It is installed but stopped, and starting it also starts every other container on this server that has a restart policy") ;;
    ok)      PLAN_KEEP+=("Docker ($(docker --version 2>/dev/null | head -n 1)) is already installed and running: it is not reinstalled, upgraded or restarted") ;;
  esac
  if [[ "$P_DOCKER" != install ]] && $P_COMPOSE_NEEDED; then
    PLAN_SOFTWARE+=("Install the Docker Compose plugin (your distribution's package, or a download from github.com/docker/compose into /usr/local/lib/docker/cli-plugins)")
  fi

  # --- system
  if [[ "$P_DOCKER" != install ]] && $P_DOCKER_BOOT; then
    PLAN_SYSTEM+=("Enable the Docker service at boot (it is installed but not set to start at boot; needed to come back after a reboot)")
  fi
  if (( P_SWAP_MB > 0 )); then
    PLAN_SYSTEM+=("Create a ${P_SWAP_MB} MB swap file at $SWAP_FILE and add one line to $FSTAB_FILE (this server has little memory and the image build can run out of it)")
  fi
  PLAN_SYSTEM+=("Create the folder $STATE_DIR (the watchdog's heartbeat and pause flag)")
  if have_systemd; then
    PLAN_SYSTEM+=("Create or refresh 5 systemd units in $SYSTEMD_DIR (ha-gatekeeper.service, ha-gatekeeper-watchdog.service/.timer, ha-gatekeeper-backup.service/.timer) and enable them: start at boot, watchdog every minute, daily backup")
  else
    PLAN_SYSTEM+=("Create the cron file $CRON_FILE (watchdog every minute, start at boot, daily backup); there is no systemd here")
  fi
  PLAN_SYSTEM+=("Create the command $BIN_LINK (a link to $APP_DIR/install.sh)")
  PLAN_SYSTEM+=("Write this run's log to $REAL_LOG_FILE; the watchdog logs to $WATCHDOG_LOG")
  if [[ "$P_DOCKER" == install && "$PKG" == apt ]]; then
    PLAN_SYSTEM+=("Temporarily write $APT_LOCK_CONF while Docker installs (so apt waits for locks); it is removed right after")
  fi

  # --- network and firewall
  if [[ "$mode" == local ]]; then
    PLAN_NETWORK+=("Open no ports. Gatekeeper listens on 127.0.0.1:${CFG[GATEKEEPER_PORT]} only, reachable from this server itself")
  else
    PLAN_NETWORK+=("Run the HTTPS proxy (Caddy container) that publishes ports 80 and 443 on all addresses of this server; Gatekeeper itself stays on 127.0.0.1:${CFG[GATEKEEPER_PORT]}")
  fi
  hp="$(ha_local_port || true)"
  if [[ "${GATEKEEPER_UFW:-}" == 0 ]]; then
    PLAN_NETWORK+=("Firewall: not touched (GATEKEEPER_UFW=0). Rules you may need are printed at the end instead")
  else
    ufw_active && fw_active=true
    firewalld_active && fw_active=true
    if $P_UFW_ENABLE; then
      PLAN_NETWORK+=("TURN ON the ufw firewall (it is off now): allow SSH (port ${P_UFW_SSH_PORTS}), 80/tcp, 443/tcp, 443/udp and block all other incoming connections. Other services on this server would stop being reachable")
    elif $fw_active; then
      [[ "$mode" == local ]] || PLAN_NETWORK+=("Firewall (already active): add 80/tcp, 443/tcp, 443/udp where missing. None of your existing rules is changed or removed")
    elif [[ "$mode" != local ]]; then
      PLAN_NETWORK+=("Firewall: none is active, so nothing is changed. If your provider has its own firewall, allow TCP 80 and 443 there")
    fi
    if [[ -n "$hp" ]] && { $fw_active || $P_UFW_ENABLE; }; then
      PLAN_NETWORK+=("Firewall: let the Docker networks (172.16.0.0/12) reach TCP port $hp, because Home Assistant runs on this server")
    fi
  fi
  PLAN_NETWORK+=("Contact Home Assistant at ${CFG[HA_BASE_URL]} (its token is stored on this server only)")

  # --- inside the app folder
  units="$APP_DIR"
  PLAN_APPDIR+=("$units/.env: your settings and secrets (mode 600; the previous one is kept as .env.previous)")
  PLAN_APPDIR+=("$units/secrets/: one root-only file per secret, mounted read-only into the container (secrets never appear in 'docker inspect')")
  PLAN_APPDIR+=("$units/data/ (database), $units/backups/ (daily backups)")
  proxy_enabled && PLAN_APPDIR+=("$units/deploy/caddy/Caddyfile (generated)")
  [[ -z "${CFG[HA_CA_CERT]:-}" ]] || PLAN_APPDIR+=("$units/deploy/certs/ha-ca.pem (the CA you provided for Home Assistant)")
  if (( STACK_PRE == 1 )); then
    PLAN_APPDIR+=("Rebuild the Docker image ha-gatekeeper:local if needed and re-create the containers of the existing installation with these settings")
  else
    PLAN_APPDIR+=("Build the Docker image ha-gatekeeper:local, download the base images it needs (if you do not have them) and start the container(s): $GK_CONTAINER$(if proxy_enabled; then printf ', %s' "$CADDY_CONTAINER"; fi)")
  fi

  # --- what is explicitly left alone
  PLAN_KEEP+=("Your other Docker containers, images, volumes and networks; SSH settings; every existing firewall rule")
  for p in 80 443; do
    if port_in_use "$p" && ! stack_publishes_port "$p"; then
      owner="$(port_owner "$p" || true)"
      PLAN_KEEP+=("Port $p is used by ${owner:-another program}: it is not stopped, changed or reconfigured")
    fi
  done
  if [[ -x /usr/sbin/nginx || -x /usr/sbin/apache2 || -x /usr/sbin/httpd ]]; then
    PLAN_KEEP+=("Your web server (nginx/Apache) configuration is never read or modified")
  fi
}

print_plan() {
  local line
  banner "Exactly what I am about to change on this server"
  say "  ${C_BOLD}Nothing has been changed yet.${C_RESET} If you say yes, this is the complete list. Each change is recorded,"
  say "  and if anything fails (an error, Ctrl-C, or the final health check) everything below is undone again,"
  say "  newest first. Things that were already on this server are never removed."
  say ""
  if (( ${#PLAN_SOFTWARE[@]} > 0 )); then
    say "${C_BOLD}Software${C_RESET}"
    for line in "${PLAN_SOFTWARE[@]}"; do say "   * $line"; done
    say ""
  fi
  say "${C_BOLD}System (outside $APP_DIR)${C_RESET}"
  for line in "${PLAN_SYSTEM[@]}"; do say "   * $line"; done
  say ""
  say "${C_BOLD}Network and firewall${C_RESET}"
  for line in "${PLAN_NETWORK[@]}"; do say "   * $line"; done
  say ""
  say "${C_BOLD}Inside the app folder${C_RESET}"
  for line in "${PLAN_APPDIR[@]}"; do say "   * $line"; done
  say ""
  say "${C_BOLD}Left untouched${C_RESET}"
  for line in "${PLAN_KEEP[@]}"; do say "   * $line"; done
  say ""
}

# One decision for the whole list. Default is NO. --yes approves it for unattended runs.
confirm_plan() {
  if $DRY_RUN; then
    say "${C_BOLD}Dry run:${C_RESET} nothing was changed. Run the same command without --dry-run to apply the list above."
    journal_rollback quiet || true
    INSTALL_ACTIVE=false
    DISCARD_LOG=true
    exit 0
  fi
  if $ASSUME_YES; then
    say "--yes was given: continuing with exactly this list."
    return 0
  fi
  if ! interactive; then
    journal_rollback quiet || true
    INSTALL_ACTIVE=false
    DISCARD_LOG=true
    err "There is no terminal to ask on, so I cannot get your approval. Nothing was changed."
    hint "Run it interactively, or add --yes to approve this list unattended (add --dry-run first to just see it)."
    exit 1
  fi
  if ! confirm "Make exactly these changes?" n; then
    journal_rollback quiet || true
    INSTALL_ACTIVE=false
    DISCARD_LOG=true
    say "Cancelled. Nothing was changed."
    exit 1
  fi
}

# The list was approved: the real log starts and the journal gets its on-disk copy.
approve_plan() {
  adopt_real_log
  log_file "PLAN APPROVED"
  ensure_state_dir
  JOURNAL_LOG="$STATE_DIR/install-journal.log"
  ( umask 077; : >>"$JOURNAL_LOG" ) 2>/dev/null || JOURNAL_LOG=""
}

# --- end of run

commit_install() {
  INSTALL_ACTIVE=false
  if [[ -d "$STATE_DIR" ]]; then
    { printf 'Changes made by the install on %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"; journal_list; printf -- '--- left in place by uninstall:\n'; journal_list keep-only; } \
      >"$STATE_DIR/changes.txt" 2>/dev/null || true
    chmod 600 "$STATE_DIR/changes.txt" 2>/dev/null || true
  fi
}

print_changes_summary() {
  local line n=0 inside=() outside=()
  banner "What this installation changed on your server"
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    if [[ "$line" == *"$APP_DIR"* ]]; then inside+=("$line"); else outside+=("$line"); fi
  done < <(journal_list)
  say "  ${C_BOLD}Outside $APP_DIR:${C_RESET}"
  if (( ${#outside[@]} > 0 )); then
    for line in "${outside[@]}"; do say "   * $line"; done
  else
    say "   * nothing: everything needed was already in place"
  fi
  say "  ${C_BOLD}Inside $APP_DIR:${C_RESET}"
  if (( ${#inside[@]} > 0 )); then
    for line in "${inside[@]}"; do say "   * $line"; done
  else
    say "   * (nothing new: the existing files were re-used)"
  fi
  say ""
  say "  ${C_BOLD}Undo it:${C_RESET}  sudo gatekeeper uninstall"
  say "  uninstall removes: the containers, the systemd units (or cron file), the 'gatekeeper' command, the firewall rules"
  say "  named 'HA Gatekeeper ...', and the secrets/ folder. With your OK (or --purge) it also deletes the built image,"
  say "  the saved HTTPS certificates, the data and .env."
  say "  uninstall does ${C_BOLD}NOT${C_RESET} undo these (they may be useful to other things on the server):"
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    say "   * $line"
  done < <(journal_list keep-only)
  say "   * base Docker images that were downloaded, and Docker's build cache (docker image prune / docker builder prune)"
  say "   * the code in $APP_DIR, the backups in $APP_DIR/backups and the log $REAL_LOG_FILE"
}

cmd_install() {
  INSTALL_ACTIVE=true
  banner "HA Gatekeeper installer  v$GK_VERSION"
  say "  Sets up HA Gatekeeper in Docker on this server: guided settings, HTTPS, automatic restarts,"
  say "  a watchdog, backups, and a full health check at the end. Safe to re-run at any time."
  say "  ${C_BOLD}Nothing is changed until you have seen the complete list of changes and said yes.${C_RESET}"
  $DRY_RUN && say "  ${C_YELLOW}Dry run: I will show the list and stop.${C_RESET}"
  journal_tmp >/dev/null

  step 1 7 "Checking this server (read-only)"
  check_resources
  if have curl; then check_internet; else warn "curl is not installed yet, so the internet check is skipped for now."; fi

  step 2 7 "Your settings"
  if ! have curl; then
    local first_tools=(curl)
    [[ -e /etc/ssl/certs/ca-certificates.crt || -d /etc/pki/tls/certs || -e /etc/ssl/cert.pem ]] || first_tools+=(ca-certificates)
    consent_install_tools "Testing your Home Assistant connection needs curl." "${first_tools[@]}" || true
  fi
  configure
  decide_changes
  fail_point after-config

  step 3 7 "The complete list of changes"
  build_plan
  print_plan
  confirm_plan
  approve_plan

  step 4 7 "Preparing the server"
  ensure_prereqs
  fail_point after-prereqs
  create_swap
  fail_point after-swap
  ensure_docker
  fail_point after-docker

  step 5 7 "Building and starting"
  apply_and_start
  fail_point after-start

  step 6 7 "Automatic restarts, watchdog and firewall"
  install_automation
  if [[ "${CFG[GATEKEEPER_MODE]}" == local ]]; then remove_firewall_rules; fi
  open_firewall
  cmd_backup || warn "The first backup did not complete; run: gatekeeper backup"
  fail_point after-automation

  step 7 7 "Verifying everything"
  JUST_INSTALLED=true
  fail_point before-verify
  local drill=""
  should_drill && drill=with-drill
  local verified=true
  verify_all "$drill" || verified=false

  if $verified; then
    commit_install
    print_summary
    print_changes_summary
    return 0
  fi

  # Failures that only mean "not ready yet" (a certificate still being issued) do not undo the install.
  if (( V_FAIL > 0 && V_FAIL == V_FAIL_DEFERRED )); then
    commit_install
    print_summary failed
    print_changes_summary
    warn "The only open item is the HTTPS certificate, which Caddy keeps requesting by itself. Check again later:  gatekeeper verify"
    exit 1
  fi

  if $KEEP_ON_FAILURE; then
    INSTALL_ACTIVE=false
    print_summary failed
    warn "Some checks failed (see above). The installation was kept because --keep-on-failure is set. Fix them and run:  gatekeeper verify"
    exit 1
  fi
  err "The final health check failed, so this installation is being undone (use --keep-on-failure to keep a failed install for debugging)."
  journal_rollback || true
  INSTALL_ACTIVE=false
  hint "Fix the problem listed above and run the installer again. Install log: $REAL_LOG_FILE"
  exit 1
}

# -------------------------------------------------------------------------------------------------
# Other commands
# -------------------------------------------------------------------------------------------------

load_runtime_config() {
  [[ -f "$APP_DIR/.env" ]] || die "Not configured yet ($APP_DIR/.env is missing). Run: sudo $APP_DIR/install.sh"
  cfg_defaults
  cfg_load_file "$APP_DIR/.env"
  derive_config
}

require_docker() { # require_docker [start]
  have docker || die "Docker is not installed. Run: sudo $APP_DIR/install.sh"
  DOCKER_BIN="$(command -v docker)"
  docker_up && return 0
  if [[ "${1:-}" == start ]]; then
    start_docker
    return 0
  fi
  die "Docker is not running. Start it with  systemctl start docker  (that also starts your other containers), then try again."
}

cmd_verify() {
  load_runtime_config
  have docker && DOCKER_BIN="$(command -v docker)"
  banner "HA Gatekeeper health check"
  local drill="" rc=0
  [[ "$DRILL" == yes ]] && drill=with-drill
  verify_all "$drill" || rc=1
  exit "$rc"
}

human_age() { # human_age SECONDS
  local s="$1"
  if (( s < 120 )); then printf '%ss' "$s"
  elif (( s < 7200 )); then printf '%sm' $((s / 60))
  elif (( s < 172800 )); then printf '%sh' $((s / 3600))
  else printf '%sd' $((s / 86400))
  fi
}

cmd_status() {
  load_runtime_config
  have docker && DOCKER_BIN="$(command -v docker)"
  local name state health since hb newest
  banner "HA Gatekeeper status"
  say "  URL            : ${CFG[GATEKEEPER_PUBLIC_URL]}   (${CFG[GATEKEEPER_MODE]})"
  docker_up || say "  Docker         : ${C_RED}not running${C_RESET}"
  if [[ -d "$APP_DIR/.git" ]]; then
    say "  Version        : $(git -C "$APP_DIR" rev-parse --short HEAD 2>/dev/null) on $(git -C "$APP_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  fi
  for name in "$GK_CONTAINER" "$CADDY_CONTAINER"; do
    [[ "$name" == "$CADDY_CONTAINER" ]] && ! proxy_enabled && continue
    if docker inspect --type container "$name" >/dev/null 2>&1; then
      state="$(container_field "$name" '{{.State.Status}}')"
      health="$(container_field "$name" '{{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}}')"
      since="$(container_field "$name" '{{.State.StartedAt}}')"
      say "  $(printf '%-15s' "$([[ "$name" == "$CADDY_CONTAINER" ]] && echo 'HTTPS proxy' || echo 'Gatekeeper')"): $state ($health), up since ${since%%.*}, restarts: $(container_field "$name" '{{.RestartCount}}')"
    else
      say "  $(printf '%-15s' "$name"): ${C_RED}missing${C_RESET}"
    fi
  done
  hb="$(cat "$STATE_DIR/heartbeat" 2>/dev/null || echo 0)"
  if [[ "$hb" =~ ^[0-9]+$ ]] && (( hb > 0 )); then
    say "  Watchdog       : last ran $(human_age $(( $(date +%s) - hb ))) ago$([[ -f "$STATE_DIR/paused" ]] && echo " ${C_YELLOW}(PAUSED)${C_RESET}")"
  else
    say "  Watchdog       : ${C_RED}has not run${C_RESET}"
  fi
  newest="$(newest_backup)"
  if [[ -n "$newest" ]]; then
    say "  Last backup    : $(basename "$newest") ($(human_age $(( $(date +%s) - $(stat -c %Y "$newest") ))) ago)"
  else
    say "  Last backup    : none yet"
  fi
  say "  Disk free      : $(disk_free_mb /) MB"
  say ""
  say "  ${C_DIM}Run 'gatekeeper verify' for a full check.${C_RESET}"
}

cmd_secrets() {
  load_runtime_config
  sync_secret_files || die "Could not write the secret files."
  ok "Secret files in $APP_DIR/secrets are up to date with .env"
}

cmd_logs() {
  load_runtime_config
  require_docker
  local follow=() svc=() arg
  for arg in ${COMMAND_ARGS[@]+"${COMMAND_ARGS[@]}"}; do
    case "$arg" in
      -f|--follow) follow=(-f) ;;
      watchdog) tail -n 100 ${follow[@]+"${follow[@]}"} /var/log/ha-gatekeeper-watchdog.log; return 0 ;;
      caddy|gatekeeper) svc=("$arg") ;;
      *) die "Unknown logs argument '$arg'. Use: gatekeeper logs [-f] [gatekeeper|caddy|watchdog]" ;;
    esac
  done
  dc logs --tail 200 ${follow[@]+"${follow[@]}"} ${svc[@]+"${svc[@]}"}
}

cmd_start() {
  load_runtime_config
  require_docker start
  resume_watchdog
  sync_secret_files || die "Could not write the secret files."
  run_logged "Starting the containers" dc up -d --remove-orphans || die "Could not start the containers."
  if wait_for_container "$GK_CONTAINER" 120; then
    ok "Gatekeeper is running and healthy"
  else
    die "Gatekeeper did not become healthy: gatekeeper logs"
  fi
}

cmd_stop() {
  load_runtime_config
  require_docker
  pause_watchdog forever
  dc stop >>"$LOG_FILE" 2>&1 || true
  ok "Stopped. The watchdog is paused so it stays stopped, also after a reboot."
  hint "Bring it back with: gatekeeper start"
}

cmd_restart() {
  load_runtime_config
  require_docker
  resume_watchdog
  run_logged "Restarting the containers" dc restart || die "Restart failed."
  if wait_for_container "$GK_CONTAINER" 120; then
    ok "Gatekeeper is running and healthy"
  else
    die "Gatekeeper did not become healthy: gatekeeper logs"
  fi
}

prune_backups() {
  find "$APP_DIR/backups" -maxdepth 1 -name 'ha-gatekeeper-*.tar.gz' -printf '%T@ %p\n' 2>/dev/null \
    | sort -nr | tail -n +$((BACKUP_KEEP + 1)) | cut -d' ' -f2- \
    | while IFS= read -r f; do rm -f -- "$f"; done || true
}

cmd_backup() {
  load_runtime_config
  local ts dest tmp data snap running=false method="file copy"
  ts="$(date +%Y%m%d-%H%M%S)"
  data="$(data_dir_abs)"
  snap="$data/.backup-snapshot.db"
  dest="$APP_DIR/backups/ha-gatekeeper-$ts.tar.gz"

  mkdir -p "$APP_DIR/backups"
  chmod 700 "$APP_DIR/backups"
  tmp="$(mktemp -d "$APP_DIR/backups/.tmp.XXXXXX")"
  TMP_FILES+=("$tmp")

  [[ -f "$data/ha-gatekeeper.db" ]] || { warn "No database yet ($data/ha-gatekeeper.db); nothing to back up."; return 0; }

  if have docker && [[ "$(container_field "$GK_CONTAINER" '{{.State.Status}}' || true)" == running ]]; then running=true; fi
  rm -f "$snap"
  if $running && docker exec -e DB=/data/ha-gatekeeper.db -e OUT=/data/.backup-snapshot.db "$GK_CONTAINER" node --no-warnings -e '
      const { DatabaseSync } = require("node:sqlite");
      const db = new DatabaseSync(process.env.DB);
      db.exec("VACUUM INTO \x27" + process.env.OUT.replace(/\x27/g, "\x27\x27") + "\x27");
      db.close();' >>"$LOG_FILE" 2>&1 && [[ -s "$snap" ]]; then
    mv "$snap" "$tmp/ha-gatekeeper.db"
    method="consistent snapshot"
  else
    rm -f "$snap"
    $running && warn "Online snapshot failed; falling back to a plain file copy."
    cp -p "$data/ha-gatekeeper.db" "$tmp/ha-gatekeeper.db"
  fi

  cp -p "$APP_DIR/.env" "$tmp/dot-env"
  printf 'HA Gatekeeper backup\ncreated: %s\nmethod: %s\nversion: %s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$method" "$(git -C "$APP_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)" >"$tmp/manifest.txt"
  jpush "Created the backup $dest" rv_rm "$dest"
  tar -C "$tmp" -czf "$dest" ha-gatekeeper.db dot-env manifest.txt
  chmod 600 "$dest"
  rm -rf "$tmp"
  prune_backups
  ok "Backup written: $dest ($method, contains secrets: keep it private)"
}

cmd_restore() {
  load_runtime_config
  require_docker
  local file="${COMMAND_ARGS[0]:-}" tmp data ts
  [[ -n "$file" && -f "$file" ]] || die "Usage: gatekeeper restore /path/to/ha-gatekeeper-YYYYMMDD-HHMMSS.tar.gz  (see $APP_DIR/backups)"
  tmp="$(mktemp -d)"
  TMP_FILES+=("$tmp")
  tar -C "$tmp" -xzf "$file" || die "Could not read the backup archive."
  [[ -s "$tmp/ha-gatekeeper.db" ]] || die "That archive has no ha-gatekeeper.db."

  warn "This replaces the current database with the one in the backup."
  confirm_cmd "Continue?" n || die "Cancelled."

  data="$(data_dir_abs)"
  ts="$(date +%Y%m%d-%H%M%S)"
  pause_watchdog_for_maintenance
  dc stop gatekeeper >>"$LOG_FILE" 2>&1 || true
  [[ -f "$data/ha-gatekeeper.db" ]] && cp -p "$data/ha-gatekeeper.db" "$data/ha-gatekeeper.db.before-restore-$ts"
  rm -f "$data/ha-gatekeeper.db-journal"
  cp "$tmp/ha-gatekeeper.db" "$data/ha-gatekeeper.db"

  if [[ -f "$tmp/dot-env" ]]; then
    if $WITH_ENV || confirm "Also restore the saved .env (secrets and settings from that time)?" n; then
      cp -p "$APP_DIR/.env" "$APP_DIR/.env.before-restore-$ts"
      cp -p "$tmp/dot-env" "$APP_DIR/.env"
      chmod 600 "$APP_DIR/.env"
      ok "Restored .env (previous one kept as .env.before-restore-$ts)"
    fi
  fi
  fix_data_permissions
  sync_secret_files || die "Could not write the secret files."
  run_logged "Starting the containers" dc up -d --remove-orphans || die "Could not start the containers."
  wait_for_container "$GK_CONTAINER" 120 || die "Gatekeeper did not become healthy after the restore: gatekeeper logs"
  resume_watchdog
  WATCHDOG_PAUSED_BY_US=false
  ok "Restored from $(basename "$file"). The previous database was kept as ha-gatekeeper.db.before-restore-$ts"
}

rollback_update() { # rollback_update PREVIOUS_COMMIT LATEST_BACKUP
  local before="$1" backup="$2"
  warn "The new version did not start cleanly. Rolling back to the previous one..."
  git -C "$APP_DIR" reset --keep "$before" >>"$LOG_FILE" 2>&1 \
    || warn "Could not move the checkout back to $before; run: git -C $APP_DIR reset --keep $before"
  if docker image inspect ha-gatekeeper:previous >/dev/null 2>&1; then
    docker tag ha-gatekeeper:previous ha-gatekeeper:local
  fi
  dc up -d --no-build --force-recreate gatekeeper >>"$LOG_FILE" 2>&1 || true
  if wait_for_container "$GK_CONTAINER" 90; then
    ok "Rolled back: the previous version is running again."
    return 0
  fi
  if [[ -n "$backup" && -f "$backup" ]]; then
    warn "Still unhealthy: restoring the database from the pre-update backup as well."
    local tmp data
    tmp="$(mktemp -d)"; TMP_FILES+=("$tmp"); data="$(data_dir_abs)"
    tar -C "$tmp" -xzf "$backup" ha-gatekeeper.db 2>>"$LOG_FILE" && {
      dc stop gatekeeper >>"$LOG_FILE" 2>&1 || true
      rm -f "$data/ha-gatekeeper.db-journal"
      cp "$tmp/ha-gatekeeper.db" "$data/ha-gatekeeper.db"
      fix_data_permissions
      dc up -d --no-build gatekeeper >>"$LOG_FILE" 2>&1 || true
    }
    wait_for_container "$GK_CONTAINER" 90 && { ok "Rolled back, including the database."; return 0; }
  fi
  err "The rollback did not bring it back either. Details: gatekeeper logs"
  return 1
}

cmd_update() {
  load_runtime_config
  require_docker
  [[ -d "$APP_DIR/.git" ]] || die "Updating needs a git checkout ($APP_DIR is not one). Re-install with git clone, then run this again."

  local before after upstream latest_backup
  before="$(git -C "$APP_DIR" rev-parse HEAD)"
  pause_watchdog_for_maintenance

  if ! git -C "$APP_DIR" diff --quiet || ! git -C "$APP_DIR" diff --cached --quiet; then
    warn "You have local changes to tracked files. They are kept, but the update can fail to merge."
  fi

  info "Fetching the latest code"
  retry 3 5 git -C "$APP_DIR" fetch --quiet origin || die "git fetch failed (network?)"
  upstream="$(git -C "$APP_DIR" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
  if [[ -n "$upstream" ]]; then
    git -C "$APP_DIR" merge --ff-only "$upstream" >>"$LOG_FILE" 2>&1 \
      || die "Could not fast-forward to $upstream (local commits or changes in the way). Merge manually: git -C $APP_DIR pull"
  else
    warn "This checkout has no upstream branch, so there is nothing to pull."
  fi
  after="$(git -C "$APP_DIR" rev-parse HEAD)"

  if [[ "$before" == "$after" ]] && docker image inspect ha-gatekeeper:local >/dev/null 2>&1; then
    ok "Already up to date ($(git -C "$APP_DIR" rev-parse --short HEAD))."
    return 0
  fi

  say "Updating $(git -C "$APP_DIR" rev-parse --short "$before") -> $(git -C "$APP_DIR" rev-parse --short "$after")"
  git -C "$APP_DIR" log --oneline "$before..$after" 2>/dev/null | head -n 10 | sed 's/^/       /' || true

  cmd_backup
  latest_backup="$(newest_backup)"
  if docker image inspect ha-gatekeeper:local >/dev/null 2>&1; then
    docker tag ha-gatekeeper:local ha-gatekeeper:previous
  fi

  while IFS= read -r img; do
    [[ -n "$img" ]] && docker pull -q "$img" >>"$LOG_FILE" 2>&1 || true
  done < <(dockerfile_images)
  prepull_images || warn "Could not refresh base images; building with what is cached."

  if ! compose_build; then
    rollback_update "$before" "$latest_backup" || true
    die "The update failed while building. Nothing was changed on the running app."
  fi
  if ! start_stack; then
    rollback_update "$before" "$latest_backup" || true
    die "The update failed to start; the previous version was restored. Log: $LOG_FILE"
  fi

  QUICK=true
  local ok_flag=true
  verify_app_quick_ok || ok_flag=false
  if ! $ok_flag; then
    rollback_update "$before" "$latest_backup" || true
    die "The new version failed its health check; the previous version was restored."
  fi

  resume_watchdog
  WATCHDOG_PAUSED_BY_US=false
  ok "Updated to $(git -C "$APP_DIR" rev-parse --short HEAD) and healthy"
  say "  Full check: gatekeeper verify"
}

# A light post-update gate: health endpoint plus admin login, without the noisy full report.
verify_app_quick_ok() {
  local base rc=0
  base="$(local_url)"
  http_do GET "$base/healthz" "" && [[ "$LAST_BODY" == *'"ok":true'* ]] || return 1
  admin_login "$base" || rc=$?
  (( rc == 0 ))
}

cmd_uninstall() {
  [[ -f "$APP_DIR/.env" ]] && { cfg_defaults; cfg_load_file "$APP_DIR/.env"; derive_config; }
  say "This removes HA Gatekeeper's containers, systemd timers/services (or cron entry) and the 'gatekeeper' command."
  say "Docker itself, and your data unless you say so below, are left alone."
  confirm_cmd "Uninstall HA Gatekeeper?" n || die "Cancelled."

  if have_systemd; then
    systemctl disable --now ha-gatekeeper-watchdog.timer ha-gatekeeper-backup.timer >>"$LOG_FILE" 2>&1 || true
    systemctl disable ha-gatekeeper.service >>"$LOG_FILE" 2>&1 || true
    rm -f "$SYSTEMD_DIR"/ha-gatekeeper.service "$SYSTEMD_DIR"/ha-gatekeeper-watchdog.service \
      "$SYSTEMD_DIR"/ha-gatekeeper-watchdog.timer "$SYSTEMD_DIR"/ha-gatekeeper-backup.service \
      "$SYSTEMD_DIR"/ha-gatekeeper-backup.timer
    systemctl daemon-reload >>"$LOG_FILE" 2>&1 || true
    ok "Removed the systemd units"
  fi
  rm -f "$CRON_FILE"
  [[ -L "$BIN_LINK" ]] && rm -f "$BIN_LINK"

  if have docker && docker_up; then
    ( cd "$APP_DIR" && docker compose --profile proxy down --remove-orphans ) >>"$LOG_FILE" 2>&1 || true
    ok "Stopped and removed the containers"
    if confirm_purge "Also delete the built images?" n; then
      docker rmi ha-gatekeeper:local ha-gatekeeper:previous >>"$LOG_FILE" 2>&1 || true
    fi
    if confirm_purge "Also delete the saved HTTPS certificates (Let's Encrypt limits how often they can be re-issued)?" n; then
      docker volume rm "${CFG[COMPOSE_PROJECT_NAME]:-ha-gatekeeper}_caddy_data" "${CFG[COMPOSE_PROJECT_NAME]:-ha-gatekeeper}_caddy_config" >>"$LOG_FILE" 2>&1 || true
    fi
  fi

  if confirm_purge "Delete your DATA (database with all tokens and the audit log) in $(data_dir_abs)?" n; then
    rm -rf "$(data_dir_abs)"
    ok "Deleted the data folder"
  fi
  if confirm_purge "Delete $APP_DIR/.env (it holds the secrets)?" n; then
    rm -f "$APP_DIR/.env" "$APP_DIR/.env.previous"
  fi
  rm -f "$APP_DIR/gatekeeper-root-ca.crt"
  rm -rf "$APP_DIR/secrets"
  remove_firewall_rules
  local left=""
  if [[ -r "$STATE_DIR/changes.txt" ]]; then
    left="$(sed -n '/^--- left in place by uninstall:$/,$p' "$STATE_DIR/changes.txt" | sed '1d')"
  fi
  rm -rf "$STATE_DIR"
  ok "HA Gatekeeper is uninstalled. The code in $APP_DIR and the backups were left in place."
  say ""
  say "${C_BOLD}Not undone by uninstall${C_RESET} (installed or changed by the installer, possibly useful to other things here):"
  if [[ -n "$left" ]]; then
    while IFS= read -r line; do [[ -n "$line" ]] && say "   * $line"; done <<<"$left"
  else
    say "   * (nothing recorded: Docker and packages were already on this server, or were installed by an older installer)"
  fi
  say "   * base Docker images and Docker's build cache (docker image prune, docker builder prune)"
  say "   * the code and backups in $APP_DIR, and the log $REAL_LOG_FILE"
  say "   * a firewall (ufw) that was switched on, and its SSH rule: they keep protecting this server"
}

# -------------------------------------------------------------------------------------------------
# Entry point
# -------------------------------------------------------------------------------------------------

usage() {
  cat <<EOF
HA Gatekeeper installer and manager (v$GK_VERSION)

Usage: sudo ./install.sh [COMMAND] [OPTIONS]      (after install also:  gatekeeper COMMAND)

Commands
  install            Guided setup. The default. Safe to re-run: it repairs and re-applies everything.
  verify             Check that everything is running well.
  status             One-screen summary.
  update             Pull the latest code, back up, rebuild, restart, check (rolls back on failure).
  start | stop | restart
  logs [-f] [gatekeeper|caddy|watchdog]
  backup             Back up the database and .env into ./backups.
  restore FILE       Restore a backup made by 'backup'.
  uninstall          Remove services and containers (asks before touching data).
  help

Options
  -y, --yes, --non-interactive   Never ask; use the environment, --config and the existing .env. This also
                                 approves the list of changes shown by the installer.
  --config FILE                  Read answers from FILE (same KEY="value" format as .env).
  --reconfigure                  Ask everything again even if settings already exist.
  --dry-run                      (install) show the complete list of changes and stop; nothing is changed.
  --keep-on-failure              (install) do not undo a failed installation (for debugging).
  --quick                        (verify) skip the temporary-token write test.
  --drill / --no-drill           Force / skip the crash-recovery drill.
  --with-env                     (restore) also restore the saved .env without asking.
  --purge                        (uninstall --yes) also delete data, .env, images and certificates.
  --quiet                        Print only warnings and errors.
  -v, --verbose                  Show full output of long-running commands.
  --no-color                     Plain output.
  -h, --help                     This text.

Answers for non-interactive use can be given as environment variables (use sudo -E):
  HA_BASE_URL  HA_TOKEN  ADMIN_PASSWORD  GATEKEEPER_MODE (domain|selfsigned|local)
  GATEKEEPER_DOMAIN  ACME_EMAIL  ALERT_WEBHOOK_URL  ADMIN_ALLOWED_IPS  AUDIT_LOG_RETENTION_DAYS
  HA_CA_FILE (host path to the CA file for a private Home Assistant certificate)
  GATEKEEPER_PUBLIC_URL (private mode behind your own HTTPS web server, e.g. https://ha.example.com)
Safety switches (environment):
  GATEKEEPER_UFW=1|0           1: switch ufw on (SSH, 80, 443) without asking. 0: never touch the firewall.
  GATEKEEPER_SWAP=1|0          1: add a swap file on a small server without asking. 0: never.
  GATEKEEPER_START_DOCKER=1    allow starting a Docker service that is installed but stopped (unattended).
  GATEKEEPER_KEEP_ON_FAILURE=1 same as --keep-on-failure.
See deploy/env.example and docs/DEPLOY_VPS.md.
EOF
}

parse_args() {
  local arg have_command=false
  while (( $# )); do
    arg="$1"
    shift
    case "$arg" in
      -h|--help) COMMAND=help ;;
      -y|--yes|--non-interactive) NON_INTERACTIVE=true; ASSUME_YES=true ;;
      --purge) PURGE=true ;;
      --dry-run) DRY_RUN=true ;;
      --keep-on-failure) KEEP_ON_FAILURE=true ;;
      --config) [[ $# -gt 0 ]] || die "--config needs a file"; CONFIG_FILE="$1"; shift ;;
      --config=*) CONFIG_FILE="${arg#--config=}" ;;
      --reconfigure) RECONFIGURE=true ;;
      --quick) QUICK=true ;;
      --drill) DRILL=yes ;;
      --no-drill) DRILL=no ;;
      --with-env) WITH_ENV=true ;;
      --quiet) QUIET=true ;;
      -v|--verbose) VERBOSE=true ;;
      --no-color) NO_COLOR_FLAG=true ;;
      install|verify|status|update|start|stop|restart|logs|backup|restore|uninstall|secrets|help)
        if $have_command; then
          COMMAND_ARGS+=("$arg")
        else
          COMMAND="$arg"; have_command=true
        fi
        ;;
      -*)
        if [[ "$COMMAND" == logs ]]; then COMMAND_ARGS+=("$arg"); else die "Unknown option '$arg'. Try: ./install.sh --help"; fi
        ;;
      *) COMMAND_ARGS+=("$arg") ;;
    esac
  done
}

ensure_root() {
  [[ $EUID -eq 0 ]] && return 0
  if have sudo && [[ -n "$SELF_PATH" ]]; then
    echo "Not running as root: re-running with sudo..." >&2
    exec sudo -E bash "$SELF_PATH" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}
  fi
  echo "This installer must run as root. Use:  sudo ./install.sh   (or:  curl -fsSL <url> | sudo bash)" >&2
  exit 1
}

open_real_log() {
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
  if [[ -f "$LOG_FILE" && "$(stat -c %s "$LOG_FILE" 2>/dev/null || echo 0)" -gt 2097152 ]]; then
    mv -f "$LOG_FILE" "$LOG_FILE.1" 2>/dev/null || true
  fi
  ( umask 077; touch "$LOG_FILE" ) 2>/dev/null || LOG_FILE=/dev/null
}

init_logging() {
  REAL_LOG_FILE="$LOG_FILE"
  if [[ "$COMMAND" == install ]]; then
    # Nothing is written to /var/log until the user has approved the plan (a declined run or a
    # --dry-run leaves the server exactly as it was).
    PENDING_LOG="$(mktemp "${TMPDIR:-/tmp}/gk-install-log.XXXXXX" 2>/dev/null || true)"
    LOG_FILE="${PENDING_LOG:-/dev/null}"
    chmod 600 "$LOG_FILE" 2>/dev/null || true
  else
    open_real_log
  fi
  log_file "===== $COMMAND started (v$GK_VERSION) ====="
}

# The plan was approved: from now on the log lives in its real place.
adopt_real_log() {
  [[ -n "$PENDING_LOG" ]] || return 0
  local pending="$PENDING_LOG"
  PENDING_LOG=""
  LOG_FILE="$REAL_LOG_FILE"
  open_real_log
  if [[ "$LOG_FILE" != /dev/null ]]; then cat "$pending" >>"$LOG_FILE" 2>/dev/null || true; fi
  rm -f -- "$pending"
}

take_lock() {
  local lock="${GK_LOCK_FILE:-}" d
  if [[ -z "$lock" && -z "${GK_STATE_DIR:-}" ]]; then
    for d in /run/lock /var/lock /run; do
      if [[ -d "$d" && -w "$d" ]]; then lock="$d/ha-gatekeeper-install.lock"; break; fi
    done
  fi
  if [[ -z "$lock" ]]; then
    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR"
    lock="$STATE_DIR/install.lock"
  fi
  exec 200>"$lock"
  flock -n 200 || die "Another install/update/backup is already running. Wait for it to finish."
}

# Running from a checkout? Otherwise fetch one (this is the `curl ... | sudo bash` path).
bootstrap_repo() {
  if [[ -n "$SELF_DIR" && -f "$SELF_DIR/docker-compose.yml" && -f "$SELF_DIR/Dockerfile" && -f "$SELF_DIR/deploy/watchdog.sh" ]]; then
    APP_DIR="$SELF_DIR"
    return 0
  fi
  [[ -z "${GK_BOOTSTRAPPED:-}" ]] || die "Bootstrap failed: $INSTALL_DIR does not look like an HA Gatekeeper checkout."

  info "No checkout next to this script: fetching HA Gatekeeper ($REPO_BRANCH) into $INSTALL_DIR"
  local created_dir=false boot_pkgs=""
  [[ -e "$INSTALL_DIR" ]] || created_dir=true
  if ! have git; then
    INSTALL_ACTIVE=true
    consent_install_tools "Downloading HA Gatekeeper needs git." git || die "git is required (apt-get install git) to fetch HA Gatekeeper."
    if (( ${#J_FN[@]} > 0 )) && [[ "${J_FN[0]}" == rv_pkgs_since ]]; then
      boot_pkgs="${J_DESC[0]#Installed packages: }"
      cp -- "$JOURNAL_TMP/pkgs.0" "$JOURNAL_TMP/pkgs.boot"
    fi
  fi
  if [[ -d "$INSTALL_DIR/.git" ]]; then
    if ! { retry 3 5 git -C "$INSTALL_DIR" fetch --depth 1 origin "$REPO_BRANCH" </dev/null >>"$LOG_FILE" 2>&1 \
      && git -C "$INSTALL_DIR" checkout -q "$REPO_BRANCH" </dev/null >>"$LOG_FILE" 2>&1 \
      && git -C "$INSTALL_DIR" merge --ff-only FETCH_HEAD </dev/null >>"$LOG_FILE" 2>&1; }; then
      die "Could not update the existing checkout in $INSTALL_DIR. Try: git -C $INSTALL_DIR pull"
    fi
  else
    if [[ -e "$INSTALL_DIR" && -n "$(ls -A "$INSTALL_DIR" 2>/dev/null)" ]]; then
      die "$INSTALL_DIR already exists and is not an HA Gatekeeper checkout. Move it away or set GK_INSTALL_DIR."
    fi
    retry 3 5 git clone --depth 1 --branch "$REPO_BRANCH" "$REPO_URL" "$INSTALL_DIR" </dev/null >>"$LOG_FILE" 2>&1 \
      || die "Could not clone $REPO_URL (branch $REPO_BRANCH). Check the URL/branch (GK_REPO_URL, GK_BRANCH) and network."
  fi
  ok "Fetched HA Gatekeeper into $INSTALL_DIR"
  export GK_BOOTSTRAPPED=1
  # The new process starts with an empty journal: hand over what this one changed, so it can be undone.
  export GK_BOOT_TMP="$JOURNAL_TMP"
  [[ -z "$boot_pkgs" ]] || export GK_BOOT_PKGS="$boot_pkgs"
  ! $created_dir || export GK_BOOT_CREATED_DIR="$INSTALL_DIR"
  [[ -z "$PENDING_LOG" ]] || rm -f -- "$PENDING_LOG"
  exec bash "$INSTALL_DIR/install.sh" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}
}

main() {
  parse_args "$@"
  setup_colors
  if [[ "$COMMAND" == help ]]; then usage; exit 0; fi

  ensure_root
  # Never let a package prompt (needrestart, debconf, config-file questions) stop an unattended run.
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
  detect_os
  init_logging
  if ! have_tty && ! $NON_INTERACTIVE; then
    NON_INTERACTIVE=true
    log_file "no terminal available: running non-interactively"
  fi

  trap cleanup EXIT
  trap 'on_error $? $LINENO' ERR
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP

  # Created here, in the main shell (a first call inside $(...) would be lost).
  [[ "$COMMAND" == install ]] && journal_tmp >/dev/null

  bootstrap_repo
  # shellcheck source=deploy/lib.sh
  source "$APP_DIR/deploy/lib.sh"

  # Re-entered after the download step above: pick up what that step changed so it can be undone too.
  if [[ -n "${GK_BOOT_TMP:-}" && -d "${GK_BOOT_TMP:-}" ]]; then
    TMP_FILES+=("$GK_BOOT_TMP")
    if [[ -n "${GK_BOOT_PKGS:-}" ]]; then
      J_KEEP_NEXT=1 jpush "Installed packages: $GK_BOOT_PKGS" rv_pkgs_since "$GK_BOOT_TMP/pkgs.boot"
    fi
  fi
  if [[ -n "${GK_BOOT_CREATED_DIR:-}" ]]; then
    jpush "Downloaded HA Gatekeeper into $GK_BOOT_CREATED_DIR" rv_rmtree "$GK_BOOT_CREATED_DIR"
  fi

  case "$COMMAND" in
    install|update|backup|restore|start|stop|restart|uninstall|secrets) take_lock ;;
  esac

  case "$COMMAND" in
    install)   cmd_install ;;
    verify)    cmd_verify ;;
    status)    cmd_status ;;
    update)    cmd_update ;;
    start)     cmd_start ;;
    stop)      cmd_stop ;;
    restart)   cmd_restart ;;
    logs)      cmd_logs ;;
    backup)    cmd_backup ;;
    restore)   cmd_restore ;;
    uninstall) cmd_uninstall ;;
    secrets)   cmd_secrets ;;
    *)         usage; exit 1 ;;
  esac
}

if [[ -z "${GK_SOURCE_ONLY:-}" ]]; then
  main "$@"
fi
