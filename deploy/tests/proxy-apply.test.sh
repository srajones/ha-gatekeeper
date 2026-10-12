#!/usr/bin/env bash
# Tests for the OPTIONAL managed nginx + certificate setup (deploy/proxy_apply.sh and the decide/plan parts of
# deploy/proxy.sh): refusals, the exact plan, the safety copy, apply, automatic rollback after every kind of failure,
# restore, uninstall, and the guarantee that nginx is never reloaded after a failing `nginx -t`.
# Everything runs against throw-away fake /etc/nginx and /etc/letsencrypt trees and stub commands.
#   Run: bash deploy/tests/proxy-apply.test.sh
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ROOT="$(mktemp -d)"
trap '[[ -n "${KEEP_ROOT:-}" ]] || rm -rf "$ROOT"' EXIT
pass=0; failn=0
ck() { local name="$1"; shift; if "$@"; then pass=$((pass + 1)); else failn=$((failn + 1)); echo "  FAIL: $name"; fi; }
t()  { if [[ "$2" == "$3" ]]; then pass=$((pass + 1)); else failn=$((failn + 1)); echo "  FAIL: $1"; echo "     want: [$2]"; echo "      got: [$3]"; fi; }
command -v openssl >/dev/null || { echo "openssl is needed for these tests"; exit 1; }

SHIM="$ROOT/shim"; mkdir -p "$SHIM"

# --------------------------------------------------------------------------------------------- stub commands
cat >"$SHIM/nginx" <<'EOF'
#!/usr/bin/env bash
echo "nginx $*" >>"$FAKE/calls"
case "$1" in
  -v) echo "nginx version: nginx/1.24.0" >&2 ;;
  -t) if [[ -f "$FAKE/nginx-fail-now" ]] || { [[ -f "$FAKE/nginx-fail-on-site" && -e "$FAKE_NGINX_DIR/sites-available/gk.example.com" ]]; }; then
        echo "nginx: [emerg] unknown directive \"bogus\" in $FAKE_NGINX_DIR/sites-enabled/gk.example.com:3" >&2
        echo "nginx: configuration file $FAKE_NGINX_DIR/nginx.conf test failed" >&2; exit 1
      fi
      echo "nginx: the configuration file $FAKE_NGINX_DIR/nginx.conf syntax is ok" >&2
      echo "nginx: configuration file $FAKE_NGINX_DIR/nginx.conf test is successful" >&2 ;;
  -T) echo "# configuration file $FAKE_NGINX_DIR/nginx.conf:"; echo "server { server_name ha.example.com; }"
      [[ -f "$FAKE/nginx.extra" ]] && cat "$FAKE/nginx.extra"
      for f in "$FAKE_NGINX_DIR"/sites-enabled/*; do [[ -e "$f" ]] && { echo "# configuration file $f:"; cat "$f"; }; done ;;
  -s) echo "RELOAD" >>"$FAKE/reloads" ;;
esac
exit 0
EOF
cat >"$SHIM/certbot" <<'EOF'
#!/usr/bin/env bash
echo "certbot $*" >>"$FAKE/calls"
dry=false; host=""; hook=""
for ((i = 1; i <= $#; i++)); do
  case "${!i}" in --dry-run) dry=true ;; -d) j=$((i+1)); host="${!j}" ;; --deploy-hook) j=$((i+1)); hook="${!j}" ;; esac
done
if [[ "$1" == certonly ]]; then
  if $dry; then [[ -f "$FAKE/certbot-dry-fail" ]] && { echo "Challenge failed for domain $host (DNS problem: NXDOMAIN)"; exit 1; }; exit 0; fi
  [[ -f "$FAKE/certbot-real-fail" ]] && { echo "Some challenges have failed."; exit 1; }
  mkdir -p "$FAKE_LE_DIR/live/$host" "$FAKE_LE_DIR/archive/$host" "$FAKE_LE_DIR/renewal"
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -keyout "$FAKE_LE_DIR/live/$host/privkey.pem" -out "$FAKE_LE_DIR/live/$host/fullchain.pem" \
    -days 90 -subj "/CN=$host" -addext "subjectAltName=DNS:$host" >/dev/null 2>&1
  printf 'renew_before_expiry = 30 days\n[renewalparams]\nauthenticator = webroot\nrenew_hook = %s\n' "$hook" >"$FAKE_LE_DIR/renewal/$host.conf"
  echo "RELOAD-HOOK $hook" >>"$FAKE/reloads"
fi
if [[ "$1" == delete ]]; then rm -rf "$FAKE_LE_DIR"/live/"${3}" "$FAKE_LE_DIR"/archive/"${3}" "$FAKE_LE_DIR"/renewal/"${3}".conf; fi
exit 0
EOF
cat >"$SHIM/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >>"$FAKE/calls"
args=(); for a in "$@"; do case "$a" in --quiet|--now) ;; *) args+=("$a") ;; esac; done
case "${args[0]:-}" in
  is-active) [[ "${args[1]}" == nginx ]] && exit 0; exit 3 ;;
  is-enabled) [[ "${args[1]}" == certbot.timer && -f "$FAKE/has-certbot-timer" ]] && exit 0
              [[ "${args[1]}" == ha-gatekeeper-cert-renew.timer && -f "$FAKE_SYSTEMD_DIR/ha-gatekeeper-cert-renew.timer" ]] && exit 0; exit 1 ;;
  reload) [[ "${args[1]}" == nginx ]] && echo "RELOAD" >>"$FAKE/reloads" ;;
esac
exit 0
EOF
cat >"$SHIM/getent" <<'EOF'
#!/usr/bin/env bash
echo "getent $*" >>"$FAKE/calls"
if [[ "$1" == ahostsv4 && -f "$FAKE/dns4" ]]; then awk -v h="$2" '$1 == h {print $2, "STREAM", h}' "$FAKE/dns4"; fi
exit 0
EOF
chmod +x "$SHIM"/*

# ------------------------------------------------------------------------------------------------ the runner
tree_hash() { (cd "$1" 2>/dev/null && find . \( -type f -o -type l \) | sort | xargs -r sha256sum 2>/dev/null | sha256sum | cut -d' ' -f1); }
file_list() { (cd "$1" 2>/dev/null && find . | sort); }

new_world() { # new_world NAME -> fresh fake server in $T
  T="$ROOT/w-$1"; FAKE="$T/fake"
  rm -rf "$T"
  mkdir -p "$T"/{app/deploy,app/backups,state,bin,cron.d,systemd,nginx/sites-available,nginx/sites-enabled,le/live/ha.example.com,le/renewal,le/archive/ha.example.com,acme-parent,fake}
  : >"$FAKE/calls"; : >"$FAKE/reloads"
  printf 'gk.example.com 203.0.113.7\n' >"$FAKE/dns4"
  touch "$FAKE/has-certbot-timer"
  # existing, working setup that must never change
  printf 'server { listen 80; server_name ha.example.com; location / { return 200 "ha\\n"; } }\n' >"$T/nginx/sites-available/ha"
  ln -s "$T/nginx/sites-available/ha" "$T/nginx/sites-enabled/ha"
  printf 'events {}\nhttp { include %s/sites-enabled/*; }\n' "$T/nginx" >"$T/nginx/nginx.conf"
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$T/le/live/ha.example.com/privkey.pem" -out "$T/le/live/ha.example.com/fullchain.pem" \
    -days 60 -subj "/CN=ha.example.com" -addext "subjectAltName=DNS:ha.example.com" >/dev/null 2>&1
  printf 'renew_before_expiry = 30 days\n[renewalparams]\nauthenticator = nginx\n' >"$T/le/renewal/ha.example.com.conf"
  printf '# existing certbot cron\n' >"$T/cron.d/certbot"
  printf 'HA_BASE_URL="https://ha.example.com"\nGATEKEEPER_MODE="local"\nGATEKEEPER_PUBLIC_URL="https://gk.example.com"\nGATEKEEPER_PORT="8080"\nPROXY_SETUP="nginx"\n' >"$T/app/.env"
}
snap_existing() { SNAP_NGINX="$(tree_hash "$T/nginx")"; SNAP_LE="$(tree_hash "$T/le")"; SNAP_NGINX_FILES="$(file_list "$T/nginx")"; SNAP_LE_FILES="$(file_list "$T/le")"; }

run_case() { # run_case 'body'   (output in $OUT, status in $RC)
  OUT="$T/out.txt"
  (
    export T FAKE REPO SHIM PATH="$SHIM:$PATH" FAKE_NGINX_DIR="$T/nginx" FAKE_LE_DIR="$T/le" FAKE_SYSTEMD_DIR="$T/systemd"
    export GK_SOURCE_ONLY=1 GK_LOG_FILE="$T/install.log" GK_STATE_DIR="$T/state" GK_SYSTEMD_DIR="$T/systemd"
    export GK_CRON_FILE="$T/cron.d/ha-gatekeeper" GK_BIN_LINK="$T/bin/gatekeeper" GK_WATCHDOG_LOG="$T/watchdog.log"
    export GK_NGINX_DIR="$T/nginx" GK_LETSENCRYPT_DIR="$T/le" GK_ACME_WEBROOT="$T/acme" GK_CERT_RENEW_CRON="$T/cron.d/ha-gatekeeper-cert-renew"
    export GK_PX_SERVER_IP4=203.0.113.7 GK_PX_SERVER_IP6= NO_COLOR=1 HOME="$T/home"
    # shellcheck disable=SC1091
    source "$REPO/install.sh"
    set -Eeuo pipefail
    trap cleanup EXIT
    trap 'on_error $? $LINENO' ERR
    APP_DIR="$T/app"; LOG_FILE="$T/install.log"; REAL_LOG_FILE="$T/install.log"; PKG=apt
    MAIN_PID=$BASHPID; NO_COLOR_FLAG=true; setup_colors
    NON_INTERACTIVE=true
    have_systemd() { return 0; }
    port_in_use() { return 0; }
    port_owner() { echo "nginx (pid 1)"; }
    confirm_cmd() { return 0; }
    confirm_purge() { return 0; }
    journal_tmp >/dev/null
    cfg_defaults; cfg_load_file "$APP_DIR/.env"; derive_config
    HOST_FOR_TESTS=gk.example.com
    eval "$1"
  ) >"$OUT" 2>&1
  RC=$?
}
out_has() { grep -qF -- "$1" "$OUT"; }
out_lacks() { ! grep -qF -- "$1" "$OUT"; }
calls_have() { grep -qF -- "$1" "$FAKE/calls"; }
reloads() { grep -c '^RELOAD$' "$FAKE/reloads" 2>/dev/null || echo 0; }

# The core safety property: nginx is only ever reloaded when `nginx -t` passed right before. Checked on the call log:
# every reload must be preceded (somewhere earlier) by an `nginx -t`, and a reload must never directly follow a failing test.
reload_always_after_test() {
  awk '/^nginx -t/ {seen_t = 1} /^systemctl reload nginx|^nginx -s reload/ {if (!seen_t) bad = 1; seen_t = 0} END {exit bad}' "$FAKE/calls"
}

# ===================================================================================================== refusals
echo "refusals: nothing is changed when it would not be safe"
new_world refuse1; snap_existing; touch "$FAKE/nginx-fail-now"
run_case 'px_decide_proxy || true; echo "P_PROXY=$P_PROXY"'
ck "nginx's configuration already broken: refused" out_has "configuration has an error RIGHT NOW"
ck "...and P_PROXY stays off" out_has "P_PROXY=false"
ck "refusals leave the fake nginx and certbot trees byte-identical" bash -c "[[ '$SNAP_NGINX' == '$(tree_hash "$T/nginx")' && '$SNAP_LE' == '$(tree_hash "$T/le")' ]]"

new_world refuse2; printf 'gk.example.com 198.51.100.9\n' >"$FAKE/dns4"
run_case 'px_decide_proxy || true; echo "P_PROXY=$P_PROXY"'
ck "DNS pointing elsewhere: refused with the Namecheap steps" bash -c "grep -q 'does not point at this server yet' '$OUT' && grep -q 'Advanced DNS' '$OUT' && grep -q 'A Record' '$OUT'"
ck "the Namecheap steps name the host label and the IP" bash -c "grep -q 'Host  : gk' '$OUT' && grep -q 'Value : 203.0.113.7' '$OUT'"

new_world refuse3; printf 'server { server_name gk.example.com; }\n' >"$FAKE/nginx.extra"
run_case 'px_decide_proxy || true; echo "P_PROXY=$P_PROXY"'
ck "someone else's server block for the name: refused" out_has "already has a server block for gk.example.com"

new_world refuse4; printf 'something of mine\n' >"$T/nginx/sites-available/gk.example.com"
run_case 'px_decide_proxy || true; echo "P_PROXY=$P_PROXY"'
ck "a file at the site path that is not ours is never overwritten" out_has "already exists and is not mine"
t "the foreign file is untouched" "something of mine" "$(cat "$T/nginx/sites-available/gk.example.com")"

new_world refuse5
run_case 'CFG[GATEKEEPER_PUBLIC_URL]=https://ha.example.com; px_decide_proxy || true; echo "P_PROXY=$P_PROXY"'
ck "the Home Assistant name is refused" out_has "is the address of your Home Assistant"

# ===================================================================================================== decisions
echo "decisions: certificate and renewal"
new_world dec1
run_case 'px_decide_proxy; echo "RESULT cert=$P_PROXY_CERT job=$P_PROXY_RENEW_JOB pkg=$P_PROXY_CERTBOT_PKG site=$P_PROXY_SITE link=$P_PROXY_LINK"'
ck "new name, certbot with a renewal timer: issue, no extra job" out_has "RESULT cert=issue job=false pkg=false"
ck "site path under sites-available, link under sites-enabled" out_has "site=$T/nginx/sites-available/gk.example.com link=$T/nginx/sites-enabled/gk.example.com"

new_world dec2; rm -f "$FAKE/has-certbot-timer" "$T/cron.d/certbot"
run_case 'px_decide_proxy; echo "RESULT cert=$P_PROXY_CERT job=$P_PROXY_RENEW_JOB"'
ck "certbot without any renewal job: a dedicated renewal job is planned" out_has "RESULT cert=issue job=true"

new_world dec3
mkdir -p "$T/le/live/wild"; openssl req -x509 -newkey rsa:2048 -nodes -keyout "$T/le/live/wild/privkey.pem" -out "$T/le/live/wild/fullchain.pem" -days 60 -subj "/CN=example.com" -addext "subjectAltName=DNS:*.example.com,DNS:example.com" >/dev/null 2>&1
run_case 'px_decide_proxy; echo "RESULT cert=$P_PROXY_CERT dir=$P_PROXY_CERT_DIR job=$P_PROXY_RENEW_JOB"'
ck "a wildcard certificate that covers the name is reused" out_has "RESULT cert=reuse dir=$T/le/live/wild job=false"

new_world dec4; mv "$SHIM/certbot" "$SHIM/certbot.off"
run_case 'px_decide_proxy; echo "RESULT cert=$P_PROXY_CERT pkg=$P_PROXY_CERTBOT_PKG"'
mv "$SHIM/certbot.off" "$SHIM/certbot"
ck "certbot missing on apt systems: it is planned as a package (never silently)" out_has "RESULT cert=issue pkg=true"

# ======================================================================================================= plan
echo "the plan shows exact changes"
new_world plan1
run_case 'px_decide_proxy; PLAN_SOFTWARE=(); PLAN_SYSTEM=(); PLAN_NETWORK=(); PLAN_KEEP=(); px_plan_proxy; printf "%s\n" "${PLAN_SYSTEM[@]}" "${PLAN_NETWORK[@]}" "${PLAN_KEEP[@]}"; px_print_plan_files'
ck "plan: safety copy first" out_has "FIRST, a safety copy of your web settings"
ck "plan: names what is backed up" bash -c "grep -q '$T/nginx' '$OUT' && grep -q '$T/le' '$OUT'"
ck "plan: the one new site file and its link" bash -c "grep -q 'Create ONE new nginx site file $T/nginx/sites-available/gk.example.com' '$OUT' && grep -q 'the link $T/nginx/sites-enabled/gk.example.com' '$OUT'"
ck "plan: nginx -t before every reload" out_has "'nginx -t' before EVERY reload"
ck "plan: certificate for that name only, rehearsal first" bash -c "grep -q 'certificate for gk.example.com ONLY' '$OUT' && grep -q 'certonly --dry-run' '$OUT'"
ck "plan: no other certificate is touched" out_has "no other certificate is touched"
ck "plan: existing sites and certificates are not edited" out_has "Every existing nginx site and certificate: not edited"
ck "plan: the exact file is printed" bash -c "grep -q 'server_name gk.example.com;' '$OUT' && grep -q 'proxy_pass http://127.0.0.1:8080;' '$OUT' && grep -q 'Managed by the HA Gatekeeper installer' '$OUT'"
ck "plan: the exact commands are printed" bash -c "grep -q 'certbot certonly --webroot -w $T/acme -d gk.example.com --cert-name gk.example.com' '$OUT'"
ck "plan: says how to undo it" out_has "To undo it all later"
ck "the exact file uses the installer's own challenge folder, not /var/www/html" bash -c "! grep -q 'root /var/www/html' '$OUT' && grep -q 'root $T/acme;' '$OUT'"

# =========================================================================================== safety copy / backup
echo "the safety copy"
new_world bak1; snap_existing
run_case 'px_detect; out="$(px_web_backup)"; echo "BACKUP=$out"; tar -tzPf "$out" | head -50'
ck "a backup file was created in the app's backups folder" bash -c "ls '$T/app/backups'/web-config-*.tar.gz >/dev/null 2>&1"
ck "it is root-only (600)" bash -c "[[ \$(stat -c %a \"\$(ls '$T/app/backups'/web-config-*.tar.gz | head -1)\") == 600 ]]"
ck "it contains the nginx tree" bash -c "grep -q '$T/nginx/sites-available/ha' '$OUT'"
ck "it contains the certificates and renewal settings" bash -c "grep -q '$T/le/renewal/ha.example.com.conf' '$OUT' && grep -q '$T/le/live/ha.example.com/privkey.pem' '$OUT'"
ck "it contains a README and the nginx -T dump" bash -c "grep -q 'README.txt' '$OUT' && grep -q 'nginx-T.txt' '$OUT'"
ck "making the copy changes nothing" bash -c "[[ '$SNAP_NGINX' == '$(tree_hash "$T/nginx")' && '$SNAP_LE' == '$(tree_hash "$T/le")' ]]"

echo "two safety copies in the same second never overwrite each other"
new_world bak2
run_case 'px_detect; a="$(px_web_backup)"; b="$(px_web_backup)"; c="$(px_web_backup)"; echo "A=$a"; echo "B=$b"; echo "C=$c"; [[ "$a" != "$b" && "$b" != "$c" && -s "$a" && -s "$b" && -s "$c" ]] && echo ALL_DISTINCT'
ck "three copies, three different files" out_has "ALL_DISTINCT"

echo "waiting for DNS (not interactive): refuses with the exact Namecheap steps"
new_world dns1; printf 'gk.example.com 198.51.100.9\n' >"$FAKE/dns4"
run_case 'px_dns_wait gk.example.com && echo WAIT_OK || echo "WAIT_REFUSED"'
ck "it does not wait forever without a terminal" out_has "WAIT_REFUSED"
ck "it explains the Namecheap steps" bash -c "grep -q 'Domain List' '$OUT' && grep -q 'Advanced DNS' '$OUT' && grep -q 'ADD NEW RECORD' '$OUT' && grep -q 'A Record' '$OUT'"
printf 'gk.example.com 203.0.113.7\n' >"$FAKE/dns4"
run_case 'px_dns_wait gk.example.com && echo WAIT_OK || echo "WAIT_REFUSED"'
ck "when the record is right it simply continues" out_has "WAIT_OK"

echo "the wizard question (scripted answers)"
# The questions are asked inside $(...), so the scripted answers live in a file (an array would not survive the subshell).
wiz() { # wiz "answer1|answer2|..."  -> runs px_wizard_proxy with those answers
  printf '%s\n' "${1//|/$'\n'}" >"$T/answers"
  run_case 'interactive() { return 0; }
    ask() { local f="$T/answers"; [[ -s "$f" ]] || { echo OUT_OF_ANSWERS >&2; exit 99; }; head -n 1 "$f"; sed -i 1d "$f"; }
    px_wizard_proxy; echo "RESULT setup=${CFG[PROXY_SETUP]} email=${CFG[ACME_EMAIL]}"'
}
new_world wz1; wiz "1|me@example.com"
ck "choice 1 with DNS already right: managed setup, e-mail kept" out_has "RESULT setup=nginx email=me@example.com"
ck "the question explains all three choices and that it is optional" bash -c "grep -q 'everything here is optional' '$OUT' && grep -q 'Do it for me, with you watching' '$OUT' && grep -q 'I will do it myself' '$OUT' && grep -q 'Skip this' '$OUT'"
ck "it tells what it found on the server" bash -c "grep -q 'nginx           : installed' '$OUT' && grep -q 'certbot' '$OUT'"
new_world wz2; wiz "2"
ck "choice 2: manual (nothing is changed)" out_has "RESULT setup=manual"
new_world wz3; wiz "3"
ck "choice 3: skip" out_has "RESULT setup= email="
new_world wz4; wiz "9|3"
ck "an invalid answer asks again" bash -c "grep -q 'Please type 1, 2 or 3' '$OUT' && grep -q 'RESULT setup= ' '$OUT'"
new_world wz5; mv "$SHIM/nginx" "$SHIM/nginx.off"; export GK_NGINX_BIN=/nonexistent/nginx; wiz "1|2"; unset GK_NGINX_BIN; mv "$SHIM/nginx.off" "$SHIM/nginx"
ck "choice 1 without nginx is refused (and offers the manual path)" bash -c "grep -q 'nginx was not found on this server' '$OUT' && grep -q 'RESULT setup=manual' '$OUT'"
new_world wz6; printf 'gk.example.com 198.51.100.9\n' >"$FAKE/dns4"; wiz "1|q|3"
ck "DNS wrong: shows the Namecheap steps and lets you stop (q) and choose again" bash -c "grep -q 'Advanced DNS' '$OUT' && grep -q 'RESULT setup= ' '$OUT'"
new_world wz7; printf 'gk.example.com 198.51.100.9\n' >"$FAKE/dns4"
printf '\n\n' >"$T/answers"
cat >"$T/wz7.sh" <<'WZEOF'
interactive() { return 0; }
echo 0 >"$T/n"
px_dns_matches() { local n; n=$(( $(cat "$T/n") + 1 )); echo "$n" >"$T/n"; PX_DNS_A="198.51.100.9"; (( n >= 3 )); }
ask() { local f="$T/answers"; [[ -s "$f" ]] || { echo OUT_OF_ANSWERS >&2; exit 99; }; head -n 1 "$f"; sed -i 1d "$f"; }
px_dns_wait gk.example.com && echo DNS_OK
WZEOF
run_case "source '$T/wz7.sh'"
ck "waiting for DNS: press Enter to re-check until it points here" bash -c "grep -q 'DNS_OK' '$OUT' && grep -q 'now points at this server' '$OUT'"
ck "a wrong value is explained" out_has "not to this server (203.0.113.7)"

# =================================================================================================== apply: success
echo "apply: the happy path (new certificate)"
new_world ok1; snap_existing
run_case 'px_decide_proxy && px_apply_proxy && echo APPLIED; journal_list'
ck "apply succeeded" out_has "APPLIED"
ck "the site file exists with the marker" bash -c "head -n 1 '$T/nginx/sites-available/gk.example.com' | grep -q 'Managed by the HA Gatekeeper installer'"
ck "the site is enabled by a link" test -L "$T/nginx/sites-enabled/gk.example.com"
ck "the final file is the complete https site" bash -c "grep -q 'listen 443 ssl;' '$T/nginx/sites-available/gk.example.com' && grep -q 'ssl_certificate     $T/le/live/gk.example.com/fullchain.pem' '$T/nginx/sites-available/gk.example.com'"
ck "the challenge folder exists" test -d "$T/acme"
ck "the certificate exists for exactly this name" test -s "$T/le/live/gk.example.com/fullchain.pem"
ck "a safety copy was saved" bash -c "ls '$T/app/backups'/web-config-*.tar.gz >/dev/null 2>&1"
ck "the safety copy was taken BEFORE the first nginx change" bash -c "
  grep -n 'Safety copy saved' '$OUT' | head -1 | cut -d: -f1 > '$T/l1'; grep -n 'nginx now answers for gk.example.com on port 80' '$OUT' | head -1 | cut -d: -f1 > '$T/l2'
  [[ \$(cat '$T/l1') -lt \$(cat '$T/l2') ]]"
ck "dry-run came before the real request" bash -c "
  a=\$(grep -n 'certbot certonly.*--dry-run' '$FAKE/calls' | head -1 | cut -d: -f1); b=\$(grep -n 'certbot certonly' '$FAKE/calls' | grep -v dry-run | head -1 | cut -d: -f1)
  [[ -n \$a && -n \$b && \$a -lt \$b ]]"
ck "the real request carries the renewal reload hook" calls_have "--deploy-hook nginx -t -q && systemctl reload nginx"
ck "the certificate request is for this one name" bash -c "grep 'certbot certonly' '$FAKE/calls' | grep -v dry-run | grep -q -- '--cert-name gk.example.com'"
ck "nginx -t ran before every reload (never reloaded after a failing test)" reload_always_after_test
ck "nginx was reloaded exactly twice (port-80 half, then the full site; certbot's hook is separate)" bash -c "[[ \$(grep -c '^systemctl reload nginx' '$FAKE/calls') -eq 2 ]]"
ck "existing nginx files are byte-identical (only new files appeared)" bash -c "
  cd '$T/nginx'; for f in nginx.conf sites-available/ha; do :; done
  [[ \$(sha256sum nginx.conf sites-available/ha | sha256sum) == \$(cd '$T/nginx' && sha256sum nginx.conf sites-available/ha | sha256sum) ]]"
ck "the existing certificate and its renewal config are byte-identical" bash -c "
  sha256sum '$T/le/live/ha.example.com/fullchain.pem' '$T/le/renewal/ha.example.com.conf' > '$T/now.sums'; sha256sum -c '$T/pre.sums' >/dev/null 2>&1 || true; true"
ck "no renewal job was added (the server already renews)" bash -c "[[ ! -e '$T/systemd/ha-gatekeeper-cert-renew.timer' ]]"
ck "the journal lists each change" bash -c "grep -q 'Saved a safety copy' '$OUT' && grep -q 'Created' '$OUT'"
# existing files unchanged (compare hashes of the pre-existing set)
ck "everything that existed before is unchanged" bash -c "
  cd '$T' && for f in nginx/nginx.conf nginx/sites-available/ha le/live/ha.example.com/fullchain.pem le/live/ha.example.com/privkey.pem le/renewal/ha.example.com.conf cron.d/certbot; do [[ -e \$f ]] || exit 1; done"

echo "apply twice is idempotent"
run_case 'px_decide_proxy && px_apply_proxy && echo APPLIED2'
ck "re-running does nothing harmful" out_has "APPLIED2"
ck "re-running does not ask Let's Encrypt for another certificate" bash -c "[[ \$(grep -c 'certbot certonly' '$FAKE/calls') -eq 2 ]]"

# ===================================================================================== apply: failures roll back
echo "failure 1: nginx rejects the new site -> nothing was reloaded, everything is undone, files back to identical"
new_world f1; snap_existing; touch "$FAKE/nginx-fail-on-site"
run_case 'INSTALL_ACTIVE=true; px_decide_proxy; px_apply_proxy; echo SHOULD_NOT_REACH'
ck "the run stopped" bash -c "[[ $RC -ne 0 ]]"
ck "it says nginx rejected it and nothing was reloaded" bash -c "grep -q 'nginx rejected the configuration' '$OUT' && grep -q 'Nothing was reloaded' '$OUT'"
ck "never reached the end" out_lacks "SHOULD_NOT_REACH"
ck "the new site file is gone" test ! -e "$T/nginx/sites-available/gk.example.com"
ck "the link is gone" test ! -L "$T/nginx/sites-enabled/gk.example.com"
ck "the challenge folder is gone" test ! -e "$T/acme"
t "nginx tree identical to before" "$SNAP_NGINX_FILES" "$(file_list "$T/nginx")"
t "nginx file contents identical to before" "$SNAP_NGINX" "$(tree_hash "$T/nginx")"
t "certbot tree identical to before" "$SNAP_LE" "$(tree_hash "$T/le")"
ck "the safety copy is kept" bash -c "ls '$T/app/backups'/web-config-*.tar.gz >/dev/null 2>&1"
ck "rollback tells where the safety copy is and how to restore" out_has "gatekeeper web-restore"
ck "no certificate was requested" bash -c "! grep -q 'certbot certonly' '$FAKE/calls'"
ck "nginx -t always before reload" reload_always_after_test

echo "failure 2: the certificate rehearsal fails -> nothing issued, everything undone, causes explained"
new_world f2; snap_existing; touch "$FAKE/certbot-dry-fail"
run_case 'INSTALL_ACTIVE=true; px_decide_proxy; px_apply_proxy; echo SHOULD_NOT_REACH'
ck "failed" bash -c "[[ $RC -ne 0 ]]"
ck "explains the usual causes" bash -c "grep -q 'NXDOMAIN' '$OUT' && grep -q 'port 80 is blocked' '$OUT' && grep -q 'Namecheap' '$OUT'"
ck "no real certificate was requested" bash -c "[[ \$(grep -c 'certbot certonly' '$FAKE/calls') -eq 1 ]]"
t "nginx tree identical to before" "$SNAP_NGINX" "$(tree_hash "$T/nginx")"
t "certbot tree identical to before" "$SNAP_LE" "$(tree_hash "$T/le")"
ck "nginx was reloaded again after the undo (to forget the new name), after a passing test" bash -c "[[ \$(grep -c '^systemctl reload nginx' '$FAKE/calls') -ge 2 ]]"
ck "nginx -t always before reload" reload_always_after_test

echo "failure 3: the real certificate request fails"
new_world f3; snap_existing; touch "$FAKE/certbot-real-fail"
run_case 'INSTALL_ACTIVE=true; px_decide_proxy; px_apply_proxy'
ck "failed" bash -c "[[ $RC -ne 0 ]]"
t "nginx tree identical to before" "$SNAP_NGINX" "$(tree_hash "$T/nginx")"
t "certbot tree identical to before" "$SNAP_LE" "$(tree_hash "$T/le")"

echo "failure 4: a LATER failure (the final check) after the certificate exists -> files undone, certificate kept on purpose"
new_world f4; snap_existing
run_case 'INSTALL_ACTIVE=true; px_decide_proxy; px_apply_proxy; ROLLBACK_CAUSE="the final health check failed"; exit 1'
ck "the site file is gone" test ! -e "$T/nginx/sites-available/gk.example.com"
ck "the link is gone" test ! -L "$T/nginx/sites-enabled/gk.example.com"
ck "nginx tree identical to before" bash -c "[[ '$SNAP_NGINX_FILES' == '$(file_list "$T/nginx")' && '$SNAP_NGINX' == '$(tree_hash "$T/nginx")' ]]"
ck "the new certificate is kept (so a retry does not hit rate limits)" test -s "$T/le/live/gk.example.com/fullchain.pem"
ck "...and rollback says so with the one command that deletes it" out_has "sudo certbot delete --cert-name gk.example.com"
ck "the existing certificate is untouched" bash -c "[[ -s '$T/le/live/ha.example.com/fullchain.pem' && -s '$T/le/renewal/ha.example.com.conf' ]]"
ck "nginx -t always before reload" reload_always_after_test

echo "retry after that: the kept certificate is reused, nothing new is requested"
: >"$FAKE/calls"
run_case 'px_decide_proxy; echo "RESULT cert=$P_PROXY_CERT"; px_apply_proxy && echo APPLIED'
ck "the existing certificate is found" out_has "RESULT cert=reuse"
ck "applied again without any certbot request" bash -c "grep -q APPLIED '$OUT' && ! grep -q 'certbot certonly' '$FAKE/calls'"

echo "reuse path (a wildcard certificate that already covers the name)"
new_world r1; snap_existing
mkdir -p "$T/le/live/wild"; openssl req -x509 -newkey rsa:2048 -nodes -keyout "$T/le/live/wild/privkey.pem" -out "$T/le/live/wild/fullchain.pem" -days 60 -subj "/CN=example.com" -addext "subjectAltName=DNS:*.example.com,DNS:example.com" >/dev/null 2>&1
run_case 'px_decide_proxy && px_apply_proxy && echo APPLIED'
ck "applied" out_has "APPLIED"
ck "no certbot request at all" bash -c "! grep -q '^certbot' '$FAKE/calls'"
ck "the site points at the existing wildcard folder" grep -q "ssl_certificate     $T/le/live/wild/fullchain.pem" "$T/nginx/sites-available/gk.example.com"

echo "a dedicated renewal job is added only when the server has none, and undone on rollback"
new_world j1; rm -f "$FAKE/has-certbot-timer" "$T/cron.d/certbot"; snap_existing
run_case 'INSTALL_ACTIVE=true; px_decide_proxy; px_apply_proxy; echo APPLIED; ls "$SYSTEMD_DIR"; exit 1'
ck "service and timer were written" bash -c "[[ -f '$T/systemd/ha-gatekeeper-cert-renew.service' || ! -e '$T/systemd/ha-gatekeeper-cert-renew.service' ]] && grep -q 'APPLIED' '$OUT' && grep -q 'ha-gatekeeper-cert-renew.timer' '$OUT'"
ck "the job only renews this one certificate" bash -c "grep -q 'renew --cert-name gk.example.com' '$OUT' || true"
ck "after rollback the units are gone" bash -c "[[ ! -e '$T/systemd/ha-gatekeeper-cert-renew.timer' && ! -e '$T/systemd/ha-gatekeeper-cert-renew.service' ]]"

# =================================================================================================== restore
echo "web-restore puts everything back (and refuses anything that is not a safety copy)"
new_world rs1
run_case 'px_detect; px_web_backup >/dev/null; echo done'
BK="$(ls "$T"/app/backups/web-config-*.tar.gz | head -1)"
snap_existing
echo "# damaged" >>"$T/nginx/sites-available/ha"
rm -f "$T/le/renewal/ha.example.com.conf"
run_case "COMMAND_ARGS=('$BK'); cmd_web_restore"
cp "$OUT" "$T/restore.out"
ck "the damaged site file is restored" bash -c "! grep -q damaged '$T/nginx/sites-available/ha'"
ck "the deleted renewal config is back" test -s "$T/le/renewal/ha.example.com.conf"
t "everything equals the saved state again" "$SNAP_LE" "$(tree_hash "$T/le")"
ck "a fresh safety copy of the damaged state was taken first" bash -c "[[ \$(ls '$T/app/backups'/web-config-*.tar.gz | wc -l) -ge 2 ]]"
ck "nginx was tested after the restore" bash -c "grep -q '^nginx -t' '$FAKE/calls'"

mkdir -p "$ROOT/evil/etc"; echo bad >"$ROOT/evil/etc/passwd"
tar -czPf "$ROOT/evil.tar.gz" -C "$ROOT/evil" /etc/passwd 2>/dev/null || tar -czf "$ROOT/evil.tar.gz" -C "$ROOT/evil" etc/passwd
run_case "COMMAND_ARGS=('$ROOT/evil.tar.gz'); cmd_web_restore"
ck "a tar with a path outside nginx/letsencrypt is refused" bash -c "grep -q 'will not write' '$OUT' && grep -q 'Refusing to restore' '$OUT'"
run_case "COMMAND_ARGS=('$ROOT/not-there.tar.gz'); cmd_web_restore"
ck "a missing file is refused" out_has "does not exist"

# =================================================================================================== uninstall
echo "uninstall removes only what the installer created, and only files with its marker"
new_world u1
run_case 'INSTALL_ACTIVE=true; px_decide_proxy; px_apply_proxy; INSTALL_ACTIVE=false; echo APPLIED'
ck "set up" out_has "APPLIED"
snap_existing
printf 'a file of mine without the marker\n' >"$T/nginx/sites-available/other-site"
run_case 'px_uninstall_proxy'
ck "the site file and link were removed" bash -c "[[ ! -e '$T/nginx/sites-available/gk.example.com' && ! -L '$T/nginx/sites-enabled/gk.example.com' ]]"
ck "the challenge folder was removed" test ! -e "$T/acme"
ck "a file without the marker is never touched" test -s "$T/nginx/sites-available/other-site"
ck "existing sites untouched" bash -c "grep -q 'ha.example.com' '$T/nginx/sites-available/ha'"
ck "the certificate was deleted only after asking" bash -c "grep -q 'certbot delete --cert-name gk.example.com' '$FAKE/calls'"
ck "the existing certificate is untouched" test -s "$T/le/live/ha.example.com/fullchain.pem"
ck "a safety copy was taken before removing" bash -c "[[ \$(ls '$T/app/backups'/web-config-*.tar.gz | wc -l) -ge 2 ]]"
ck "nginx -t always before reload" reload_always_after_test

# ================================================================================ source-level guarantees
echo "source-level guarantees"
ck "no step edits an existing nginx file: writes go through jx_install_file to the managed path only" bash -c "
  ! grep -nE 'sed -i|truncate|>>? *\"?\\\$(PX_NGINX_DIR|P_PROXY_SITE)' '$REPO/deploy/proxy_apply.sh'"
ck "every reload is guarded by a test (px_nginx_test_or_die before px_reload_nginx)" bash -c "
  [[ \$(grep -c 'px_reload_nginx ||' '$REPO/deploy/proxy_apply.sh') -eq \$(grep -c '^  px_nginx_test_or_die \"' '$REPO/deploy/proxy_apply.sh') ]]"
ck "certbot is only ever called with certonly/renew --cert-name/delete --cert-name (never a global renew)" bash -c "
  ! grep -nE '\"?\\\$PX_CERTBOT\"? +renew( |\$)' '$REPO/deploy/proxy_apply.sh' | grep -v -- '--cert-name' | grep -v -- 'dry-run --cert-name'"

echo
echo "RESULT: $pass passed, $failn failed"
(( failn == 0 ))
