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

TMP_FILES=()
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

cleanup() {
  local f
  for f in "${TMP_FILES[@]:-}"; do
    [[ -n "$f" ]] && rm -rf "$f" 2>/dev/null || true
  done
  if $WATCHDOG_PAUSED_BY_US; then
    resume_watchdog
  fi
}

MAIN_PID=$$

on_error() {
  local rc=$1 line=$2
  # Command substitutions and pipelines inherit this trap; only the main shell reports.
  [[ "$BASHPID" == "$MAIN_PID" ]] || return 0
  trap - ERR
  err "Stopped unexpectedly (exit code $rc, line $line)."
  hint "Nothing is half-installed in a way that blocks a retry: it is safe to run this script again."
  hint "Details: $LOG_FILE"
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
apt_lock_held() {
  have fuser || return 1
  fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock >/dev/null 2>&1
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
APT_LOCK_CONF=/etc/apt/apt.conf.d/99gatekeeper-lock
apt_lock_conf_on()  { [[ "$PKG" == apt ]] && printf 'DPkg::Lock::Timeout "300";\nAPT::Get::Assume-Yes "true";\n' >"$APT_LOCK_CONF" 2>/dev/null || true; }
apt_lock_conf_off() { rm -f "$APT_LOCK_CONF" 2>/dev/null || true; }

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

ensure_prereqs() {
  local need=()
  have curl    || need+=(curl)
  have openssl || need+=(openssl)
  have git     || need+=(git)
  have jq      || need+=(jq)
  have flock   || need+=(util-linux)
  have tar     || need+=(tar)
  have gzip    || need+=(gzip)
  [[ -e /etc/ssl/certs/ca-certificates.crt || -d /etc/pki/tls/certs || -e /etc/ssl/cert.pem ]] || need+=(ca-certificates)

  if (( ${#need[@]} == 0 )); then
    ok "Required tools present (curl, openssl, git, jq, flock, tar)"
    return 0
  fi

  info "Installing required tools: ${need[*]}"
  if ! pkg_install "${need[@]}"; then
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

ensure_swap() {
  local mem swap total size free path=/swapfile
  mem="$(mem_mb)"; swap="$(swap_mb)"; total=$((mem + swap))
  (( total >= 1800 )) && return 0

  warn "Only ${mem} MB RAM and ${swap} MB swap. Building the image can run out of memory on a server this small."
  if [[ -e "$path" ]]; then
    warn "$path already exists but is not active; leaving it alone."
    return 0
  fi

  size=$((2048 - total))
  (( size < 1024 )) && size=1024
  (( size > 2048 )) && size=2048
  free="$(disk_free_mb /)"
  if (( free < size + 2048 )); then
    warn "Not enough free disk (${free} MB) to add a ${size} MB swap file safely; skipping."
    return 0
  fi

  if ! confirm "Add a ${size} MB swap file so the build cannot run out of memory?" y; then
    warn "Skipping swap. If the build gets 'Killed', re-run and accept the swap file."
    return 0
  fi

  info "Creating a ${size} MB swap file at $path"
  if ! { fallocate -l "${size}M" "$path" 2>/dev/null || dd if=/dev/zero of="$path" bs=1M count="$size" status=none; }; then
    rm -f "$path"; warn "Could not create the swap file; continuing without it."; return 0
  fi
  chmod 600 "$path"
  if mkswap "$path" >>"$LOG_FILE" 2>&1 && swapon "$path" >>"$LOG_FILE" 2>&1; then
    grep -qs "^$path " /etc/fstab || printf '%s none swap sw 0 0\n' "$path" >>/etc/fstab
    ok "Swap enabled (${size} MB) and set to persist across reboots"
  else
    swapoff "$path" 2>/dev/null || true
    rm -f "$path"
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

gen_alnum() { # gen_alnum LENGTH
  local len="$1" raw=""
  while (( ${#raw} < len )); do
    raw+="$(openssl rand -base64 $((len * 3)) | tr -dc 'A-Za-z0-9')"
  done
  printf '%s' "${raw:0:len}"
}

# 32 random bytes, standard base64: what the README asks for (`openssl rand -base64 32`).
gen_session_secret() { openssl rand -base64 32 | tr -d '\n'; }
gen_hash_secret() { openssl rand -base64 48 | tr -d '\n' | tr '+/' '-_' | tr -d '='; }

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
  ADMIN_ALLOWED_IPS ALERT_WEBHOOK_URL GATEKEEPER_PORT GATEKEEPER_DATA_DIR
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

cfg_load_environment() {
  local key
  for key in "${ENV_ACCEPTED_KEYS[@]}"; do
    if [[ -n "${!key:-}" ]]; then
      CFG[$key]="${!key}"
    fi
  done
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
      CFG[TRUST_PROXY]=""
      CFG[GATEKEEPER_PUBLIC_URL]="http://localhost:$port"
      CFG[GATEKEEPER_DOMAIN]=""
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
  local file="$APP_DIR/.env" tmp key line extras=()
  if [[ -f "$file" ]]; then
    cp -p "$file" "$APP_DIR/.env.previous" 2>/dev/null || true
    chmod 600 "$APP_DIR/.env.previous" 2>/dev/null || true
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
  mv -f "$tmp" "$file"
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
  have docker || return 1
  docker inspect --type container --format '{{json .NetworkSettings.Ports}}' "$CADDY_CONTAINER" 2>/dev/null \
    | grep -q "\"$1/tcp\""
}

# -------------------------------------------------------------------------------------------------
# Docker and Docker Compose
# -------------------------------------------------------------------------------------------------

have_systemd() { have systemctl && [[ -d /run/systemd/system ]]; }
docker_ready() { timeout 20 docker info >/dev/null 2>&1; }
compose_ok() { docker compose version >/dev/null 2>&1; }

compose_version_ok() {
  local v major
  v="$(docker compose version --short 2>/dev/null || true)"
  v="${v#v}"
  major="${v%%.*}"
  [[ "$major" =~ ^[0-9]+$ ]] && (( major >= 2 ))
}

install_docker() {
  local script
  script="$(mktemp_tracked)"
  info "Installing Docker Engine (official installer from get.docker.com)"
  if ! retry 3 5 curl -fsSL --connect-timeout 10 --max-time 90 https://get.docker.com -o "$script"; then
    err "Could not download the Docker installer from get.docker.com"
    return 1
  fi
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
  pkg_install docker-compose-plugin >/dev/null 2>&1 || pkg_install docker-compose-v2 >/dev/null 2>&1 || true
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
  mkdir -p "$dest"
  info "Downloading the Docker Compose plugin from GitHub"
  retry 3 5 curl -fsSL --connect-timeout 10 --max-time 180 -o "$dest/docker-compose" "$url" \
    || die "Could not download Docker Compose from $url"
  chmod +x "$dest/docker-compose"
  if ! compose_ok || ! compose_version_ok; then
    die "Docker Compose still does not work after installing it. See $LOG_FILE"
  fi
  ok "Docker Compose $(docker compose version --short 2>/dev/null) installed"
}

ensure_docker() {
  if have docker; then
    ok "Docker found: $(docker --version 2>/dev/null | head -n 1)"
  else
    have curl || die "curl is required to install Docker"
    install_docker || die "Docker could not be installed automatically. Install Docker Engine (https://docs.docker.com/engine/install/) and re-run this script."
    have docker || die "Docker was installed but the 'docker' command is not on PATH."
    ok "Docker installed"
  fi
  DOCKER_BIN="$(command -v docker)"
  start_docker
  ensure_compose

  if have_systemd; then
    if systemctl is-enabled docker >/dev/null 2>&1; then
      ok "Docker starts automatically at boot"
    elif systemctl enable docker >>"$LOG_FILE" 2>&1; then
      ok "Enabled Docker at boot"
    else
      warn "Could not enable Docker at boot (systemctl enable docker failed)."
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
  if docker image inspect "$image" >/dev/null 2>&1; then
    log_file "image already present: $image"
    return 0
  fi
  if retry 3 6 docker pull -q "$image" >>"$LOG_FILE" 2>&1; then
    return 0
  fi

  first="${image%%/*}"
  if [[ "$image" == */* && ( "$first" == *.* || "$first" == *:* ) ]]; then
    return 1 # not a Docker Hub image: no mirror to try
  fi
  name="$image"
  [[ "$image" == */* ]] || name="library/$image"
  for mirror in mirror.gcr.io public.ecr.aws/docker; do
    warn "Pulling $image from Docker Hub failed; trying $mirror"
    if docker pull -q "$mirror/$name" >>"$LOG_FILE" 2>&1 && docker tag "$mirror/$name" "$image"; then
      ok "Got $image via $mirror"
      return 0
    fi
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
  mkdir -p "$data"
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
  local attempt
  for attempt in 1 2; do
    if run_logged "Starting the containers" dc up -d --remove-orphans; then
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
  mkdir -p "$dir"
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
    mv -f "$tmp" "$dir/Caddyfile"
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

# Home Assistant on this same server: the container reaches it through the Docker bridge, which
# a default-deny host firewall blocks. Allow just that port from the Docker networks.
ha_local_port() {
  [[ "$(url_host "${CFG[HA_BASE_URL]:-}")" == host.docker.internal ]] || return 1
  local port
  port="$(url_port "${CFG[HA_BASE_URL]}")"
  [[ -n "$port" ]] || { [[ "$(url_scheme "${CFG[HA_BASE_URL]}")" == https ]] && port=443 || port=80; }
  printf '%s' "$port"
}

maybe_enable_ufw() {
  have ufw || return 0
  ufw_active && return 0
  [[ "${CFG[GATEKEEPER_MODE]}" == local ]] && return 0
  local ports p
  ports="$(ssh_ports)"
  if [[ -z "$ports" ]]; then
    hint "The host firewall (ufw) is off. It could not be enabled safely because the SSH port could not be detected."
    return 0
  fi
  if [[ "${GATEKEEPER_UFW:-}" == 0 ]]; then return 0; fi
  if [[ "${GATEKEEPER_UFW:-}" != 1 ]]; then
    interactive || return 0
    say "  The server firewall (ufw) is switched off, so anything else listening on this server is reachable."
    say "  ${C_DIM}I can turn it on allowing only: SSH (port $ports), 80, 443. Other services on this server would be blocked.${C_RESET}"
    confirm "Turn the firewall on now?" y || return 0
  fi
  for p in $ports; do ufw allow "$p/tcp" comment 'SSH (HA Gatekeeper installer)' >>"$LOG_FILE" 2>&1 || return 0; done
  ufw allow 80/tcp comment 'HA Gatekeeper HTTP' >>"$LOG_FILE" 2>&1 || true
  ufw allow 443/tcp comment 'HA Gatekeeper HTTPS' >>"$LOG_FILE" 2>&1 || true
  ufw allow 443/udp comment 'HA Gatekeeper HTTP/3' >>"$LOG_FILE" 2>&1 || true
  if ufw --force enable >>"$LOG_FILE" 2>&1; then
    ok "Firewall (ufw) enabled: SSH ($ports), 80 and 443 allowed"
  else
    warn "Could not enable ufw."
  fi
}

open_firewall() {
  local touched=false hp
  hp="$(ha_local_port || true)"

  if [[ "${CFG[GATEKEEPER_MODE]}" != local ]]; then
    maybe_enable_ufw
    if ufw_active; then
      if ufw allow 80/tcp comment 'HA Gatekeeper HTTP' >>"$LOG_FILE" 2>&1 \
        && ufw allow 443/tcp comment 'HA Gatekeeper HTTPS' >>"$LOG_FILE" 2>&1 \
        && ufw allow 443/udp comment 'HA Gatekeeper HTTP/3' >>"$LOG_FILE" 2>&1; then
        ok "ufw firewall: opened ports 80 and 443"
      else
        warn "Could not add ufw rules. Run: ufw allow 80/tcp && ufw allow 443/tcp && ufw allow 443/udp"
      fi
      touched=true
    fi
    if firewalld_active; then
      if firewall-cmd --permanent --add-service=http --add-service=https >>"$LOG_FILE" 2>&1 \
        && firewall-cmd --permanent --add-port=443/udp >>"$LOG_FILE" 2>&1 \
        && firewall-cmd --reload >>"$LOG_FILE" 2>&1; then
        ok "firewalld: opened http/https"
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
      if ufw allow from 172.16.0.0/12 to any port "$hp" proto tcp comment 'HA Gatekeeper -> Home Assistant' >>"$LOG_FILE" 2>&1; then
        ok "ufw: let the Gatekeeper container reach Home Assistant on port $hp (Docker networks only)"
      else
        warn "Could not add the ufw rule. Run: ufw allow from 172.16.0.0/12 to any port $hp proto tcp"
      fi
    fi
    if firewalld_active; then
      if firewall-cmd --permanent --add-rich-rule="rule family=ipv4 source address=172.16.0.0/12 port port=$hp protocol=tcp accept" >>"$LOG_FILE" 2>&1 \
        && firewall-cmd --reload >>"$LOG_FILE" 2>&1; then
        ok "firewalld: let the Gatekeeper container reach Home Assistant on port $hp"
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
  local path="$SYSTEMD_DIR/$1"
  cat >"$path.tmp"
  mv -f "$path.tmp" "$path"
  chmod 644 "$path"
}

install_systemd_units() {
  if [[ "$APP_DIR" =~ [[:space:]\"\'\\%$] ]]; then
    die "The install path must not contain spaces or special characters: $APP_DIR"
  fi
  mkdir -p "$SYSTEMD_DIR"

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
    pkg_install cron >/dev/null 2>&1 || pkg_install cronie >/dev/null 2>&1 || true
  fi
  if [[ ! -d "$dir" ]]; then
    warn "There is neither systemd nor cron, so the watchdog cannot be scheduled automatically."
    hint "Run it every minute yourself: $APP_DIR/deploy/watchdog.sh"
    return 1
  fi

  cat >"$CRON_FILE" <<EOF
# HA Gatekeeper: watchdog every minute, start at boot, daily backup. Managed by install.sh.
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
* * * * * root $APP_DIR/deploy/watchdog.sh >/dev/null 2>&1
@reboot root sleep 30 && cd $APP_DIR && $DOCKER_BIN compose up -d --remove-orphans >/dev/null 2>&1
30 3 * * * root $APP_DIR/install.sh backup --quiet >/dev/null 2>&1
EOF
  chmod 644 "$CRON_FILE"

  if have service; then
    service cron start >>"$LOG_FILE" 2>&1 || service crond start >>"$LOG_FILE" 2>&1 || true
  fi
  ok "cron: watchdog every minute, start at boot, daily backup ($CRON_FILE)"
}

install_automation() {
  chmod +x "$APP_DIR/install.sh" "$APP_DIR/deploy/watchdog.sh"
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"

  if have_systemd; then
    rm -f "$CRON_FILE" 2>/dev/null || true
    install_systemd_units
  else
    install_cron_fallback || true
  fi

  if ln -sf "$APP_DIR/install.sh" "$BIN_LINK" 2>/dev/null; then
    ok "Installed the 'gatekeeper' command ($BIN_LINK): try  gatekeeper status"
  else
    warn "Could not create $BIN_LINK; run $APP_DIR/install.sh directly."
  fi
}

# -------------------------------------------------------------------------------------------------
# Verification: is everything actually running well?
# -------------------------------------------------------------------------------------------------

V_PASS=0
V_WARN=0
V_FAIL=0
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
  if docker_ready; then
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
    fetch(base + "/api/config", { headers: { Authorization: "Bearer " + process.env.HA_TOKEN }, signal: AbortSignal.timeout(15000) })
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
      ECONNREFUSED)        vfail "Home Assistant refused the connection from the container" "Wrong port, or HA only listens on localhost. If HA runs on this server it must listen on 0.0.0.0 and the firewall must allow the Docker network (ufw allow from 172.16.0.0/12 to any port 8123)." ;;
      ETIMEDOUT|UND_ERR_CONNECT_TIMEOUT|TimeoutError)
        if [[ "$(url_host "${CFG[HA_BASE_URL]:-}")" == host.docker.internal ]]; then
          vfail "Timed out reaching Home Assistant on this server from the container" "A host firewall is probably blocking the Docker network: ufw allow from 172.16.0.0/12 to any port $(ha_local_port || echo 8123) proto tcp (re-running the installer adds this for you)."
        else
          vfail "Timed out reaching Home Assistant from the container" "Home LAN addresses are unreachable from a VPS without a VPN (Tailscale/WireGuard); for a public address check the port is open to this server."
        fi ;;
      *CERT*|*SELF_SIGNED*|*certificate*) vfail "TLS certificate problem talking to Home Assistant ($why)" "Provide the CA file for a private certificate: sudo $APP_DIR/install.sh --reconfigure (advanced options)." ;;
      *) vfail "Container could not reach Home Assistant (${why:-no details})" "gatekeeper logs" ;;
    esac
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
    hint "Something other than Caddy answered on port 80. Stop any other web server (nginx/apache) using ports 80/443."
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
    vfail "HTTPS does not work yet for $host (${LAST_ERR:-HTTP $LAST_CODE})" "The app itself is fine; the proxy has no certificate."
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
  (( V_FAIL == 0 ))
}

verify_all() { # verify_all [with-drill]
  V_PASS=0; V_WARN=0; V_FAIL=0
  local drill="${1:-}"
  verify_host
  verify_docker || { verify_summary || true; return 1; }
  verify_containers
  verify_app
  if proxy_enabled; then verify_public; fi
  verify_automation
  verify_data
  if [[ "$drill" == with-drill ]]; then run_drill; fi
  verify_summary
}

# -------------------------------------------------------------------------------------------------
# Guided configuration
# -------------------------------------------------------------------------------------------------

PUBLIC_IPV4=""
FRESH_INSTALL=true

container_publishes_host_port() { # container_publishes_host_port NAME PORT
  have docker || return 1
  docker inspect --type container --format '{{json .NetworkSettings.Ports}}' "$1" 2>/dev/null \
    | grep -q "\"HostPort\":\"$2\""
}

pick_app_port() {
  local p="${CFG[GATEKEEPER_PORT]:-8080}" tries=0 owner
  while port_in_use "$p" && ! container_publishes_host_port "$GK_CONTAINER" "$p"; do
    owner="$(port_owner "$p" || true)"
    warn "Local port $p is already in use${owner:+ by $owner}; trying the next one."
    p=$((p + 1))
    tries=$((tries + 1))
    (( tries < 50 )) || die "Could not find a free local port near ${CFG[GATEKEEPER_PORT]}."
  done
  CFG[GATEKEEPER_PORT]="$p"
}

check_web_ports() {
  proxy_enabled || return 0
  local p owner bad=false
  for p in 80 443; do
    if port_in_use "$p" && ! stack_publishes_port "$p"; then
      owner="$(port_owner "$p" || true)"
      err "Port $p is already in use${owner:+ by $owner}. HTTPS needs ports 80 and 443."
      bad=true
    fi
  done
  if $bad; then
    hint "Free them (for example: systemctl disable --now nginx apache2 caddy) and re-run, or pick the private SSH-tunnel option."
    return 1
  fi
  ok "Ports 80 and 443 are free for the HTTPS proxy"
}

install_ha_ca() { # install_ha_ca HOSTFILE
  local src="$1"
  if ! openssl x509 -in "$src" -noout >/dev/null 2>&1; then
    err "$src is not a PEM-encoded certificate."
    return 1
  fi
  mkdir -p "$APP_DIR/deploy/certs"
  install -m 644 "$src" "$APP_DIR/deploy/certs/ha-ca.pem"
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
  local ip choice default cur="${CFG[GATEKEEPER_MODE]:-}"
  ip="$(public_ip 4 || true)"
  PUBLIC_IPV4="$ip"
  case "$cur" in domain) default=1 ;; selfsigned) default=2 ;; local) default=3 ;; *) default=2 ;; esac

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
  say "  ${C_DIM}Not sure? Choose 2: it works immediately with just the server's IP address. You can switch to a${C_RESET}"
  say "  ${C_DIM}domain later by running  sudo gatekeeper install --reconfigure .${C_RESET}"
  say ""
  while true; do
    choice="$(ask "Choose 1, 2 or 3" "$default")"
    case "$choice" in
      1) CFG[GATEKEEPER_MODE]=domain; return ;;
      2) CFG[GATEKEEPER_MODE]=selfsigned; return ;;
      3) CFG[GATEKEEPER_MODE]=local; return ;;
    esac
    warn "Please type 1, 2 or 3."
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
    *) printf 'private: only on this server (127.0.0.1:%s), reached through an SSH tunnel' "${CFG[GATEKEEPER_PORT]}" ;;
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
  esac
  wizard_home_assistant
  wizard_admin_password
  if confirm "Configure advanced options (alerts, admin IP allow-list, log retention)?" n; then
    wizard_advanced
  fi
  ensure_secrets
  derive_config
  show_settings
  say ""
  confirm "Install with these settings?" y || die "Cancelled. Nothing was changed."
}

# Non-interactive: everything comes from --config, environment variables, the existing .env and defaults.
noninteractive_config() {
  local problems
  if [[ -z "${CFG[GATEKEEPER_MODE]:-}" ]]; then
    if is_domain "${CFG[GATEKEEPER_DOMAIN]:-}"; then CFG[GATEKEEPER_MODE]=domain; else CFG[GATEKEEPER_MODE]=local; fi
  fi
  if [[ "${CFG[GATEKEEPER_MODE]}" == selfsigned && -z "${CFG[GATEKEEPER_DOMAIN]:-}" ]]; then
    PUBLIC_IPV4="$(public_ip 4 || true)"
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
  elif ha_probe "$(ha_url_for_host_test "${CFG[HA_BASE_URL]}")" "${CFG[HA_TOKEN]}" "$(ha_ca_hostfile)"; then
    ok "Home Assistant ${HA_VERSION:-?}${HA_LOCATION:+ (\"$HA_LOCATION\")} is reachable and the token works"
  else
    ha_explain_failure "${CFG[HA_BASE_URL]}"
    die "Cannot continue without a working Home Assistant connection. (Set GK_SKIP_HA_CHECK=1 to override.)"
  fi

  if [[ "${CFG[GATEKEEPER_MODE]}" == domain ]]; then dns_check "${CFG[GATEKEEPER_DOMAIN]}"; fi
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
  pick_app_port
  check_web_ports || die "Cannot start the HTTPS proxy while those ports are taken."
  write_env_file
  chmod 700 "$STATE_DIR" 2>/dev/null || true
  mkdir -p "$APP_DIR/backups" "$APP_DIR/deploy/certs" "$APP_DIR/deploy/caddy"
  chmod 700 "$APP_DIR/backups"
  fix_data_permissions
  ok "Settings saved to $APP_DIR/.env (private, mode 600)"

  prepull_images || die "Could not download the required container images."
  write_caddyfile || die "Could not create a valid Caddy configuration."
  compose_build || die "The image build failed. Full log: $LOG_FILE"

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
      ip="$(public_ip 4 || echo '<server-ip>')"
      say ""
      say "  Private mode: nothing is exposed. From your own computer run:"
      say "      ${C_BOLD}ssh -L ${CFG[GATEKEEPER_PORT]}:127.0.0.1:${CFG[GATEKEEPER_PORT]} root@${ip}${C_RESET}"
      say "  and open http://localhost:${CFG[GATEKEEPER_PORT]}  ${C_DIM}(Chrome, Firefox or Edge; Safari refuses secure cookies on plain-HTTP localhost)${C_RESET}"
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

cmd_install() {
  banner "HA Gatekeeper installer  v$GK_VERSION"
  say "  Sets up HA Gatekeeper in Docker on this server: guided settings, HTTPS, automatic restarts,"
  say "  a watchdog, backups, and a full health check at the end. Safe to re-run at any time."
  say "  Log: $LOG_FILE"

  step 1 6 "Checking this server"
  ensure_prereqs
  check_resources
  check_internet
  ensure_swap

  step 2 6 "Docker"
  ensure_docker

  step 3 6 "Configuration"
  configure

  step 4 6 "Building and starting"
  apply_and_start

  step 5 6 "Automatic restarts, watchdog and firewall"
  install_automation
  if [[ "${CFG[GATEKEEPER_MODE]}" == local ]]; then remove_firewall_rules; fi
  open_firewall
  cmd_backup || warn "The first backup did not complete; run: gatekeeper backup"

  step 6 6 "Verifying everything"
  JUST_INSTALLED=true
  local drill=""
  should_drill && drill=with-drill
  local verified=true
  verify_all "$drill" || verified=false

  if $verified; then print_summary; else print_summary failed; fi
  $verified || { warn "Some checks failed (see above). Fix them and run:  gatekeeper verify"; exit 1; }
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

require_docker() {
  have docker || die "Docker is not installed. Run: sudo $APP_DIR/install.sh"
  DOCKER_BIN="$(command -v docker)"
  start_docker
}

cmd_verify() {
  load_runtime_config
  require_docker
  banner "HA Gatekeeper health check"
  local drill=""
  [[ "$DRILL" == yes ]] && drill=with-drill
  verify_all "$drill"
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
  require_docker
  local name state health since hb newest
  banner "HA Gatekeeper status"
  say "  URL            : ${CFG[GATEKEEPER_PUBLIC_URL]}   (${CFG[GATEKEEPER_MODE]})"
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
  require_docker
  resume_watchdog
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

  if have docker && docker_ready; then
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
  remove_firewall_rules
  rm -rf "$STATE_DIR"
  ok "HA Gatekeeper is uninstalled. The code in $APP_DIR and the backups were left in place."
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
  -y, --yes, --non-interactive   Never ask; use the environment, --config and the existing .env.
  --config FILE                  Read answers from FILE (same KEY="value" format as .env).
  --reconfigure                  Ask everything again even if settings already exist.
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
      install|verify|status|update|start|stop|restart|logs|backup|restore|uninstall|help)
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

init_logging() {
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
  if [[ -f "$LOG_FILE" && "$(stat -c %s "$LOG_FILE" 2>/dev/null || echo 0)" -gt 2097152 ]]; then
    mv -f "$LOG_FILE" "$LOG_FILE.1" 2>/dev/null || true
  fi
  ( umask 077; touch "$LOG_FILE" ) 2>/dev/null || LOG_FILE=""
  log_file "===== $COMMAND started (v$GK_VERSION) ====="
}

take_lock() {
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"
  exec 200>"$STATE_DIR/install.lock"
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
  have git || pkg_install git || die "git is required (apt-get install git) to fetch HA Gatekeeper."
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
  exec bash "$INSTALL_DIR/install.sh" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}
}

main() {
  parse_args "$@"
  setup_colors
  if [[ "$COMMAND" == help ]]; then usage; exit 0; fi

  ensure_root
  detect_os
  init_logging
  if ! have_tty && ! $NON_INTERACTIVE; then
    NON_INTERACTIVE=true
    log_file "no terminal available: running non-interactively"
  fi

  bootstrap_repo
  # shellcheck source=deploy/lib.sh
  source "$APP_DIR/deploy/lib.sh"

  trap cleanup EXIT
  trap 'on_error $? $LINENO' ERR

  case "$COMMAND" in
    install|update|backup|restore|start|stop|restart|uninstall) take_lock ;;
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
    *)         usage; exit 1 ;;
  esac
}

if [[ -z "${GK_SOURCE_ONLY:-}" ]]; then
  main "$@"
fi
