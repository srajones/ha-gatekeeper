#!/usr/bin/env bash
# Offline tests for the change journal and automatic rollback in install.sh.
# Every case runs install.sh's real functions in a fresh process, against a throw-away fake root
# and stub system commands (apt-get, dpkg-query, ufw, systemctl, swap tools). Nothing real is touched.
#   Run: bash deploy/tests/rollback.test.sh
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ROOT="$(mktemp -d)"
trap '[[ -n "${KEEP_ROOT:-}" ]] || rm -rf "$ROOT"' EXIT
pass=0; failn=0

ck() { # ck "name" command...   (success = pass)
  local name="$1"
  shift
  if "$@"; then pass=$((pass + 1)); else failn=$((failn + 1)); echo "  FAIL: $name"; fi
}
t() { # t "name" expected actual
  if [[ "$2" == "$3" ]]; then pass=$((pass + 1)); else failn=$((failn + 1)); echo "  FAIL: $1"; echo "     want: [$2]"; echo "      got: [$3]"; fi
}

# ---------------------------------------------------------------------------------- stub commands
SHIM="$ROOT/shim"
mkdir -p "$SHIM"

cat >"$SHIM/dpkg-query" <<'EOF'
#!/usr/bin/env bash
while read -r p; do [[ -n "$p" ]] && echo "ii  $p"; done <"$FAKE/pkgs"
exit 0
EOF

cat >"$SHIM/apt-get" <<'EOF'
#!/usr/bin/env bash
echo "apt-get $*" >>"$FAKE/calls"
sim=false; mode=""; pkgs=()
for a in "$@"; do
  case "$a" in
    -s) sim=true ;;
    install) mode=install ;;
    remove) mode=remove ;;
    -*|*=*|update) ;;
    *) pkgs+=("$a") ;;
  esac
done
if [[ "$mode" == install ]]; then
  [[ -f "$FAKE/apt-fails" ]] && exit 100
  for p in "${pkgs[@]}"; do
    grep -qxF "$p" "$FAKE/pkgs" || echo "$p" >>"$FAKE/pkgs"
    if [[ -f "$FAKE/deps" ]]; then
      for d in $(awk -F: -v p="$p" '$1 == p {gsub(",", " ", $2); print $2}' "$FAKE/deps"); do
        grep -qxF "$d" "$FAKE/pkgs" || echo "$d" >>"$FAKE/pkgs"
      done
    fi
  done
  exit 0
fi
if [[ "$mode" == remove ]]; then
  if $sim; then
    for p in "${pkgs[@]}"; do echo "Remv $p [1.0]"; done
    [[ -f "$FAKE/extra-remove" ]] && echo "Remv $(cat "$FAKE/extra-remove") [1.0]"
    exit 0
  fi
  for p in "${pkgs[@]}"; do grep -vxF "$p" "$FAKE/pkgs" >"$FAKE/pkgs.new" || true; mv "$FAKE/pkgs.new" "$FAKE/pkgs"; done
fi
exit 0
EOF

cat >"$SHIM/ufw" <<'EOF'
#!/usr/bin/env bash
echo "ufw $*" >>"$FAKE/calls"
strip() { local out=() skip=false w; for w in "$@"; do if [[ "$w" == comment ]]; then skip=true; continue; fi; $skip || out+=("$w"); done; echo "${out[*]}"; }
case "$1 $2" in
  "status numbered") exit 0 ;;
  "show added")
    echo "Added user rules (see 'ufw status' for running firewall):"
    [[ -f "$FAKE/ufw.rules" ]] && sed 's/^/ufw /' "$FAKE/ufw.rules"
    exit 0 ;;
esac
case "$1" in
  status) [[ -f "$FAKE/ufw.active" ]] && echo "Status: active" || echo "Status: inactive"; exit 0 ;;
  allow) shift; echo "allow $(strip "$@")" >>"$FAKE/ufw.rules"; exit 0 ;;
  --force)
    case "$2" in
      enable) touch "$FAKE/ufw.active" ;;
      disable) rm -f "$FAKE/ufw.active" ;;
      delete) shift 2; spec="$(strip "$@")"; grep -vxF "$spec" "$FAKE/ufw.rules" >"$FAKE/ufw.new" || true; mv "$FAKE/ufw.new" "$FAKE/ufw.rules" ;;
    esac
    exit 0 ;;
esac
exit 0
EOF

cat >"$SHIM/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >>"$FAKE/calls"
quiet=false; args=()
for a in "$@"; do case "$a" in --quiet|--now|--permanent) [[ "$a" == --quiet ]] && quiet=true ;; *) args+=("$a") ;; esac; done
cmd="${args[0]:-}"; units=("${args[@]:1}")
case "$cmd" in
  is-enabled) grep -qxF "${units[0]}" "$FAKE/enabled" 2>/dev/null; exit $? ;;
  is-active) grep -qxF "${units[0]}" "$FAKE/active" 2>/dev/null; exit $? ;;
  enable) for u in "${units[@]}"; do grep -qxF "$u" "$FAKE/enabled" 2>/dev/null || echo "$u" >>"$FAKE/enabled"; done ;;
  disable) for u in "${units[@]}"; do grep -vxF "$u" "$FAKE/enabled" >"$FAKE/enabled.new" 2>/dev/null || true; mv "$FAKE/enabled.new" "$FAKE/enabled"; done ;;
  cat) exit 1 ;;
esac
exit 0
EOF

for c in fallocate mkswap swapon swapoff; do
  cat >"$SHIM/$c" <<'EOF'
#!/usr/bin/env bash
echo "$(basename "$0") $*" >>"$FAKE/calls"
if [[ "$(basename "$0")" == fallocate ]]; then : >"${@: -1}"; fi
exit 0
EOF
done
chmod +x "$SHIM"/*

# ------------------------------------------------------------------------------------ test runner
# run_case NAME 'body'  -> runs body in a fresh shell with install.sh loaded; sets $T, $FAKE; echoes its exit status.
run_case() {
  local name="$1" body="$2"
  T="$ROOT/case-$name"
  FAKE="$T/fake"
  rm -rf "$T"
  mkdir -p "$T/app/deploy" "$T/state" "$T/bin" "$T/cron.d" "$FAKE"
  : >"$FAKE/pkgs"; : >"$FAKE/calls"
  CASE_OUT="$T/out.txt"
  (
    export T FAKE REPO SHIM
    export PATH="$SHIM:$PATH"
    export GK_SOURCE_ONLY=1 GK_LOG_FILE="$T/install.log" GK_STATE_DIR="$T/state" GK_SYSTEMD_DIR="$T/systemd"
    export GK_CRON_FILE="$T/cron.d/ha-gatekeeper" GK_BIN_LINK="$T/bin/gatekeeper" GK_SWAP_FILE="$T/swapfile"
    export GK_FSTAB_FILE="$T/fstab" GK_APT_CONF="$T/apt.conf" GK_WATCHDOG_LOG="$T/watchdog.log"
    # shellcheck disable=SC1091
    source "$REPO/install.sh"
    set -Eeuo pipefail
    trap cleanup EXIT
    trap 'on_error $? $LINENO' ERR
    APP_DIR="$T/app"; LOG_FILE="$T/install.log"; REAL_LOG_FILE="$T/install.log"; PKG=apt
    MAIN_PID=$BASHPID
    NO_COLOR_FLAG=true; setup_colors
    have_systemd() { return 0; }
    journal_tmp >/dev/null
    eval "$body"
  ) >"$CASE_OUT" 2>&1
  CASE_RC=$?
}
out_has() { grep -qF -- "$1" "$CASE_OUT"; }
calls_have() { grep -qF -- "$1" "$FAKE/calls"; }
calls_lack() { ! grep -qF -- "$1" "$FAKE/calls"; }

# ============================================================================== files and folders
echo "files and folders: new things are removed, replaced things come back, existing things stay"
mkdir -p "$ROOT/pre"
run_case files '
  mkdir -p "$T/keep/sub"
  printf old >"$T/existing.txt"
  printf same >"$T/identical.txt"
  INSTALL_ACTIVE=true
  src="$(mktemp)"
  printf new >"$src";  jx_install_file "$src" "$T/existing.txt" 644
  printf same >"$src"; jx_install_file "$src" "$T/identical.txt" 644
  printf hello >"$src"; jx_install_file "$src" "$T/created.txt" 600
  jx_mkdir "$T/keep/sub/a/b/c"
  jx_mkdir "$T/keep/sub"
  [[ "$(cat "$T/existing.txt")" == new && -f "$T/created.txt" && -d "$T/keep/sub/a/b/c" ]] || exit 40
  [[ "$(stat -c %a "$T/created.txt")" == 600 ]] || exit 41
  echo "journal-entries: $(journal_list | wc -l)"
  exit 3
'
t "failure exit code is preserved" 3 "$CASE_RC"
t "existing file restored" old "$(cat "$T/existing.txt")"
t "identical file untouched" same "$(cat "$T/identical.txt")"
ck "new file removed" test ! -e "$T/created.txt"
ck "new folders removed" test ! -e "$T/keep/sub/a"
ck "pre-existing folder kept" test -d "$T/keep/sub"
ck "identical file was not journaled (3 entries: replaced + created + 3 folders = 5)" out_has "journal-entries: 5"
ck "rollback prints each undo" out_has "[undone]"

echo "a successful run (INSTALL_ACTIVE=false) and --keep-on-failure are never rolled back"
run_case nofail '
  src="$(mktemp)"; printf x >"$src"
  INSTALL_ACTIVE=true
  jx_install_file "$src" "$T/a.txt" 644
  INSTALL_ACTIVE=false
  exit 1
'
ck "committed install keeps its files even if the shell later fails" test -e "$T/a.txt"
run_case keep '
  src="$(mktemp)"; printf x >"$src"
  INSTALL_ACTIVE=true; KEEP_ON_FAILURE=true
  jx_install_file "$src" "$T/a.txt" 644
  exit 1
'
ck "--keep-on-failure keeps the failed install" test -e "$T/a.txt"
run_case ok '
  src="$(mktemp)"; printf x >"$src"
  INSTALL_ACTIVE=true
  jx_install_file "$src" "$T/a.txt" 644
  exit 0
'
ck "exit 0 does not roll back" test -e "$T/a.txt"

echo "Ctrl-C and ERR (a failing command) roll back too"
run_case err '
  trap "exit 130" INT
  src="$(mktemp)"; printf x >"$src"
  INSTALL_ACTIVE=true
  jx_install_file "$src" "$T/a.txt" 644
  false
'
ck "set -e failure rolled back" test ! -e "$T/a.txt"
ck "failure message explains the undo" out_has "being undone"
run_case sigint '
  trap "exit 130" INT
  src="$(mktemp)"; printf x >"$src"
  INSTALL_ACTIVE=true
  jx_install_file "$src" "$T/a.txt" 644
  kill -INT $BASHPID
  sleep 5
'
t "Ctrl-C exit code" 130 "$CASE_RC"
ck "Ctrl-C rolled back" test ! -e "$T/a.txt"

# ================================================================================== safety guards
echo "rollback refuses dangerous deletions"
run_case guards '
  for p in / /etc /usr /opt /var/lib /home /root /tmp relative/path /etc/../etc; do
    if safe_rm_target "$p"; then echo "ALLOWED:$p"; fi
  done
  safe_rm_target /opt/ha-gatekeeper && echo "ok-opt-app"
  safe_rm_target /opt/HAVPS && echo "ok-opt-havps"
'
ck "no dangerous path is allowed" bash -c "! grep -q ALLOWED '$CASE_OUT'"
ck "app folders are allowed" out_has "ok-opt-havps"

# ==================================================================================== packages
echo "packages: only what this run installed is removed, and only if nothing else would go"
run_case pkgs_ok '
  printf "bash\ncoreutils\ncurl\n" >"$FAKE/pkgs"
  printf "jq:libjq1\n" >"$FAKE/deps"
  INSTALL_ACTIVE=true
  jx_pkg_install curl jq psmisc
  echo "after-install: $(tr "\n" " " <"$FAKE/pkgs")"
  echo "entry: $(journal_list)"
  exit 1
'
t "packages after rollback: curl (pre-existing) stays" "bash coreutils curl " "$(tr '\n' ' ' <"$FAKE/pkgs")"
ck "journal text names the new packages (not the pre-installed curl)" out_has "entry: Installed packages: jq libjq1 psmisc"
ck "apt was asked to simulate first" calls_have "apt-get -s remove --purge"

run_case pkgs_guard '
  printf "bash\n" >"$FAKE/pkgs"
  INSTALL_ACTIVE=true
  jx_pkg_install jq
  echo "other-package" >"$FAKE/extra-remove"
  exit 1
'
ck "removal that would take other packages with it is skipped" grep -qx jq "$FAKE/pkgs"
ck "and says why" out_has "would also remove"
ck "no real removal happened" calls_lack "apt-get remove --purge -y"

run_case pkgs_noop '
  printf "curl\njq\n" >"$FAKE/pkgs"
  INSTALL_ACTIVE=true
  jx_pkg_install curl jq
  echo "entries: $(journal_list | wc -l)"
'
ck "installing what is already there records nothing" out_has "entries: 0"
run_case pkgs_fail '
  INSTALL_ACTIVE=true
  touch "$FAKE/apt-fails"
  jx_pkg_install jq || echo "install-failed"
  echo "entries: $(journal_list | wc -l)"
'
ck "a failed install records nothing" out_has "entries: 0"

# ====================================================================================== firewall
echo "ufw: rules that already existed are never recorded or removed; rules we add are removed again"
run_case ufw_existing '
  touch "$FAKE/ufw.active"
  printf "allow 80/tcp comment '"'"'mine'"'"'\nallow 22/tcp\n" >"$FAKE/ufw.rules"
  CFG[GATEKEEPER_MODE]=selfsigned; CFG[HA_BASE_URL]="https://ha.example.com"; CFG[GATEKEEPER_PORT]=8080
  INSTALL_ACTIVE=true
  open_firewall
  echo "rules-after-open: $(sed "s/ comment.*//" "$FAKE/ufw.rules" | tr "\n" ";")"
  exit 1
'
t "rules after rollback are exactly the original ones" "allow 80/tcp;allow 22/tcp;" "$(sed "s/ comment.*//" "$FAKE/ufw.rules" | tr '\n' ';')"
ck "443 rules were added during the run" out_has "allow 443/tcp"
ck "ufw was never disabled" calls_lack "disable"
ck "pre-existing 80/tcp rule was not re-added" bash -c "[[ \$(grep -c 'ufw allow 80/tcp' '$FAKE/calls') -eq 0 ]]"

run_case ufw_enable '
  : >"$FAKE/ufw.rules"
  CFG[GATEKEEPER_MODE]=selfsigned; CFG[HA_BASE_URL]="https://ha.example.com"; CFG[GATEKEEPER_PORT]=8080
  P_UFW_ENABLE=true; P_UFW_SSH_PORTS="22 2222"
  INSTALL_ACTIVE=true
  open_firewall
  [[ -f "$FAKE/ufw.active" ]] || exit 50
  echo "rules-while-on: $(tr "\n" ";" <"$FAKE/ufw.rules")"
  exit 1
'
ck "ufw was on during the run" out_has "rules-while-on: allow 22/tcp;allow 2222/tcp;allow 80/tcp;allow 443/tcp;allow 443/udp;"
ck "ufw is off again after rollback (this run had switched it on)" test ! -f "$FAKE/ufw.active"
t "no rules left" "" "$(tr '\n' ';' <"$FAKE/ufw.rules")"
ck "firewall is switched off BEFORE its rules are deleted (no lock-out window)" bash -c "
  off=\$(grep -n 'ufw --force disable' '$FAKE/calls' | head -1 | cut -d: -f1)
  del=\$(grep -n 'ufw --force delete' '$FAKE/calls' | head -1 | cut -d: -f1)
  [[ -n \$off && -n \$del && \$off -lt \$del ]]"

run_case ufw_off_untouched '
  : >"$FAKE/ufw.rules"
  CFG[GATEKEEPER_MODE]=selfsigned; CFG[HA_BASE_URL]="https://ha.example.com"; CFG[GATEKEEPER_PORT]=8080
  P_UFW_ENABLE=false
  INSTALL_ACTIVE=true
  open_firewall
'
ck "ufw off and not approved: no rule is added" calls_lack "ufw allow"

run_case ufw_never '
  touch "$FAKE/ufw.active"
  CFG[GATEKEEPER_MODE]=selfsigned; CFG[HA_BASE_URL]="https://ha.example.com"; CFG[GATEKEEPER_PORT]=8080
  export GATEKEEPER_UFW=0
  INSTALL_ACTIVE=true
  open_firewall
'
ck "GATEKEEPER_UFW=0 touches no firewall at all" calls_lack "ufw allow"

# ================================================================================ swap and fstab
echo "swap: file and fstab line are undone; a line that already existed is not touched"
run_case swap '
  printf "UUID=abc / ext4 defaults 0 1\n" >"$FAKE/../fstab"
  P_SWAP_MB=1024
  INSTALL_ACTIVE=true
  create_swap
  [[ -f "$GK_SWAP_FILE" ]] && grep -q "swapfile none swap" "$GK_FSTAB_FILE" || exit 60
  exit 1
'
ck "swap file removed" test ! -e "$T/swapfile"
t "fstab back to the original" "UUID=abc / ext4 defaults 0 1" "$(cat "$T/fstab")"
ck "swapoff was called" calls_have "swapoff"
run_case swap_existing_line '
  printf "UUID=abc / ext4 defaults 0 1\n%s none swap sw 0 0\n" "$GK_SWAP_FILE" >"$GK_FSTAB_FILE"
  P_SWAP_MB=1024
  INSTALL_ACTIVE=true
  create_swap
  exit 1
'
ck "an fstab line that already existed stays" grep -q "swapfile none swap" "$T/fstab"

# ====================================================================================== systemd
echo "systemd units: created units are removed and disabled, replaced ones are restored"
run_case units '
  DOCKER_BIN=/usr/bin/docker
  mkdir -p "$T/systemd"
  printf "[Unit]\nDescription=old\n" >"$T/systemd/ha-gatekeeper-backup.service"
  echo ha-gatekeeper-backup.timer >"$FAKE/enabled"
  INSTALL_ACTIVE=true
  install_systemd_units
  [[ -f "$T/systemd/ha-gatekeeper.service" ]] || exit 70
  grep -qx ha-gatekeeper.service "$FAKE/enabled" || exit 71
  exit 1
'
ck "new unit removed" test ! -e "$T/systemd/ha-gatekeeper.service"
ck "new timer unit removed" test ! -e "$T/systemd/ha-gatekeeper-watchdog.timer"
ck "replaced unit restored" grep -q "Description=old" "$T/systemd/ha-gatekeeper-backup.service"
ck "units enabled by this run are disabled again" bash -c "! grep -qx ha-gatekeeper.service '$FAKE/enabled'"
ck "a timer that was enabled before stays enabled" grep -qx ha-gatekeeper-backup.timer "$FAKE/enabled"
ck "systemd reloaded after the files are gone" calls_have "systemctl daemon-reload"

# =========================================================================== secrets and .env
echo "secrets are written as private files and the container env never carries them"
run_case secrets '
  declare -A X=()
  cfg_defaults
  CFG[HA_TOKEN]="tok-$(printf "z%.0s" {1..30})"; CFG[ADMIN_PASSWORD]="p@ss $+word"; CFG[ADMIN_SESSION_SECRET]="sess-secret-123"; CFG[API_KEY_HASH_SECRET]="hash-secret-0123456789"
  INSTALL_ACTIVE=true
  sync_secret_files
  echo "dir: $(stat -c "%a %u" "$APP_DIR/secrets")"
  echo "token-file: $(stat -c "%a" "$APP_DIR/secrets/ha_token")"
  echo "pw-roundtrip: [$(cat "$APP_DIR/secrets/admin_password")]"
  echo "changed1: $SECRETS_CHANGED"
  SECRETS_CHANGED=false; sync_secret_files; echo "changed2: $SECRETS_CHANGED"
  mkdir "$APP_DIR/secrets/ha_token.d"; rm -rf "$APP_DIR/secrets/ha_token"; mkdir "$APP_DIR/secrets/ha_token"
  sync_secret_files; echo "dir-replaced: $([[ -f "$APP_DIR/secrets/ha_token" ]] && echo yes)"
  exit 1
'
ck "secrets folder is root-only" out_has "dir: 700 0"
ck "secret file is read-only for the app user" out_has "token-file: 400"
ck "special characters survive byte for byte" out_has 'pw-roundtrip: [p@ss $+word]'
ck "first write flags a recreate" out_has "changed1: true"
ck "unchanged secrets do not flag a recreate" out_has "changed2: false"
ck "a folder Docker created in place of a missing file is replaced" out_has "dir-replaced: yes"
ck "secrets folder removed by rollback (it was created by this run)" test ! -e "$T/app/secrets"

echo "the compose file passes no secret as an environment variable"
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  mkdir -p "$ROOT/compose/secrets"
  cp "$REPO/docker-compose.yml" "$ROOT/compose/"
  for f in ha_token admin_password admin_session_secret api_key_hash_secret; do echo "SECRET-$f" >"$ROOT/compose/secrets/$f"; done
  mkdir -p "$ROOT/compose/deploy/certs" "$ROOT/compose/deploy/caddy"
  cat >"$ROOT/compose/.env" <<'EOF'
HA_BASE_URL="https://ha.example.com"
HA_TOKEN="SECRET-FROM-ENV-FILE-ha-token"
ADMIN_PASSWORD="SECRET-FROM-ENV-FILE-admin"
ADMIN_SESSION_SECRET="SECRET-FROM-ENV-FILE-session"
API_KEY_HASH_SECRET="SECRET-FROM-ENV-FILE-hash"
EOF
  rendered="$( cd "$ROOT/compose" && docker compose config 2>&1 )"
  ck "compose renders" bash -c "[[ -n '$rendered' ]]"
  ck "no value from .env reaches the container environment" bash -c "! grep -q 'SECRET-FROM-ENV-FILE' <<<\"\$1\"" _ "$rendered"
  ck "the *_FILE variables point at read-only mounts" bash -c "grep -q 'HA_TOKEN_FILE: /run/secrets/ha_token' <<<\"\$1\" && grep -q 'read_only: true' <<<\"\$1\"" _ "$rendered"
else
  echo "  (docker compose not available: skipped)"
fi

# ======================================================================================= apt lock
echo "apt lock detection works without fuser (reads /proc/locks)"
LOCKF="$ROOT/aptlock"
: >"$LOCKF"
python3 - "$LOCKF" <<'PYEOF' &
import fcntl, sys, time
f = open(sys.argv[1], "w")
fcntl.lockf(f, fcntl.LOCK_EX)
time.sleep(6)
PYEOF
HOLDER=$!
sleep 1
run_case aptlock "
  have() { [[ \"\$1\" == fuser ]] && return 1; command -v \"\$1\" >/dev/null 2>&1; }
  APT_LOCK_PATHS=('$LOCKF')
  apt_lock_held && echo held-detected
  APT_LOCK_PATHS=('$ROOT/not-locked')
  : >'$ROOT/not-locked'
  apt_lock_held || echo free-detected
"
ck "a held lock is detected" out_has "held-detected"
ck "an unlocked file is not reported as held" out_has "free-detected"
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null

# ============================================================================ local HA + firewall (O1)
echo "Home Assistant on this server + active ufw + GATEKEEPER_UFW=0 is refused BEFORE anything changes"
run_case localha_block '
  touch "$FAKE/ufw.active"; : >"$FAKE/ufw.rules"
  CFG[HA_BASE_URL]="http://host.docker.internal:8123"
  export GATEKEEPER_UFW=0
  check_local_ha_firewall && echo allowed || echo refused
'
ck "refused" out_has "refused"
ck "names the exact ufw command" out_has "ufw allow from 172.16.0.0/12 to any port 8123 proto tcp"
run_case localha_covered '
  touch "$FAKE/ufw.active"; echo "allow from 172.16.0.0/12 to any port 8123 proto tcp" >"$FAKE/ufw.rules"
  CFG[HA_BASE_URL]="http://host.docker.internal:8123"
  export GATEKEEPER_UFW=0
  check_local_ha_firewall && echo allowed || echo refused
'
ck "allowed when a covering rule exists" out_has "allowed"
run_case localha_remote '
  touch "$FAKE/ufw.active"; : >"$FAKE/ufw.rules"
  CFG[HA_BASE_URL]="https://ha.example.com"
  export GATEKEEPER_UFW=0
  check_local_ha_firewall && echo allowed || echo refused
'
ck "a remote Home Assistant is never blocked by this check" out_has "allowed"

# ===================================================================== rollback cause + log note (O4, O9)
echo "a rollback says why it started and that the log is kept"
run_case cause '
  ROLLBACK_CAUSE="SIGHUP: the terminal or SSH session closed"
  mkdir -p "$T/made"; : >"$T/jx"
  jpush "Created a folder" rv_rm_path "$T/made"
  journal_rollback
'
ck "cause printed" out_has "Cause: SIGHUP: the terminal or SSH session closed"
ck "cause logged" grep -q "ROLLBACK started with 1 entries (cause: SIGHUP" "$T/install.log"
ck "log kept note" out_has "Kept for you, on purpose: the install log"

# ================================================================== Docker Engine leftovers (O2)
echo "undoing Docker Engine also removes what the packages leave behind, only if this run created it"
cat >"$SHIM/getent" <<'EOF'
#!/usr/bin/env bash
echo "getent $*" >>"$FAKE/calls"
[[ "$1" == group && "$2" == docker && -f "$FAKE/docker.group" ]] && { echo "docker:x:998:"; exit 0; }
exit 2
EOF
cat >"$SHIM/groupdel" <<'EOF'
#!/usr/bin/env bash
echo "groupdel $*" >>"$FAKE/calls"; rm -f "$FAKE/docker.group"
EOF
chmod +x "$SHIM/getent" "$SHIM/groupdel"
run_case dockerleft '
  touch "$FAKE/docker.group";   echo bash >"$FAKE/pkgs"; echo bash >"$T/snap"; : >"$T/before"
  rv_docker_engine "$T/snap" "$T/before" 0 0 0 1 || true
  echo "rc=$?"
'
ck "docker group created by this run is removed" calls_have "groupdel docker"
run_case dockerkeep '
  touch "$FAKE/docker.group"
  echo bash >"$FAKE/pkgs"; echo bash >"$T/snap"; : >"$T/before"
  rv_docker_engine "$T/snap" "$T/before" 0 0 1 1 || true
'
ck "a docker group that existed before is kept" calls_lack "groupdel"

echo
echo "RESULT: $pass passed, $failn failed"
(( failn == 0 ))
