#!/usr/bin/env bash
# Offline tests for `gatekeeper proxy-help` and `gatekeeper proxy-check` (deploy/proxy.sh).
# The most important property is proven here: these commands NEVER modify nginx, certbot, Let's Encrypt data,
# Docker, ufw or systemd. Every external command is a stub that logs its call, and the test fails on any call
# that is not on the read-only allow-list; the fake /etc/nginx and /etc/letsencrypt trees are hashed before/after.
#   Run: bash deploy/tests/proxy.test.sh
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ROOT="$(mktemp -d)"
trap '[[ -n "${KEEP_ROOT:-}" ]] || rm -rf "$ROOT"' EXIT
pass=0; failn=0
ck() { local name="$1"; shift; if "$@"; then pass=$((pass + 1)); else failn=$((failn + 1)); echo "  FAIL: $name"; fi; }
t()  { if [[ "$2" == "$3" ]]; then pass=$((pass + 1)); else failn=$((failn + 1)); echo "  FAIL: $1"; echo "     want: [$2]"; echo "      got: [$3]"; fi; }
out_has()  { grep -qF -- "$1" "$OUT"; }
out_lacks() { ! grep -qF -- "$1" "$OUT"; }

command -v openssl >/dev/null || { echo "openssl is needed for these tests"; exit 1; }

FAKE="$ROOT/fake"; SHIM="$ROOT/shim"; LE="$ROOT/le"; NG="$ROOT/nginx"; APP="$ROOT/app"
mkdir -p "$FAKE" "$SHIM" "$LE/live" "$NG/sites-available" "$NG/sites-enabled" "$APP"

# ---------------------------------------------------------------- real test certificates (SAN lists)
mkcert() { # mkcert DIRNAME DAYS NAME...
  local dir="$LE/live/$1" days="$2" san="" n; shift 2
  mkdir -p "$dir"
  for n in "$@"; do san+="DNS:$n,"; done
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$dir/privkey.pem" -out "$dir/fullchain.pem" -days "$days" \
    -subj "/CN=${1}" -addext "subjectAltName=${san%,}" >/dev/null 2>&1
}
mkcert ha.example.com 80 ha.example.com
mkcert wildcard.example.com 80 '*.example.org' example.org
cp "$LE/live/ha.example.com/fullchain.pem" "$ROOT/presented.pem"
echo "an existing site" >"$NG/sites-available/default"; ln -s "$NG/sites-available/default" "$NG/sites-enabled/default"
echo "existing certbot options" >"$LE/options-ssl-nginx.conf"

# ---------------------------------------------------------------- stub commands (all log their calls)
cat >"$SHIM/nginx" <<'EOF'
#!/usr/bin/env bash
echo "nginx $*" >>"$FAKE/calls"
case "$1" in
  -v) echo "nginx version: nginx/${FAKE_NGINX_VERSION:-1.24.0}" >&2 ;;
  -T) echo "# configuration file $FAKE_NGINX_DIR/nginx.conf:"; echo "server { server_name ha.example.com; }"
      [[ -f "$FAKE/nginx.extra" ]] && cat "$FAKE/nginx.extra" ;;
  *) echo "MUTATING nginx $*" >>"$FAKE/mutations" ;;
esac
EOF
cat >"$SHIM/certbot" <<'EOF'
#!/usr/bin/env bash
echo "certbot $*" >>"$FAKE/calls"; echo "MUTATING certbot $*" >>"$FAKE/mutations"
EOF
cat >"$SHIM/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >>"$FAKE/calls"
case "$1" in
  is-active) [[ "$3" == nginx ]] && exit 0; exit 3 ;;
  is-enabled) [[ "$3" == certbot.timer && ! -f "$FAKE/no-timer" ]] && exit 0; exit 1 ;;
  *) echo "MUTATING systemctl $*" >>"$FAKE/mutations" ;;
esac
EOF
cat >"$SHIM/ufw" <<'EOF'
#!/usr/bin/env bash
echo "ufw $*" >>"$FAKE/calls"
[[ "$1" == status ]] && { echo "Status: active"; echo "80/tcp ALLOW Anywhere"; echo "443/tcp ALLOW Anywhere"; exit 0; }
echo "MUTATING ufw $*" >>"$FAKE/mutations"
EOF
cat >"$SHIM/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker $*" >>"$FAKE/calls"; echo "MUTATING docker $*" >>"$FAKE/mutations"; exit 1
EOF
cat >"$SHIM/getent" <<'EOF'
#!/usr/bin/env bash
echo "getent $*" >>"$FAKE/calls"
if [[ "$1" == ahostsv4 && -f "$FAKE/dns4" ]]; then awk -v h="$2" '$1 == h {print $2, "STREAM", h}' "$FAKE/dns4"; fi
if [[ "$1" == ahostsv6 && -f "$FAKE/dns6" ]]; then awk -v h="$2" '$1 == h {print $2, "STREAM", h}' "$FAKE/dns6"; fi
exit 0
EOF
cat >"$SHIM/dpkg-query" <<'EOF'
#!/usr/bin/env bash
echo "dpkg-query $*" >>"$FAKE/calls"
[[ "$*" == *python3-certbot-nginx* && -f "$FAKE/has-nginx-plugin" ]] && { printf 'install ok installed'; exit 0; }
exit 1
EOF
cat >"$SHIM/openssl" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == s_client ]]; then echo "openssl $*" >>"$FAKE/calls"; [[ -f "$FAKE/no-tls" ]] && exit 1; cat "$FAKE/presented.pem"; exit 0; fi
exec /usr/bin/openssl "$@"
EOF
# curl: canned answers by URL (the installer's http_do calls it with -D headers -o body -w '%{http_code}')
cat >"$SHIM/curl" <<'EOF'
#!/usr/bin/env bash
args=("$@"); hdr=""; body=""; url=""; method=GET
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[i]}" in
    -D) hdr="${args[i+1]}" ;; -o) body="${args[i+1]}" ;; -X) method="${args[i+1]}" ;;
  esac
  url="${args[i]}"
done
echo "curl $method $url" >>"$FAKE/calls"
code=200; ctype="application/json"; text='{"ok":true}'; extra=""
case "$url" in
  http://127.0.0.1:*/healthz) ;;
  http://*.example.com/) code=301; extra="Location: https://${url#http://}"; text="" ;;
  https://*/healthz) [[ -f "$FAKE/proxy-502" ]] && { code=502; text="bad gateway"; } ;;
  https://*/admin/login) extra="Set-Cookie: gk_session=abc; Path=/; HttpOnly; ${FAKE_COOKIE_SECURE-Secure}; SameSite=Strict"; text='{"ok":true}' ;;
  https://*/admin/me) text='{"ok":true,"authenticated":true}' ;;
  https://*/) ctype="text/html"; text="<html></html>" ;;
esac
[[ -n "$hdr" ]] && { printf 'HTTP/1.1 %s X\r\ncontent-type: %s\r\n' "$code" "$ctype"; [[ -n "$extra" ]] && printf '%s\r\n' "$extra"; printf '\r\n'; } >"$hdr"
[[ -n "$body" ]] && printf '%s' "$text" >"$body"
printf '%s' "$code"
EOF
chmod +x "$SHIM"/*

# ---------------------------------------------------------------- a case runner (fresh process each time)
reset_world() {
  : >"$FAKE/calls"; : >"$FAKE/mutations"; rm -f "$FAKE/nginx.extra" "$FAKE/no-timer" "$FAKE/has-nginx-plugin" "$FAKE/no-tls" "$FAKE/proxy-502"
  cp "$ROOT/presented.pem" "$FAKE/presented.pem"
  printf 'gk.example.com 203.0.113.7\n' >"$FAKE/dns4"; : >"$FAKE/dns6"
  rm -rf "$APP/proxy"
  printf '%s\n' 'HA_BASE_URL="https://ha.example.com"' 'ADMIN_PASSWORD="correct-horse-battery"' 'GATEKEEPER_MODE="local"' \
    'GATEKEEPER_PUBLIC_URL="https://gk.example.com"' 'GATEKEEPER_PORT="8080"' >"$APP/.env"
}
tree_hash() { (cd "$1" && find . -type f -o -type l | sort | xargs -r sha256sum 2>/dev/null | sha256sum | cut -d' ' -f1); }
run_case() { # run_case NAME 'bash code' ; output -> $OUT
  OUT="$ROOT/out.$1.txt"
  (
    export PATH="$SHIM:$PATH" FAKE GK_SOURCE_ONLY=1 GK_LOG_FILE=/dev/null GK_LETSENCRYPT_DIR="$LE" GK_NGINX_DIR="$NG" \
      FAKE_NGINX_DIR="$NG" GK_PX_SERVER_IP4=203.0.113.7 GK_PX_SERVER_IP6="" HOME="$ROOT/home"
    export NO_COLOR=1
    # shellcheck source=/dev/null
    source "$REPO/install.sh"
    set +e
    NON_INTERACTIVE=true
    APP_DIR="$APP"
    port_in_use() { return 0; }
    port_owner() { echo "nginx (pid 1)"; }
    eval "$2"
  ) >"$OUT" 2>&1
  RC=$?
}
allowed_calls_only() { # every logged call must be read-only
  ! grep -Evq '^(nginx -v|nginx -T|systemctl is-active|systemctl is-enabled|ufw status|dpkg-query -W|getent |openssl s_client|curl (GET|POST) )' "$FAKE/calls"
}

# =============================================================================================== pure helpers
echo "certificate name matching"
run_case pure '
  m() { px_name_matches "$1" "$2" && echo yes || echo no; }
  echo "exact=$(m gk.example.com gk.example.com)"
  echo "case=$(m GK.Example.com gk.example.com)"
  echo "wild=$(m "*.example.com" gk.example.com)"
  echo "wild-apex=$(m "*.example.com" example.com)"
  echo "wild-deep=$(m "*.example.com" a.b.example.com)"
  echo "wild-other=$(m "*.example.org" gk.example.com)"
  echo "other=$(m ha.example.com gk.example.com)"
  px_version_ge 1.24.0 1.25.1 && echo "ver-old=ge" || echo "ver-old=lt"
  px_version_ge 1.25.1 1.25.1 && echo "ver-eq=ge" || echo "ver-eq=lt"
  px_version_ge 1.26.2 1.25.1 && echo "ver-new=ge" || echo "ver-new=lt"
  px_version_ge "" 1.25.1 && echo "ver-none=ge" || echo "ver-none=lt"'
ck "exact name" out_has "exact=yes"; ck "case-insensitive" out_has "case=yes"; ck "wildcard covers one label" out_has "wild=yes"
ck "wildcard does not cover the apex" out_has "wild-apex=no"; ck "wildcard does not cover two labels" out_has "wild-deep=no"
ck "wildcard of another domain" out_has "wild-other=no"; ck "another name" out_has "other=no"
ck "nginx 1.24 is older than 1.25.1" out_has "ver-old=lt"; ck "equal version" out_has "ver-eq=ge"; ck "newer version" out_has "ver-new=ge"; ck "unknown version" out_has "ver-none=lt"

echo "finding an existing certificate"
reset_world
run_case find '
  px_find_cert ha.example.com && echo "A: $PX_CERT_KIND $(basename "$PX_CERT_DIR")" || echo "A: none"
  px_find_cert gk.example.org && echo "B: $PX_CERT_KIND $(basename "$PX_CERT_DIR")" || echo "B: none"
  px_find_cert gk.example.com && echo "C: $PX_CERT_KIND" || echo "C: none"
  px_find_cert example.org && echo "D: $PX_CERT_KIND" || echo "D: none"'
ck "exact certificate found" out_has "A: exact ha.example.com"
ck "wildcard certificate found for a new subdomain" out_has "B: wildcard wildcard.example.com"
ck "no certificate for an unrelated name" out_has "C: none"
ck "wildcard file also covers its apex name" out_has "D: exact"

# =============================================================================================== file generation
echo "the generated nginx files"
reset_world
run_case blocks '
  PX_NGINX_VERSION=1.24.0; px_http_block gk.example.com; echo "=====";
  px_https_block gk.example.com "'"$LE"'/live/gk.example.com" 8080; echo "=====";
  PX_NGINX_VERSION=1.26.0; px_https_block gk.example.com "/x" 9090'
ck "port-80 file has the name" out_has "server_name gk.example.com;"
ck "port-80 file keeps the acme challenge path" out_has "location /.well-known/acme-challenge/"
ck "nginx variables stay literal (\$host)" out_has 'return 301 https://$host$request_uri;'
ck "proxy_pass uses the Gatekeeper port" out_has "proxy_pass http://127.0.0.1:8080;"
ck "no http2 option (cannot change the listeners of your other sites)" out_lacks "http2"
ck "no default_server / ipv6only options" bash -c "! grep -Eq 'default_server|ipv6only' '$OUT'"
ck "IPv4 listen only when nginx does not use IPv6" out_lacks "[::]"
ck "custom port is honoured" out_has "proxy_pass http://127.0.0.1:9090;"
ck "uses certbot's options file when present" out_has "include $LE/options-ssl-nginx.conf;"
ck "forwards the protocol header" out_has 'proxy_set_header X-Forwarded-Proto $scheme;'
ck "points at the certificate for this name" out_has "ssl_certificate     $LE/live/gk.example.com/fullchain.pem;"
# a syntactically valid nginx file: braces balance
ck "braces balance in the final file" bash -c "[[ \$(grep -o '{' '$OUT' | wc -l) -eq \$(grep -o '}' '$OUT' | wc -l) ]]"

echo "choosing the name"
run_case choose '
  CFG[HA_BASE_URL]=https://ha.example.com; CFG[GATEKEEPER_PUBLIC_URL]=""
  echo "1:$(px_choose_host GK.Example.com)"
  echo "2:$(px_choose_host https://gk.example.com/path)"
  px_choose_host ha.example.com >/dev/null; echo "3:rc=$?"
  px_choose_host "not a name" >/dev/null; echo "4:rc=$?"
  px_choose_host "" >/dev/null; echo "5:rc=$?"'
ck "lower-cases" out_has "1:gk.example.com"; ck "strips scheme and path" out_has "2:gk.example.com"
ck "refuses the Home Assistant name" out_has "3:rc=1"; ck "refuses an invalid name" out_has "4:rc=1"; ck "needs a name when not interactive" out_has "5:rc=1"
ck "explains why the HA name is refused" out_has "is the address your Home Assistant is reached on"

# =============================================================================================== proxy-help end to end
echo "proxy-help: read-only, verbose, correct"
reset_world
NG_BEFORE="$(tree_hash "$NG")"; LE_BEFORE="$(tree_hash "$LE")"
run_case help1 'COMMAND_ARGS=(proxy-help gk.example.com); cmd_proxy_help'
t "exit status" 0 "$RC"
for n in 1 2 3 4 5 6 7; do ck "step $n is printed" out_has "STEP $n OF 7"; done
ck "tells the user nothing is changed" out_has "never changes nginx, your certificates, DNS or the firewall"
ck "shows the DNS record to create" out_has "Type  : A"
ck "shows the server's IP as the record value" out_has "Value : 203.0.113.7"
ck "Cloudflare grey-cloud warning" out_has "grey (DNS only)"
ck "certbot rehearsal first" out_has "certbot certonly --webroot -w /var/www/html -d gk.example.com --dry-run"
ck "explains certonly leaves nginx alone" out_has "does not edit any nginx file"
ck "nginx -t before reload, with STOP instruction" out_has "If you see anything else, STOP"
ck "reload, not restart" out_has "sudo systemctl reload nginx"
ck "final file path under sites-available" out_has "$NG/sites-available/gk.example.com"
ck "undo instructions" out_has "To undo everything"
ck "points at proxy-check" out_has "gatekeeper proxy-check gk.example.com"
ck "lists failure causes for certbot" out_has "Timeout during connect"
ck "files were written inside the install dir only" test -f "$APP/proxy/gk.example.com.step-B-https.conf"
ck "DNS already correct is recognised" out_has "gk.example.com already points at this server"
ck "no mutating command was run" test ! -s "$FAKE/mutations"
ck "only allow-listed read-only commands were run" allowed_calls_only
ck "certbot was never executed" bash -c "! grep -q '^certbot' '$FAKE/calls'"
t "fake nginx tree unchanged" "$NG_BEFORE" "$(tree_hash "$NG")"
t "fake letsencrypt tree unchanged" "$LE_BEFORE" "$(tree_hash "$LE")"
ck "written files contain no secrets" bash -c "! grep -rqi 'correct-horse' '$APP/proxy'"

echo "proxy-help: existing certificate / wildcard / name clash / DNS problems"
reset_world
run_case help2 'COMMAND_ARGS=(proxy-help gk.example.org); cmd_proxy_help'
ck "wildcard certificate reused, nothing to issue" out_has "wildcard"
ck "step 4 skipped" out_has "Certificate: already there, skipping"
ck "final file uses the existing wildcard folder" out_has "$LE/live/wildcard.example.com/fullchain.pem"
ck "no certbot command suggested for issuing" out_lacks "certbot certonly"
ck "does not claim the DNS is fine when it is not" out_has "gk.example.org does not resolve yet"

reset_world; printf 'gk.example.com 198.51.100.9\n' >"$FAKE/dns4"
run_case help3 'COMMAND_ARGS=(proxy-help gk.example.com); cmd_proxy_help'
ck "wrong DNS target is called out" out_has "currently points to 198.51.100.9, which is NOT this server"

reset_world; printf 'gk.example.com 203.0.113.7\n' >"$FAKE/dns4"; printf 'gk.example.com 2001:db8::5\n' >"$FAKE/dns6"
run_case help4 'GK_PX_SERVER_IP6=2001:db8::1; px_detect; COMMAND_ARGS=(proxy-help gk.example.com); cmd_proxy_help'
ck "a stray IPv6 record is called out" out_has "(AAAA) record (2001:db8::5) that is NOT this server"

reset_world; printf 'server { server_name gk.example.com; }\n' >"$FAKE/nginx.extra"
run_case help5 'COMMAND_ARGS=(proxy-help gk.example.com); cmd_proxy_help'
ck "an existing server block for the name is detected" out_has "ALREADY has a server block for gk.example.com"

reset_world; touch "$FAKE/has-nginx-plugin"
run_case help6 'COMMAND_ARGS=(proxy-help gk.example.com); cmd_proxy_help'
ck "nginx plugin on disk (apt) -> nginx authenticator offered" out_has "sudo certbot certonly --nginx -d gk.example.com --dry-run"
ck "still no certbot execution" bash -c "! grep -q '^certbot' '$FAKE/calls'"

reset_world; printf 'server { listen [::]:443 ssl; server_name other.example.com; }\n' >"$FAKE/nginx.extra"
run_case help7 'COMMAND_ARGS=(proxy-help gk.example.com); cmd_proxy_help'
ck "IPv6 listen lines appear only when nginx already listens on IPv6" out_has "listen [::]:443 ssl;"
ck "the safety copy is the first thing suggested" out_has "take a safety copy"
ck "the safety copy command is root-only and covers nginx and letsencrypt" out_has "tar czf /root/web-backup-"

reset_world; mkdir -p "$ROOT/nonginx"
run_case help8 'GK_NGINX_DIR="'"$ROOT"'/nonginx"; PX_NGINX_DIR="'"$ROOT"'/nonginx"; COMMAND_ARGS=(proxy-help gk.example.com); cmd_proxy_help'
ck "no sites-enabled / conf.d: a clear explanation, not a crash" out_has "Could not find"
t "still exits 0" 0 "$RC"

# =============================================================================================== proxy-check
echo "proxy-check"
reset_world
NG_BEFORE="$(tree_hash "$NG")"; LE_BEFORE="$(tree_hash "$LE")"
run_case check1 'COMMAND_ARGS=(proxy-check gk.example.com); GK_PX_SERVER_IP4=203.0.113.7; cmd_proxy_check'
ck "all sections are run" bash -c "for n in 1 2 3 4 5 6 7; do grep -q \"^\$n\\. \" '$OUT' || exit 1; done"
ck "DNS pass" out_has "gk.example.com points at this server"
ck "certificate for the wrong name is detected" out_has "is for: ha.example.com"
ck "http redirect checked" out_has "redirects to https://gk.example.com"
ck "login through the proxy works" out_has "Logging in at https://gk.example.com works"
ck "secure cookie checked" out_has "marked Secure"
ck "a failing test gives a fix, not just an error" out_has "nginx is not using your new site file"
ck "overall result is NOT ready" out_has "is NOT ready"
t "non-zero exit when something failed" 1 "$RC"
ck "proxy-check mutates nothing" test ! -s "$FAKE/mutations"
ck "proxy-check only runs read-only commands" allowed_calls_only
t "fake nginx tree unchanged" "$NG_BEFORE" "$(tree_hash "$NG")"
t "fake letsencrypt tree unchanged" "$LE_BEFORE" "$(tree_hash "$LE")"

reset_world; mkcert gk.example.com 80 gk.example.com; cp "$LE/live/gk.example.com/fullchain.pem" "$FAKE/presented.pem"
run_case check2 'COMMAND_ARGS=(proxy-check gk.example.com); cmd_proxy_check'
ck "right certificate: name covered" out_has "covers that name"
ck "certificate validity period reported" out_has "The certificate is valid for another"
ck "healthy setup is reported ready" bash -c "grep -q 'is ready' '$OUT' || grep -q 'works, with' '$OUT'"
ck "no [FAIL] lines in a healthy setup" bash -c "! grep -q '\[FAIL\]' '$OUT'"

reset_world; mkcert gk.example.com 80 gk.example.com; cp "$LE/live/gk.example.com/fullchain.pem" "$FAKE/presented.pem"; touch "$FAKE/proxy-502"
run_case check3 'COMMAND_ARGS=(proxy-check gk.example.com); cmd_proxy_check'
ck "502 explains proxy_pass" out_has "could not reach Gatekeeper (HTTP 502)"

reset_world; mkcert gk.example.com 80 gk.example.com; cp "$LE/live/gk.example.com/fullchain.pem" "$FAKE/presented.pem"
run_case check4 'export FAKE_COOKIE_SECURE=""; COMMAND_ARGS=(proxy-check gk.example.com); cmd_proxy_check'
ck "a cookie that is not Secure is a failure with the cause" out_has "NOT marked Secure"

reset_world; rm -f "$FAKE/dns4"; touch "$FAKE/no-tls"
run_case check5 'COMMAND_ARGS=(proxy-check gk.example.com); cmd_proxy_check'
ck "no DNS record is reported with the record to create" out_has "does not resolve"
ck "no certificate from nginx is reported with next step" out_has "Could not read a certificate from nginx"

# an expired certificate
reset_world
mkdir -p "$ROOT/exp"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$ROOT/exp/k.pem" -out "$ROOT/exp/c.pem" -subj "/CN=gk.example.com" \
  -addext "subjectAltName=DNS:gk.example.com" -days 1 >/dev/null 2>&1
cp "$ROOT/exp/c.pem" "$FAKE/presented.pem"
run_case check6 'COMMAND_ARGS=(proxy-check gk.example.com); cmd_proxy_check'
ck "a certificate close to expiry is flagged" bash -c "grep -Eq 'expires in [0-9]+ day|EXPIRED' '$OUT'"

# =============================================================================================== wiring
echo "wiring"
ck "install.sh dispatches proxy-help" grep -q 'proxy-help) *cmd_proxy_help' "$REPO/install.sh"
ck "install.sh dispatches proxy-check" grep -q 'proxy-check) *cmd_proxy_check' "$REPO/install.sh"
ck "usage text documents both" bash -c "grep -q 'proxy-help \[NAME\]' '$REPO/install.sh' && grep -q 'proxy-check \[NAME\]' '$REPO/install.sh'"
ck "proxy.sh never EXECUTES a mutating certbot/nginx/systemctl/ufw/docker subcommand (quoted text and comments removed first)" bash -c "
  ! sed -E 's/\"([^\"\\\\]|\\\\.)*\"//g; s/#.*//' '$REPO/deploy/proxy.sh' \
    | grep -nE '(^|[^a-zA-Z_.-])(certbot +(certonly|--nginx|renew|delete|install|run)|nginx +(-s|reload)|systemctl +(reload|restart|start|stop|enable|disable)|ufw +(allow|deny|enable|disable|delete|route)|docker +(rm|stop|kill|restart|run|compose))'"
ck "proxy.sh never writes outside its own folder (no redirects into /etc, no tee/cp/mv/rm/ln/chmod on system paths)" bash -c "
  ! sed -E 's/\"([^\"\\\\]|\\\\.)*\"//g; s/#.*//' '$REPO/deploy/proxy.sh' | grep -nE '(^|[ ;|&(])(tee|cp|mv|rm|ln|install|sed -i|truncate|dd) '"

echo
echo "RESULT: $pass passed, $failn failed"
(( failn == 0 ))
