# shellcheck shell=bash
#
# "I already run nginx + Let's Encrypt on this server. Put Gatekeeper on a new subdomain, safely."
#
#   gatekeeper proxy-help [SUBDOMAIN]   a long, step-by-step walkthrough (DNS, certificate, nginx, tests)
#   gatekeeper proxy-check [SUBDOMAIN]  tests the finished setup from every angle and says what to fix
#
# Both are READ-ONLY with respect to your web server and your certificates: they look, explain and test.
# The only thing proxy-help ever writes is two ready-to-copy nginx files under <install dir>/proxy/ (inside
# this install's own folder). Nothing in /etc/nginx, /etc/letsencrypt, DNS or a firewall is changed by it.
#
# Sourced by install.sh (needs its say/ok/warn/hint/ask/confirm/vpass/vwarn/vfail helpers). Defines functions only.

PX_LE_DIR="${GK_LETSENCRYPT_DIR:-/etc/letsencrypt}"
PX_NGINX_DIR="${GK_NGINX_DIR:-/etc/nginx}"
# Folder for Let's Encrypt challenge files of the managed setup (its own folder; /var/www/html is never used or touched).
PX_WEBROOT="${GK_ACME_WEBROOT:-/var/www/ha-gatekeeper-acme}"
# Where the guide's challenge location points (the manual guide uses the common /var/www/html; the managed setup its own folder).
PX_ACME_ROOT="/var/www/html"
# First line of every file the installer writes itself: uninstall only ever deletes files that carry it.
PX_MARK="# Managed by the HA Gatekeeper installer. To remove: sudo gatekeeper uninstall  (or delete this file and its link in sites-enabled, then: sudo nginx -t && sudo systemctl reload nginx)"
PX_MANAGED=false

# ---------------------------------------------------------------------------------------------
# Small output helpers
# ---------------------------------------------------------------------------------------------

px_title() { # px_title "STEP 1 OF 6" "Choose the name"
  $QUIET && return 0
  printf '\n%s%s%s\n' "$C_BOLD$C_CYAN" "------------------------------------------------------------------------" "$C_RESET"
  printf '%s%s  %s%s\n' "$C_BOLD$C_CYAN" "$1" "$2" "$C_RESET"
  printf '%s%s%s\n' "$C_BOLD$C_CYAN" "------------------------------------------------------------------------" "$C_RESET"
  log_file "===== $1 $2"
}

px_cmd() { # a command the person copies and runs themselves
  $QUIET || printf '      %s$ %s%s\n' "$C_BOLD" "$*" "$C_RESET"
  log_file "      \$ $*"
}

px_file() { # print a file's content indented, so it can be copied
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    $QUIET || printf '      %s| %s%s\n' "$C_DIM" "$line" "$C_RESET"
    log_file "      | $line"
  done
}

# ---------------------------------------------------------------------------------------------
# Detection (all read-only)
# ---------------------------------------------------------------------------------------------

PX_SERVER_IP4=""; PX_SERVER_IP6=""
PX_NGINX=""; PX_NGINX_VERSION=""; PX_NGINX_RUNNING=false; PX_NGINX_STYLE=""; PX_NGINX_IPV6=false
PX_CERTBOT=""; PX_CERTBOT_NGINX=false; PX_CERTBOT_RENEWS=""
PX_ACMESH=""
PX_CERT_DIR=""; PX_CERT_NAMES=""; PX_CERT_END=""; PX_CERT_KIND=""

# True if the certbot nginx plugin is installed (apt package, snap, or pip), found by looking at files only.
px_certbot_nginx_plugin_present() {
  local d
  if [[ "${GK_CERTBOT_PLUGIN_SCAN:-}" == stub ]]; then   # test hook: only the stubbed package query counts
    have dpkg-query && dpkg-query -W -f='${Status}' python3-certbot-nginx 2>/dev/null | grep -q 'install ok installed'
    return
  fi
  for d in /usr/lib/python3/dist-packages /usr/lib/python3*/site-packages /usr/local/lib/python3*/dist-packages /usr/local/lib/python3*/site-packages /snap/certbot/current/lib/python3*/site-packages; do
    # shellcheck disable=SC2086
    compgen -G "$d/certbot_nginx" >/dev/null 2>&1 && return 0
  done
  [[ -n "$(compgen -G '/snap/certbot/current/lib/python3*/site-packages/certbot_nginx' 2>/dev/null)" ]] && return 0
  have dpkg-query && dpkg-query -W -f='${Status}' python3-certbot-nginx 2>/dev/null | grep -q 'install ok installed' && return 0
  return 1
}

px_detect() {
  PX_SERVER_IP4="${GK_PX_SERVER_IP4:-}"
  PX_SERVER_IP6="${GK_PX_SERVER_IP6:-}"
  if [[ -z "$PX_SERVER_IP4" && -z "${GK_PX_SERVER_IP4+x}" ]]; then PX_SERVER_IP4="$(public_ip 4 || true)"; fi
  if [[ -z "$PX_SERVER_IP6" && -z "${GK_PX_SERVER_IP6+x}" ]]; then PX_SERVER_IP6="$(public_ip 6 || true)"; fi

  PX_NGINX=""; PX_NGINX_VERSION=""; PX_NGINX_RUNNING=false; PX_NGINX_STYLE=""
  if [[ -n "${GK_NGINX_BIN+x}" ]]; then
    [[ -x "$GK_NGINX_BIN" ]] && PX_NGINX="$GK_NGINX_BIN"   # test hook: a fixed (or missing) nginx binary
  elif have nginx; then
    PX_NGINX="$(command -v nginx)"
  elif [[ -x /usr/sbin/nginx ]]; then
    PX_NGINX=/usr/sbin/nginx
  fi
  if [[ -n "$PX_NGINX" ]]; then
    PX_NGINX_VERSION="$("$PX_NGINX" -v 2>&1 | sed -n 's|.*nginx/\([0-9][0-9.]*\).*|\1|p' | head -n 1)" || true
    if have systemctl && systemctl is-active --quiet nginx 2>/dev/null; then PX_NGINX_RUNNING=true
    elif port_in_use 80 || port_in_use 443; then PX_NGINX_RUNNING=true; fi
  fi
  # Only listen on IPv6 if the existing nginx configuration already does (otherwise a new "listen [::]" line could fail on a
  # server without IPv6). If the configuration cannot be read, stay on IPv4 only: that always works.
  PX_NGINX_IPV6=false
  # (comment lines are ignored: Ubuntu's default site carries commented-out example blocks that mention [::])
  if [[ -n "$PX_NGINX" ]] && px_nginx_config_dump | grep -Ev '^[[:space:]]*#' | grep -Eq 'listen[[:space:]]+\[::\]'; then PX_NGINX_IPV6=true; fi
  if [[ -d "$PX_NGINX_DIR/sites-enabled" ]]; then PX_NGINX_STYLE=sites
  elif [[ -d "$PX_NGINX_DIR/conf.d" ]]; then PX_NGINX_STYLE=confd; fi

  PX_CERTBOT=""; PX_CERTBOT_NGINX=false; PX_CERTBOT_RENEWS=""
  if [[ -n "${GK_CERTBOT_BIN+x}" ]]; then
    [[ -x "$GK_CERTBOT_BIN" ]] && PX_CERTBOT="$GK_CERTBOT_BIN"   # test hook: a fixed (or missing) certbot binary
  elif have certbot; then PX_CERTBOT="$(command -v certbot)"
  elif [[ -x /snap/bin/certbot ]]; then PX_CERTBOT=/snap/bin/certbot; fi
  if [[ -n "$PX_CERTBOT" ]]; then
    # Looked up on disk, never by running certbot: even `certbot plugins` writes logs and takes locks under /var/lib/letsencrypt.
    if px_certbot_nginx_plugin_present; then PX_CERTBOT_NGINX=true; fi
    if have systemctl && { systemctl is-enabled --quiet certbot.timer 2>/dev/null || systemctl is-enabled --quiet snap.certbot.renew.timer 2>/dev/null; }; then
      PX_CERTBOT_RENEWS="a systemd timer"
    elif [[ -f "${GK_CERTBOT_CRON:-/etc/cron.d/certbot}" ]] && grep -q 'certbot' "${GK_CERTBOT_CRON:-/etc/cron.d/certbot}" 2>/dev/null; then
      PX_CERTBOT_RENEWS="a cron job (${GK_CERTBOT_CRON:-/etc/cron.d/certbot})"
    fi
  fi

  PX_ACMESH=""
  local h
  for h in "${HOME:-/root}/.acme.sh/acme.sh" /root/.acme.sh/acme.sh; do
    if [[ -x "$h" ]]; then PX_ACMESH="$h"; break; fi
  done
}

# px_subject_alt_names FILE -> one DNS name per line ('*.example.com' for a wildcard)
px_subject_alt_names() {
  have openssl || return 0
  openssl x509 -noout -ext subjectAltName -in "$1" 2>/dev/null | tr ',' '\n' | sed -n 's/^ *DNS: *//p' | tr -d ' '
}

# px_name_matches NAME HOST -> 0 if the certificate name covers HOST (exact, or a one-label wildcard)
px_name_matches() {
  local name="${1,,}" host="${2,,}"
  [[ "$name" == "$host" ]] && return 0
  if [[ "$name" == \*.* ]]; then
    local parent="${name#\*.}" first="${host%%.*}" rest="${host#*.}"
    [[ "$host" == *.* && "$rest" == "$parent" && -n "$first" ]] && return 0
  fi
  return 1
}

# px_find_cert HOST: is there already a Let's Encrypt (certbot) certificate that covers HOST?
# Sets PX_CERT_DIR (the live/NAME folder), PX_CERT_NAMES, PX_CERT_END, PX_CERT_KIND (exact|wildcard).
px_find_cert() {
  local host="$1" f dir name found
  PX_CERT_DIR=""; PX_CERT_NAMES=""; PX_CERT_END=""; PX_CERT_KIND=""
  have openssl || return 1
  local best_kind=""
  for f in "$PX_LE_DIR"/live/*/fullchain.pem; do
    [[ -f "$f" ]] || continue
    dir="$(dirname "$f")"
    found=""
    while IFS= read -r name; do
      [[ -n "$name" ]] || continue
      if px_name_matches "$name" "$host"; then
        if [[ "$name" == \** ]]; then found=wildcard; else found=exact; fi
        [[ "$found" == exact ]] && break
      fi
    done < <(px_subject_alt_names "$f")
    [[ -n "$found" ]] || continue
    # An exact certificate beats a wildcard one.
    if [[ -z "$best_kind" || ( "$best_kind" == wildcard && "$found" == exact ) ]]; then
      best_kind="$found"
      PX_CERT_DIR="$dir"
      PX_CERT_KIND="$found"
      PX_CERT_NAMES="$(px_subject_alt_names "$f" | tr '\n' ' ')"
      PX_CERT_END="$(openssl x509 -noout -enddate -in "$f" 2>/dev/null | sed 's/^notAfter=//')"
    fi
  done
  [[ -n "$PX_CERT_DIR" ]]
}

# px_nginx_names -> every server_name nginx knows about (needs root; empty otherwise)
px_nginx_config_dump() {
  [[ -n "$PX_NGINX" ]] || return 0
  timeout 20 "$PX_NGINX" -T 2>/dev/null || true
}

# px_nginx_has_host HOST -> prints the file that already has a server block for HOST, if any
px_nginx_has_host() {
  local host="$1" dump
  dump="$(px_nginx_config_dump)"
  [[ -n "$dump" ]] || return 1
  awk -v h="$host" '
    /^# configuration file / { file = $4; sub(/:$/, "", file) }
    {
      rest = $0
      while (match(rest, /server_name[ \t]+[^;]*;/)) {
        names = substr(rest, RSTART, RLENGTH)
        rest = substr(rest, RSTART + RLENGTH)
        sub(/^server_name[ \t]+/, "", names); sub(/;$/, "", names)
        n = split(names, a, /[ \t]+/)
        for (i = 1; i <= n; i++) if (tolower(a[i]) == h) { print file; found = 1; exit }
      }
    }' <<<"$dump" | head -n 1 | grep .
}

# px_version_ge A B (dotted versions) -> 0 if A >= B
px_version_ge() {
  [[ -n "$1" ]] || return 1
  [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n 1)" == "$2" ]]
}

# ---------------------------------------------------------------------------------------------
# DNS
# ---------------------------------------------------------------------------------------------

# px_dns_state HOST -> sets PX_DNS_A, PX_DNS_AAAA and prints nothing
PX_DNS_A=""; PX_DNS_AAAA=""
px_dns_state() {
  PX_DNS_A="$(dns_records "$1" 4 | tr '\n' ' ')"
  PX_DNS_AAAA="$(dns_records "$1" 6 | tr '\n' ' ')"
  PX_DNS_A="${PX_DNS_A% }"; PX_DNS_AAAA="${PX_DNS_AAAA% }"
}

# ---------------------------------------------------------------------------------------------
# Subdomain choice
# ---------------------------------------------------------------------------------------------

px_parent_of() { local h="$1"; [[ "$h" == *.*.* ]] && printf '%s' "${h#*.}" || printf '%s' "$h"; }

px_choose_host() { # px_choose_host [ARG] -> prints the chosen host name, or returns 1
  local host="${1:-}" cur ha_host suggestion
  cur="$(url_host "${CFG[GATEKEEPER_PUBLIC_URL]:-}" 2>/dev/null || true)"
  ha_host="$(url_host "${CFG[HA_BASE_URL]:-}" 2>/dev/null || true)"
  if [[ -z "$host" && -n "$cur" && "$cur" == *.* && "${CFG[GATEKEEPER_PUBLIC_URL]:-}" == https://* ]]; then
    suggestion="$cur"
  elif [[ -n "$ha_host" && "$ha_host" == *.*.* ]]; then
    suggestion="gatekeeper.$(px_parent_of "$ha_host")"
  else
    suggestion="gatekeeper.example.com"
  fi
  if [[ -z "$host" ]]; then
    interactive || { err "Tell me the subdomain: gatekeeper proxy-help gatekeeper.example.com"; return 1; }
    say "  ${C_DIM}A subdomain is a name in front of your domain, for example ${suggestion}.${C_RESET}" >&2
    say "  ${C_DIM}Use a NEW name. Do not reuse the name your Home Assistant already answers on${ha_host:+ ($ha_host)}.${C_RESET}" >&2
    host="$(ask "Subdomain for HA Gatekeeper" "$suggestion")"
  fi
  host="${host,,}"; host="${host#https://}"; host="${host#http://}"; host="${host%%/*}"; host="${host%.}"
  if ! is_domain "$host"; then
    err "'$host' is not a valid name. It looks like  gatekeeper.example.com  (letters, digits and dashes, with dots)."
    return 1
  fi
  if [[ -n "$ha_host" && "$host" == "$ha_host" ]]; then
    err "$host is the address your Home Assistant is reached on. Pick a different, new name for Gatekeeper (for example gatekeeper.$(px_parent_of "$host"))."
    return 1
  fi
  printf '%s' "$host"
}

# ---------------------------------------------------------------------------------------------
# The two nginx files
# ---------------------------------------------------------------------------------------------

px_site_path() { # where the person should install the file
  local host="$1"
  if [[ "$PX_NGINX_STYLE" == confd ]]; then printf '%s/conf.d/%s.conf' "$PX_NGINX_DIR" "$host"
  else printf '%s/sites-available/%s' "$PX_NGINX_DIR" "$host"; fi
}

px_listen_lines() { # px_listen_lines PORT [ssl] -> the listen line(s) for this port (IPv6 only when nginx already uses it)
  local port="$1" ssl="${2:+ ssl}"
  printf '    listen %s%s;\n' "$port" "$ssl"
  if $PX_NGINX_IPV6; then printf '    listen [::]:%s%s;\n' "$port" "$ssl"; fi
}

px_mark_line() { if $PX_MANAGED; then printf '%s\n' "$PX_MARK"; fi; }

px_http_block() { # px_http_block HOST  (step A: port 80 only, so the certificate can be issued)
  px_mark_line
  cat <<EOF
# Gatekeeper, step A: answers on port 80 only.
# It exists so Let's Encrypt can prove you own $1, and it forwards everything else to https.
server {
$(px_listen_lines 80)
    server_name $1;

    # Let's Encrypt writes a small token here (only used by the "webroot" method).
    location /.well-known/acme-challenge/ {
        root $PX_ACME_ROOT;
        default_type "text/plain";
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF
}

# The finished site. Deliberately NO http2/spdy/default_server/ipv6only options: those can change how nginx treats the
# sites you already have on the same ports, and Gatekeeper does not need them.
px_https_block() { # px_https_block HOST CERTDIR PORT
  local host="$1" certdir="$2" port="$3"
  px_mark_line
  cat <<EOF
# Gatekeeper, step B: the finished site. Port 80 redirects to https, port 443 forwards to Gatekeeper.
server {
$(px_listen_lines 80)
    server_name $host;

    location /.well-known/acme-challenge/ {
        root $PX_ACME_ROOT;
        default_type "text/plain";
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
$(px_listen_lines 443 ssl)
    server_name $host;

    ssl_certificate     $certdir/fullchain.pem;
    ssl_certificate_key $certdir/privkey.pem;
EOF
  if [[ -f "$PX_LE_DIR/options-ssl-nginx.conf" ]]; then
    printf '    include %s/options-ssl-nginx.conf;\n' "$PX_LE_DIR"
  else
    printf '    ssl_protocols TLSv1.2 TLSv1.3;\n    ssl_session_cache shared:gatekeeper_ssl:10m;\n    ssl_session_timeout 1d;\n'
  fi
  if [[ -f "$PX_LE_DIR/ssl-dhparams.pem" ]]; then
    printf '    ssl_dhparam %s/ssl-dhparams.pem;\n' "$PX_LE_DIR"
  fi
  cat <<EOF

    # Gatekeeper only needs small requests.
    client_max_body_size 1m;

    location / {
        proxy_pass http://127.0.0.1:$port;
        proxy_http_version 1.1;
        proxy_set_header Host              \$host;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade           \$http_upgrade;
        proxy_set_header Connection        "upgrade";
        proxy_read_timeout 60s;
    }
}
EOF
}

px_write_files() { # px_write_files HOST CERTDIR PORT -> writes <app>/proxy/HOST.{http,https}.conf (own folder only)
  local host="$1" certdir="$2" port="$3" dir="$APP_DIR/proxy"
  mkdir -p "$dir" 2>/dev/null || return 1
  chmod 755 "$dir" 2>/dev/null || true
  px_http_block "$host" >"$dir/$host.step-A-http.conf" || return 1
  px_https_block "$host" "$certdir" "$port" >"$dir/$host.step-B-https.conf" || return 1
  chmod 644 "$dir/$host.step-A-http.conf" "$dir/$host.step-B-https.conf" 2>/dev/null || true
  printf '%s' "$dir"
}

# ---------------------------------------------------------------------------------------------
# gatekeeper proxy-help
# ---------------------------------------------------------------------------------------------

# The read-only commands (proxy-help, proxy-check) must work on a server that is not set up yet: use .env when it exists,
# otherwise the defaults (the name then comes from the command line).
px_load_config_lenient() {
  if [[ -f "$APP_DIR/.env" ]]; then load_runtime_config
  else cfg_defaults; derive_config; fi
}

cmd_proxy_help() {
  px_load_config_lenient
  local host port have_cert=false site enabled certdir dir existing_file
  port="${CFG[GATEKEEPER_PORT]:-8080}"

  banner "HA Gatekeeper on its own subdomain: a step-by-step guide"
  say ""
  say "  This guide is ${C_BOLD}read-only${C_RESET}. It looks at your server, explains what to do and prints the exact"
  say "  commands. ${C_BOLD}It never changes nginx, your certificates, DNS or the firewall.${C_RESET} You run each command"
  say "  yourself, so nothing happens that you did not see first. It is safe to run as often as you like."
  say ""
  say "  ${C_DIM}Why it works this way: your server already has a web server (nginx) that owns ports 80 and 443 and certificates${C_RESET}"
  say "  ${C_DIM}that keep your other sites running. Touching those automatically is how sites get broken, so this guide only${C_RESET}"
  say "  ${C_DIM}adds ONE new, separate file for the new name and leaves every existing file exactly as it is.${C_RESET}"

  host="$(px_choose_host "${COMMAND_ARGS[0]:-}")" || return 1

  # ------------------------------------------------------------------ what is on this server
  px_title "STEP 1 OF 7" "What is already on this server (looking only, changing nothing)"
  px_detect
  say "  Name you chose            : ${C_BOLD}$host${C_RESET}"
  if [[ -n "$PX_SERVER_IP4" ]]; then say "  This server's IPv4 address: ${C_BOLD}$PX_SERVER_IP4${C_RESET}   ${C_DIM}(what the DNS record must point to)${C_RESET}"
  else warn "Could not find out this server's public IPv4 address (no internet?). Look it up in your hosting provider's control panel."; fi
  [[ -z "$PX_SERVER_IP6" ]] || say "  This server's IPv6 address: $PX_SERVER_IP6"

  if [[ -n "$PX_NGINX" ]]; then
    ok "nginx is installed (version ${PX_NGINX_VERSION:-unknown}); it is $($PX_NGINX_RUNNING && echo running || echo not running)"
    case "$PX_NGINX_STYLE" in
      sites) say "      Site files live in $PX_NGINX_DIR/sites-available (each is switched on with a link in sites-enabled)." ;;
      confd) say "      Site files live in $PX_NGINX_DIR/conf.d (every *.conf there is loaded automatically)." ;;
      *)     warn "Could not find $PX_NGINX_DIR/sites-enabled or $PX_NGINX_DIR/conf.d. The files below still work; put them wherever your nginx loads site files from." ;;
    esac
    if existing_file="$(px_nginx_has_host "$host")"; then
      warn "nginx ALREADY has a server block for $host in: $existing_file"
      say "      Do not add a second one (nginx would warn about a conflicting server name). Either choose another name or edit that existing file."
    elif [[ -z "$(px_nginx_config_dump)" ]]; then
      hint "(Could not read nginx's full configuration. Run this guide with sudo to let it check whether the name is already used.)"
    else
      ok "nginx has no server block for $host yet, so adding one cannot clash with anything"
    fi
  else
    warn "nginx was not found on this server. This guide's files are for nginx. For Apache, Traefik or another web server the idea is the same: forward the name to http://127.0.0.1:$port and keep the Host and X-Forwarded-* headers."
  fi

  if [[ -n "$PX_CERTBOT" ]]; then
    ok "certbot (Let's Encrypt) is installed: $PX_CERTBOT"
    if $PX_CERTBOT_NGINX; then say "      The certbot nginx plugin is available."; else hint "The certbot nginx plugin was not listed; the 'webroot' method below works without it."; fi
    if [[ -n "$PX_CERTBOT_RENEWS" ]]; then ok "Automatic renewal is set up through $PX_CERTBOT_RENEWS, so a new certificate renews itself like your existing ones"
    else warn "Could not see an automatic renewal job for certbot. Check with: systemctl list-timers | grep -i certbot"; fi
  else
    say "  certbot was not found."
  fi
  if [[ -n "$PX_ACMESH" ]]; then ok "acme.sh is installed: $PX_ACMESH"; fi
  if [[ -z "$PX_CERTBOT" && -z "$PX_ACMESH" ]]; then
    say "      You have no certificate tool yet. The simplest is certbot. To install it:"
    px_cmd "sudo apt install certbot python3-certbot-nginx"
    say "      ${C_DIM}(That is the only thing in this guide that installs software, and only if you choose to run it.)${C_RESET}"
  fi

  if px_find_cert "$host"; then
    have_cert=true
    certdir="$PX_CERT_DIR"
    ok "A Let's Encrypt certificate that already covers $host exists: $PX_CERT_DIR"
    say "      It is valid for: ${PX_CERT_NAMES:-?}   and expires: ${PX_CERT_END:-unknown}"
    if [[ "$PX_CERT_KIND" == wildcard ]]; then
      say "      It is a ${C_BOLD}wildcard${C_RESET} certificate, so you do NOT need to issue anything new: step 4 is skipped, and the existing"
      say "      certificate keeps renewing exactly as it does today."
    else
      say "      So you do NOT need to issue anything new: step 4 is skipped."
    fi
  else
    certdir="$PX_LE_DIR/live/$host"
    say "  No existing certificate covers $host, so step 4 will issue a new one for just this name."
    say "  ${C_DIM}Your existing certificates are not touched: certbot keeps one separate folder per name.${C_RESET}"
  fi

  say ""
  say "  ${C_BOLD}Before you change anything, take a safety copy${C_RESET} of your nginx and certbot settings (it takes a second):"
  px_cmd "sudo gatekeeper web-backup"
  say "  ${C_DIM}Saved as one root-only file in $APP_DIR/backups (it contains your certificate keys). Put everything back any time with: sudo gatekeeper web-restore${C_RESET}"

  # ------------------------------------------------------------------ DNS
  px_title "STEP 2 OF 7" "DNS: tell the internet that $host lives on this server"
  say "  DNS is the phone book of the internet. You create ${C_BOLD}one record${C_RESET} at the company that manages your domain"
  say "  (where you bought it, or Cloudflare, Vultr DNS, Namecheap, GoDaddy ... wherever the 'DNS records' page is):"
  say ""
  say "      Type  : ${C_BOLD}A${C_RESET}"
  say "      Name  : ${C_BOLD}${host%%.*}${C_RESET}      ${C_DIM}(some providers want the full name $host, some only the first part)${C_RESET}"
  say "      Value : ${C_BOLD}${PX_SERVER_IP4:-<the IPv4 address of this server>}${C_RESET}"
  say "      TTL   : Auto / 300"
  [[ -z "$PX_SERVER_IP6" ]] || say "      ${C_DIM}(Only add an AAAA record with $PX_SERVER_IP6 if your nginx also listens on IPv6; the files below do.)${C_RESET}"
  say ""
  say "  ${C_BOLD}If you use Cloudflare:${C_RESET} set the cloud next to the record to ${C_BOLD}grey (DNS only)${C_RESET}, at least until the certificate is"
  say "  issued. The orange cloud hides your server's address, so Let's Encrypt would reach Cloudflare instead of you."
  say ""
  px_dns_state "$host"
  if [[ -z "$PX_DNS_A" && -z "$PX_DNS_AAAA" ]]; then
    warn "$host does not resolve yet. That is normal if you have not created the record: create it now, wait 1 to 5 minutes, then run this guide again."
  elif [[ -n "$PX_SERVER_IP4" && " $PX_DNS_A " == *" $PX_SERVER_IP4 "* ]]; then
    ok "$host already points at this server ($PX_DNS_A). Nothing to do here."
  elif [[ -n "$PX_DNS_A" ]]; then
    warn "$host currently points to $PX_DNS_A, which is NOT this server (${PX_SERVER_IP4:-unknown})."
    say "      Fix the record's value, wait a few minutes, run this guide again. (If you use Cloudflare's orange cloud this is expected: switch it to grey.)"
  else
    warn "$host has an IPv6 (AAAA) record only ($PX_DNS_AAAA) and no IPv4 record. Add the A record above."
  fi
  if [[ -n "$PX_DNS_AAAA" && -n "$PX_SERVER_IP6" && " $PX_DNS_AAAA " != *" $PX_SERVER_IP6 "* ]]; then
    warn "$host has an IPv6 (AAAA) record ($PX_DNS_AAAA) that is NOT this server ($PX_SERVER_IP6). Browsers prefer IPv6, so fix or delete that AAAA record."
  fi
  say "  ${C_DIM}This check uses this server's own DNS resolver; a very new record can take a few minutes to show up everywhere.${C_RESET}"

  # ------------------------------------------------------------------ open ports
  px_title "STEP 3 OF 7" "Ports 80 and 443 must be reachable from the internet"
  say "  Your other sites already work on these ports, so this is probably already fine. Two places can block them:"
  say "   1. The server's own firewall (ufw). Check with:   ${C_BOLD}sudo ufw status${C_RESET}   (80 and 443 should say ALLOW; 'inactive' is fine)"
  say "   2. Your hosting provider's firewall (Vultr: 'Firewall' in the control panel). 80/tcp and 443/tcp must be allowed there too."
  say "  ${C_DIM}Port 80 matters even though the site uses https: Let's Encrypt checks you over port 80, and renewals do too.${C_RESET}"
  if have ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then
    local p
    for p in 80 443; do
      if ufw status 2>/dev/null | grep -Eq "^${p}(/tcp)?[[:space:]].*ALLOW|^Nginx (Full|HTTP|HTTPS)"; then ok "ufw allows port $p"
      else warn "ufw is active and does not obviously allow port $p. If your other sites work, an 'Nginx Full' rule probably covers it; otherwise: sudo ufw allow $p/tcp"; fi
    done
  fi

  # ------------------------------------------------------------------ write the files
  site="$(px_site_path "$host")"
  enabled="$PX_NGINX_DIR/sites-enabled/$host"
  dir="$(px_write_files "$host" "$certdir" "$port")" || dir=""
  px_title "STEP 4 OF 7" "$($have_cert && echo "Certificate: already there, skipping" || echo "Certificate: issue a new one for $host only")"
  if $have_cert; then
    say "  Nothing to do. The certificate in $certdir already covers $host."
  else
    say "  ${C_BOLD}4a.${C_RESET} Put the small PORT-80 file in place first. certbot needs it to prove that you own $host."
    if [[ -n "$dir" ]]; then
      say "      I wrote it for you (inside Gatekeeper's own folder, not in nginx): $dir/$host.step-A-http.conf"
      say "      Install it:"
      if [[ "$PX_NGINX_STYLE" == confd ]]; then
        px_cmd "sudo cp $dir/$host.step-A-http.conf $site"
      else
        px_cmd "sudo cp $dir/$host.step-A-http.conf $site"
        px_cmd "sudo ln -s $site $enabled"
      fi
    fi
    say "      Its content (so you can see exactly what you are adding):"
    px_http_block "$host" | px_file
    say ""
    say "  ${C_BOLD}4b.${C_RESET} Make the folder for the 'webroot' method (harmless if it exists), then ${C_BOLD}test nginx before reloading${C_RESET}:"
    px_cmd "sudo mkdir -p /var/www/html"
    px_cmd "sudo nginx -t"
    say "      You must see:  ${C_GREEN}syntax is ok${C_RESET}  and  ${C_GREEN}test is successful${C_RESET}. ${C_BOLD}If you see anything else, STOP${C_RESET}: do not reload."
    say "      Undo with:  sudo rm $site${enabled:+ $enabled}  then  sudo nginx -t  again. Your other sites are unaffected either way."
    say ""
    say "  ${C_BOLD}4c.${C_RESET} Reload nginx. (A reload keeps every existing connection and site up; it is not a restart.)"
    px_cmd "sudo systemctl reload nginx"
    say ""
    say "  ${C_BOLD}4d.${C_RESET} Issue the certificate. First a ${C_BOLD}rehearsal${C_RESET} that changes nothing and uses Let's Encrypt's practice server,"
    say "      so a typo cannot use up your weekly limit of real certificates:"
    if [[ -n "$PX_ACMESH" && -z "$PX_CERTBOT" ]]; then
      px_cmd "$PX_ACMESH --issue --test -d $host -w /var/www/html"
      say "      If that says 'Cert success', do it for real, then install the files where nginx will read them:"
      px_cmd "$PX_ACMESH --issue --force -d $host -w /var/www/html"
      px_cmd "sudo mkdir -p /etc/ssl/gatekeeper"
      px_cmd "$PX_ACMESH --install-cert -d $host --key-file /etc/ssl/gatekeeper/$host.key --fullchain-file /etc/ssl/gatekeeper/$host.pem --reloadcmd 'systemctl reload nginx'"
      say "      ${C_DIM}(acme.sh renews it later by itself and runs that reload command; with acme.sh the step-B file must use these two paths${C_RESET}"
      say "      ${C_DIM}instead of the /etc/letsencrypt ones: /etc/ssl/gatekeeper/$host.pem and /etc/ssl/gatekeeper/$host.key.)${C_RESET}"
    else
      if $PX_CERTBOT_NGINX || [[ -z "$PX_CERTBOT" ]]; then
        px_cmd "sudo certbot certonly --nginx -d $host --dry-run"
        say "      If it ends with 'The dry run was successful', do it for real:"
        px_cmd "sudo certbot certonly --nginx -d $host"
      else
        px_cmd "sudo certbot certonly --webroot -w /var/www/html -d $host --dry-run"
        say "      If it ends with 'The dry run was successful', do it for real:"
        px_cmd "sudo certbot certonly --webroot -w /var/www/html -d $host"
      fi
      say "      ${C_BOLD}certonly${C_RESET} means 'only fetch the certificate'. It does ${C_BOLD}not${C_RESET} edit any nginx file (unlike 'certbot --nginx' without certonly)."
      say "      It will ask for an e-mail address (expiry warnings) and to accept the terms; answering is safe."
    fi
    say ""
    say "      ${C_BOLD}If it fails:${C_RESET}"
    say "       - 'DNS problem: NXDOMAIN' or 'no valid A records': step 2 is not finished. Wait a few minutes and retry."
    say "       - 'Timeout during connect' or 'Connection refused': port 80 is blocked (step 3) or the name points elsewhere."
    say "       - 'Invalid response ... 404/301': the step A file is not active. Check that nginx -t passed and nginx was reloaded."
    say "       - 'too many certificates / rate limit': Let's Encrypt allows only a few real attempts per week; wait, and use --dry-run."
  fi

  # ------------------------------------------------------------------ final site file
  px_title "STEP 5 OF 7" "The finished site file (https, forwarding to Gatekeeper)"
  say "  This ${C_BOLD}replaces${C_RESET} the step A file (it contains the same port-80 part plus the https part), so you still add only one file:"
  if [[ -n "$dir" ]]; then
    say "      I wrote it for you: $dir/$host.step-B-https.conf"
    px_cmd "sudo cp $dir/$host.step-B-https.conf $site"
    if [[ "$PX_NGINX_STYLE" != confd ]]; then say "      ${C_DIM}(The link in sites-enabled from step 4 already points at that file; make it only if you skipped step 4:  sudo ln -s $site $enabled)${C_RESET}"; fi
  fi
  say "      Its content:"
  px_https_block "$host" "$certdir" "$port" | px_file
  say ""
  say "  What the important lines do:"
  say "    - ${C_BOLD}proxy_pass http://127.0.0.1:$port${C_RESET}  Gatekeeper only listens on this server itself, never on the internet; nginx is the front door."
  say "    - ${C_BOLD}X-Forwarded-For / X-Forwarded-Proto${C_RESET}  lets Gatekeeper see the visitor's real address and know the connection was https (secure cookies)."
  say "    - ${C_BOLD}ssl_certificate${C_RESET}  points at the certificate for this name only."
  say "  Then, exactly as before: test first, reload second."
  px_cmd "sudo nginx -t"
  px_cmd "sudo systemctl reload nginx"
  if ! $have_cert; then
    say "  ${C_DIM}If the certificate in step 4 was issued under a name other than $host, change the two ssl_certificate lines to match 'sudo certbot certificates'.${C_RESET}"
  fi

  # ------------------------------------------------------------------ gatekeeper side
  px_title "STEP 6 OF 7" "Tell Gatekeeper its public address"
  if [[ "${CFG[GATEKEEPER_PUBLIC_URL]:-}" == "https://$host" ]]; then
    ok "Gatekeeper already knows its address is https://$host and is set to trust one proxy in front of it."
  else
    warn "Gatekeeper's configured public address is '${CFG[GATEKEEPER_PUBLIC_URL]:-none}', not https://$host."
    say "      The address is used for the login cookie and for which websites may call the API (CORS), so it has to match. Set it by running:"
    px_cmd "sudo gatekeeper install --reconfigure"
    say "      and choose option 3 (private, behind my own web server), then enter  https://$host  when asked. It keeps your data and secrets."
  fi
  if [[ "${CFG[TRUST_PROXY]:-}" != 1 ]]; then
    warn "TRUST_PROXY is not set. Choosing an https:// address as above sets it for you."
  fi

  # ------------------------------------------------------------------ test
  px_title "STEP 7 OF 7" "Test everything"
  say "  When steps 2 to 6 are done, run the automatic check. It tests DNS, the certificate (name, chain, expiry, renewal),"
  say "  the redirect from http to https, the connection through nginx to Gatekeeper, login and the cookie, and tells you what to fix:"
  px_cmd "sudo gatekeeper proxy-check $host"
  say "  It is read-only and safe to repeat after every fix."
  say ""
  say "  ${C_BOLD}To undo everything${C_RESET} (your other sites are never involved):"
  px_cmd "sudo rm $site${enabled:+ $enabled}"
  px_cmd "sudo nginx -t && sudo systemctl reload nginx"
  say "  Optionally delete the DNS record, and the certificate:  sudo certbot delete --cert-name $host"
  say ""
  return 0
}

# ---------------------------------------------------------------------------------------------
# gatekeeper proxy-check
# ---------------------------------------------------------------------------------------------

# px_tls_probe HOST ADDR -> prints "subject|issuer|notAfter|sanlist" for the certificate nginx presents (SNI = HOST)
px_tls_probe() {
  have openssl || return 1
  local pem
  pem="$(printf '' | timeout 15 openssl s_client -servername "$1" -connect "$2:443" 2>/dev/null | sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' | sed '/-----END CERTIFICATE-----/q')" || true
  [[ -n "$pem" ]] || return 1
  local issuer enddate sans
  issuer="$(openssl x509 -noout -issuer <<<"$pem" 2>/dev/null | sed 's/^issuer= *//')"
  enddate="$(openssl x509 -noout -enddate <<<"$pem" 2>/dev/null | sed 's/^notAfter=//')"
  sans="$(openssl x509 -noout -ext subjectAltName <<<"$pem" 2>/dev/null | tr ',' '\n' | sed -n 's/^ *DNS: *//p' | tr -d ' ' | tr '\n' ' ')"
  printf '%s|%s|%s' "$issuer" "$enddate" "$sans"
}

px_days_until() { # px_days_until "Mon DD HH:MM:SS YYYY GMT" -> integer days (negative if past)
  local end now
  end="$(date -u -d "$1" +%s 2>/dev/null)" || return 1
  now="$(date -u +%s)"
  printf '%s' $(( (end - now) / 86400 ))
}

# px_checks HOST: sections 1-7 (counts into V_PASS/V_WARN/V_FAIL). Used by proxy-check and, for the managed setup, by verify.
# Read-only, except that the managed setup (PX_RENEW_DRYRUN=true) also rehearses renewal against Let's Encrypt's staging server.
PX_RENEW_DRYRUN=false
px_checks() {
  local host="$1" port base cert_info issuer enddate sans days name_ok n code addr
  port="${CFG[GATEKEEPER_PORT]:-8080}"
  base="https://$host"
  px_detect

  vsection "1. Gatekeeper itself"
  if http_do GET "http://127.0.0.1:$port/healthz" "" --max-time 8 && [[ "$LAST_CODE" == 200 ]]; then
    vpass "Gatekeeper answers on this server (127.0.0.1:$port) and reports healthy"
  else
    vfail "Gatekeeper does not answer on 127.0.0.1:$port (${LAST_ERR:-HTTP ${LAST_CODE:-none}})" "Run: sudo gatekeeper status   then   sudo gatekeeper logs"
  fi

  vsection "2. DNS"
  px_dns_state "$host"
  if [[ -z "$PX_DNS_A" && -z "$PX_DNS_AAAA" ]]; then
    vfail "$host does not resolve" "Create the A record (type A, name ${host%%.*}, value ${PX_SERVER_IP4:-the IP of this server}); wait a few minutes. See: gatekeeper proxy-help $host"
  elif [[ -z "$PX_SERVER_IP4" ]]; then
    vwarn "$host resolves to ${PX_DNS_A:-$PX_DNS_AAAA}, but this server's own public address could not be determined to compare" "Make sure that is this server's IP in your provider's control panel"
  elif [[ " $PX_DNS_A " == *" $PX_SERVER_IP4 "* ]]; then
    vpass "$host points at this server ($PX_DNS_A)"
  elif [[ -n "$PX_DNS_A" ]]; then
    vfail "$host points to $PX_DNS_A, not this server ($PX_SERVER_IP4)" "Fix the A record (Cloudflare: use the grey cloud). Then wait a few minutes"
  else
    vfail "$host has only an IPv6 record" "Add the IPv4 (A) record for $PX_SERVER_IP4"
  fi
  if [[ -n "$PX_DNS_AAAA" && -n "$PX_SERVER_IP6" && " $PX_DNS_AAAA " != *" $PX_SERVER_IP6 "* ]]; then
    vwarn "$host has an IPv6 (AAAA) record ($PX_DNS_AAAA) that is not this server" "Browsers prefer IPv6, so visitors would land elsewhere. Fix or delete the AAAA record"
  fi

  vsection "3. nginx and the certificate it presents for $host"
  addr=127.0.0.1
  if ! port_in_use 443; then
    vfail "Nothing is listening on port 443 on this server" "Is nginx running? sudo systemctl status nginx. Did you reload it after adding the site file?"
  else
    vpass "Something is listening on port 443 ($(port_owner 443 || echo 'unknown program'))"
    if cert_info="$(px_tls_probe "$host" "$addr")"; then
      IFS='|' read -r issuer enddate sans <<<"$cert_info"
      name_ok=false
      for n in $sans; do px_name_matches "$n" "$host" && name_ok=true; done
      if $name_ok; then vpass "The certificate nginx presents for $host covers that name ($sans)"
      else vfail "The certificate nginx presents for $host is for: ${sans:-(no names)}, not $host" "nginx is not using your new site file for this name: check server_name in the file, run sudo nginx -t, reload nginx. (A different certificate here usually means the default site answered.)"; fi
      if days="$(px_days_until "$enddate")"; then
        if (( days < 0 )); then vfail "The certificate EXPIRED ${days#-} day(s) ago ($enddate)" "Renew: sudo certbot renew   then   sudo systemctl reload nginx"
        elif (( days < 14 )); then vwarn "The certificate expires in $days day(s) ($enddate)" "Check that renewal works: sudo certbot renew --dry-run"
        else vpass "The certificate is valid for another $days days (until $enddate)"; fi
      fi
      say "        ${C_DIM}issued by: ${issuer:-unknown}${C_RESET}"
    else
      vfail "Could not read a certificate from nginx on port 443 for $host" "nginx may not have a https server block for this name yet. See step 5 of: gatekeeper proxy-help $host"
    fi
  fi

  vsection "4. The full trip: browser to nginx to Gatekeeper"
  # (a) on this server, bypassing DNS: proves nginx + certificate chain + proxy_pass
  local local_ok=false
  if http_do GET "$base/healthz" "" --resolve "$host:443:127.0.0.1" --max-time 12 && [[ "$LAST_CODE" == 200 ]]; then
    local_ok=true
    vpass "https://$host/healthz through nginx reached Gatekeeper (certificate chain, name and forwarding all fine)"
  else
    code="${LAST_CODE:-none}"
    case "$code" in
      502|504) vfail "nginx answered but could not reach Gatekeeper (HTTP $code)" "The proxy_pass line must say http://127.0.0.1:$port. Check: sudo gatekeeper status" ;;
      404) vfail "nginx answered 404 for $host" "Another site is answering for this name. Check server_name in your file and that it is linked in sites-enabled; sudo nginx -T | grep -n server_name" ;;
      none|000) vfail "Could not complete a https request to nginx on this server (${LAST_ERR:-no response})" "Often an untrusted/wrong certificate or nginx not reloaded. Details above in section 3. Try: curl -v --resolve $host:443:127.0.0.1 $base/healthz" ;;
      *) vfail "https://$host/healthz answered HTTP $code instead of 200 (${LAST_ERR:-})" "Check the nginx error log: sudo tail -n 30 /var/log/nginx/error.log" ;;
    esac
  fi
  # (b) the real public route (only meaningful once the trip on this server works)
  if ! $local_ok; then
    say "  ${C_DIM}(The test over the real internet route is skipped until the one above passes: fix that first.)${C_RESET}"
  elif http_do GET "$base/healthz" "" --max-time 15 && [[ "$LAST_CODE" == 200 ]]; then
    vpass "The same request over the real internet route (DNS, then your provider's firewall) also works"
  else
    vwarn "The request over the real internet route did not work (${LAST_ERR:-HTTP ${LAST_CODE:-none}}), although it works on this server" "The problem is outside this server: DNS not updated yet, your provider's firewall (80/443), or a provider that does not let a server call its own public address. Test from your phone's mobile network to be sure"
  fi
  # http -> https redirect
  if http_do GET "http://$host/" "" --resolve "$host:80:127.0.0.1" --max-time 10; then
    if [[ "$LAST_CODE" =~ ^30[1278]$ ]] && grep -qi "^location: https://$host" <<<"$LAST_HEADERS"; then
      vpass "http://$host redirects to https://$host (HTTP $LAST_CODE)"
    else
      vwarn "http://$host answered HTTP $LAST_CODE and does not redirect to https" "Add the port-80 server block from step 5 so nobody lands on an insecure page"
    fi
  else
    vwarn "Port 80 for $host did not answer here (${LAST_ERR:-no response})" "Let's Encrypt needs port 80 for renewals. Check the port-80 part of the site file and that nginx listens on 80"
  fi
  # headers that show the app is really behind this host
  if ! $local_ok; then
    :
  elif http_do GET "$base/" "" --resolve "$host:443:127.0.0.1" --max-time 12 && [[ "$LAST_CODE" == 200 ]]; then
    if grep -qi '^content-type: *text/html' <<<"$LAST_HEADERS"; then vpass "The dashboard page loads at $base/"
    else vwarn "$base/ answered 200 but not with a web page" "Check which site is answering for this name (sudo nginx -T | grep -n server_name)"; fi
  else
    vwarn "$base/ did not return the dashboard (HTTP ${LAST_CODE:-none})" "See the failures above first"
  fi

  vsection "5. Login through the proxy (proves cookies and forwarding headers survive)"
  if ! $local_ok; then
    say "  ${C_DIM}(Skipped until section 4 passes.)${C_RESET}"
  elif [[ -z "${CFG[ADMIN_PASSWORD]:-}" ]]; then
    vwarn "The admin password is not in $APP_DIR/.env, so the login test was skipped" "Open $base in a browser and log in yourself"
  else
    local rc=0
    admin_login "$base" --resolve "$host:443:127.0.0.1" || rc=$?
    case "$rc" in
      0)
        vpass "Logging in at $base works"
        if grep -qi 'secure' <<<"$COOKIE_ATTRS"; then vpass "The login cookie is marked Secure (browsers only send it over https)"
        else vfail "The login cookie is NOT marked Secure" "Usually nginx is not sending  proxy_set_header X-Forwarded-Proto \$scheme;  or Gatekeeper does not trust one proxy (TRUST_PROXY=1). See: gatekeeper proxy-help $host"; fi
        if grep -qi 'httponly' <<<"$COOKIE_ATTRS"; then vpass "The login cookie is HttpOnly (scripts in a page cannot read it)"; fi
        if http_do GET "$base/admin/me" "" --resolve "$host:443:127.0.0.1" && grep -q '"authenticated":true' <<<"$LAST_BODY"; then
          vpass "The login stays valid on the next request (the cookie survives the proxy)"
        else
          vfail "Logged in, but the next request was not recognised as logged in" "Usually the cookie is not being stored because the address Gatekeeper expects differs from $base. Re-run: sudo gatekeeper install --reconfigure"
        fi
        ;;
      4) vpass "The password was accepted and the two-factor step is waiting for a code, as it should (login test stops here)" ;;
      2) if [[ "$LAST_CODE" == 401 || "$LAST_CODE" == 403 ]]; then
           vfail "The proxy reached Gatekeeper but the admin password was rejected" "Check ADMIN_PASSWORD in $APP_DIR/.env"
         else
           vfail "The login request got HTTP ${LAST_CODE:-none} instead of a login result" "Check: sudo gatekeeper logs   and the nginx error log: sudo tail -n 30 /var/log/nginx/error.log"
         fi ;;
      3) vfail "Login worked but no cookie came back through the proxy" "nginx is stripping Set-Cookie? Check that the location block does not contain proxy_hide_header Set-Cookie" ;;
      *) vfail "Login request did not get through the proxy" "See section 4" ;;
    esac
  fi

  vsection "6. Gatekeeper's own settings for this name"
  if [[ "${CFG[GATEKEEPER_PUBLIC_URL]:-}" == "$base" ]]; then
    vpass "Gatekeeper's public address is $base (cookies and CORS match)"
  else
    vwarn "Gatekeeper's public address is '${CFG[GATEKEEPER_PUBLIC_URL]:-none}', not $base" "Run: sudo gatekeeper install --reconfigure   (option 3, then enter $base)"
  fi
  if [[ "${CFG[TRUST_PROXY]:-}" == 1 ]]; then vpass "Gatekeeper trusts one proxy in front of it (it sees real visitor addresses)"
  else vwarn "TRUST_PROXY is not set" "Setting an https:// public address in the installer turns it on"; fi

  vsection "7. Renewal (so the certificate does not expire in 90 days)"
  if [[ -n "$PX_CERTBOT" ]]; then
    if [[ -n "$PX_CERTBOT_RENEWS" ]]; then vpass "certbot renews automatically through $PX_CERTBOT_RENEWS"
    elif [[ -e "${GK_CERT_RENEW_UNIT:-/etc/systemd/system/ha-gatekeeper-cert-renew.timer}" || -e "${GK_CERT_RENEW_CRON:-/etc/cron.d/ha-gatekeeper-cert-renew}" ]]; then
      vpass "This certificate renews automatically through the renewal job the installer added for $host"
    else vwarn "No automatic certbot renewal job was found" "Check: systemctl list-timers | grep -i certbot   (certbot normally installs one)"; fi
    if $PX_RENEW_DRYRUN; then
      if timeout 180 "$PX_CERTBOT" renew --dry-run --cert-name "$host" >>"$LOG_FILE" 2>&1; then
        vpass "A rehearsal of renewal for $host succeeded (Let's Encrypt staging server; nothing was changed)"
      else
        vfail "A rehearsal of renewal for $host FAILED, so the certificate would expire in about 90 days" "See: sudo tail -n 40 /var/log/letsencrypt/letsencrypt.log  (usually port 80 or the challenge folder $PX_WEBROOT is not reachable)"
      fi
    else
      say "        ${C_DIM}For a full rehearsal of renewal (changes nothing): sudo certbot renew --dry-run --cert-name $host${C_RESET}"
    fi
  elif [[ -n "$PX_ACMESH" ]]; then
    vpass "acme.sh is installed; it renews through its own cron job (check: crontab -l | grep acme)"
  else
    vwarn "Neither certbot nor acme.sh was found on this server" "If the certificate comes from somewhere else (a panel, a load balancer), make sure it renews there"
  fi
}

cmd_proxy_check() {
  px_load_config_lenient
  local host base
  host="$(px_choose_host "${COMMAND_ARGS[0]:-${CFG[GATEKEEPER_PUBLIC_URL]:+$(url_host "${CFG[GATEKEEPER_PUBLIC_URL]}")}}")" || return 1
  base="https://$host"
  V_PASS=0; V_WARN=0; V_FAIL=0
  banner "Checking $host"
  say "  Read-only: this only looks and tests, it changes nothing. Each line says what was tested and, if it failed, what to do."
  px_checks "$host"

  say ""
  if (( V_FAIL > 0 )); then
    banner "$host is NOT ready: $V_FAIL problem(s), $V_WARN warning(s)"
    say "  Fix the [FAIL] lines from the top (each says what to do), then run again:  sudo gatekeeper proxy-check $host"
    return 1
  elif (( V_WARN > 0 )); then
    banner "$host works, with $V_WARN warning(s) worth a look"
    return 0
  fi
  banner "$host is ready: $V_PASS checks passed"
  say "  Open $base in your browser and log in. API base URL for agents: $base"
  return 0
}

# =============================================================================================================
# The OPTIONAL managed setup: the installer does the nginx site + certificate for you, with you watching.
# (Choice 1 in the installer. Choice 2 prints the same steps as commands to run yourself: gatekeeper proxy-help.)
#
# Principles:
#   * a complete plan of exact files and commands is shown before anything changes, and needs your yes;
#   * a safety copy of your nginx and certbot settings is taken before the first change and is never deleted;
#   * ONE new site file for the new name, its own challenge folder, a certificate for that name only;
#     existing sites, existing certificates, existing renewal jobs are never edited;
#   * `nginx -t` runs before every reload, and a reload never happens when it fails;
#   * every step is journaled; any failure undoes the file changes (the new certificate is kept on purpose, with
#     the one command that deletes it, so a retry does not burn Let's Encrypt's weekly limits).
# =============================================================================================================

P_PROXY=false
P_PROXY_CERT=""            # issue | reuse
P_PROXY_CERT_DIR=""
P_PROXY_RENEW_JOB=false    # add a renewal job just for this certificate (only when the server has none)
P_PROXY_CERTBOT_PKG=false  # certbot has to be installed (apt)
P_PROXY_SITE=""; P_PROXY_LINK=""
PX_HOST=""

PX_RENEW_SERVICE_NAME="ha-gatekeeper-cert-renew.service"
PX_RENEW_TIMER_NAME="ha-gatekeeper-cert-renew.timer"
px_renew_timer_path() { printf '%s/%s' "${SYSTEMD_DIR:-/etc/systemd/system}" "$PX_RENEW_TIMER_NAME"; }
px_renew_service_path() { printf '%s/%s' "${SYSTEMD_DIR:-/etc/systemd/system}" "$PX_RENEW_SERVICE_NAME"; }
px_renew_cron_path() { printf '%s' "${GK_CERT_RENEW_CRON:-/etc/cron.d/ha-gatekeeper-cert-renew}"; }

px_managed_host() { url_host "${CFG[GATEKEEPER_PUBLIC_URL]:-}" 2>/dev/null || true; }
px_managed() { [[ "${CFG[PROXY_SETUP]:-}" == nginx && "${CFG[GATEKEEPER_MODE]:-}" == local && "${CFG[GATEKEEPER_PUBLIC_URL]:-}" == https://* ]]; }

px_nginx_running() { have_systemd && systemctl is-active --quiet nginx 2>/dev/null || port_in_use 443 || port_in_use 80; }

# --- undo helpers -----------------------------------------------------------------------------------------


# --- safety copy of nginx + certbot settings ---------------------------------------------------------------






# --- DNS (Namecheap hand-holding) ---------------------------------------------------------------------------

px_dns_matches() { # px_dns_matches HOST -> 0 when it resolves to this server's IPv4
  px_dns_state "$1"
  [[ -n "$PX_SERVER_IP4" && " $PX_DNS_A " == *" $PX_SERVER_IP4 "* ]]
}

px_dns_instructions() { # px_dns_instructions HOST
  local host="$1" label="${1%%.*}" domain="${1#*.}"
  say ""
  say "  ${C_BOLD}Point $host at this server (one DNS record, at Namecheap):${C_RESET}"
  say "    1. Log in to Namecheap, open ${C_BOLD}Domain List${C_RESET}, click ${C_BOLD}MANAGE${C_RESET} next to ${C_BOLD}$domain${C_RESET}."
  say "    2. Open the ${C_BOLD}Advanced DNS${C_RESET} tab and click ${C_BOLD}ADD NEW RECORD${C_RESET}."
  say "    3. Fill in exactly:"
  say "         Type  : ${C_BOLD}A Record${C_RESET}"
  say "         Host  : ${C_BOLD}$label${C_RESET}"
  say "         Value : ${C_BOLD}${PX_SERVER_IP4:-<the IPv4 address of this server>}${C_RESET}"
  say "         TTL   : Automatic"
  say "    4. Click the green ${C_BOLD}checkmark${C_RESET} to save."
  say "  ${C_DIM}If $domain does not use Namecheap's own nameservers (Domain tab: 'Nameservers'; for example it uses Cloudflare), add the same${C_RESET}"
  say "  ${C_DIM}record there instead, as 'DNS only' (grey cloud). Changes normally show up within 1 to 5 minutes, sometimes up to 30.${C_RESET}"
  say "  ${C_DIM}Do not touch any other record: your other sites keep working exactly as they do now.${C_RESET}"
}

# px_dns_wait HOST: show the instructions if needed, then wait (you press Enter to re-check) until it points here.
px_dns_wait() {
  local host="$1" answer tries=0
  px_detect
  if px_dns_matches "$host"; then ok "$host already points at this server ($PX_DNS_A): nothing to do at Namecheap"; return 0; fi
  if [[ -z "$PX_SERVER_IP4" ]]; then
    warn "I could not find out this server's public IPv4 address (no internet?), so I cannot check the DNS record."
    interactive || return 1
    confirm "Is $host already pointing at this server?" n && return 0
    return 1
  fi
  px_dns_instructions "$host"
  interactive || return 1
  while true; do
    tries=$((tries + 1))
    # Never wait forever: a closed terminal (end of input) or a very long wait ends this, so the install lock is released.
    if (( tries > 300 )); then warn "Giving up waiting for the DNS record. Nothing was changed."; return 1; fi
    answer="$(ask_or_quit "Press Enter to check the record now (type q to stop)" "")" || { warn "The terminal was closed while waiting. Nothing was changed."; return 1; }
    [[ "$answer" != q && "$answer" != Q ]] || return 1
    if px_dns_matches "$host"; then ok "$host now points at this server ($PX_DNS_A). Good."; return 0; fi
    if [[ -z "$PX_DNS_A" && -z "$PX_DNS_AAAA" ]]; then
      warn "$host does not resolve yet. If you just saved the record, wait a minute or two and press Enter again."
    else
      warn "$host currently points to ${PX_DNS_A:-$PX_DNS_AAAA}, not to this server (${PX_SERVER_IP4}). Fix the value of the record, wait a minute, press Enter."
    fi
    (( tries % 4 != 0 )) || px_dns_instructions "$host"
  done
}

# --- the wizard question -------------------------------------------------------------------------------------

px_describe_server() { # one-glance summary of what was found, for the question
  px_detect
  local host="$1"
  if [[ -n "$PX_NGINX" ]]; then say "    nginx           : installed${PX_NGINX_VERSION:+ (version $PX_NGINX_VERSION)}, $($PX_NGINX_RUNNING && echo running || echo 'not running')"
  else say "    nginx           : not found"; fi
  if [[ -n "$PX_CERTBOT" ]]; then say "    certbot         : installed${PX_CERTBOT_RENEWS:+, renews through $PX_CERTBOT_RENEWS}"
  elif [[ -n "$PX_ACMESH" ]]; then say "    acme.sh         : installed (certbot is not)"
  else say "    certificates    : no certbot or acme.sh found"; fi
  if px_find_cert "$host"; then say "    certificate     : one that covers $host already exists (${PX_CERT_KIND}, expires ${PX_CERT_END:-?})"
  else say "    certificate     : none for $host yet"; fi
}

px_wizard_proxy() {
  local host choice def=2 email
  [[ "${CFG[GATEKEEPER_PUBLIC_URL]:-}" == https://* ]] || { CFG[PROXY_SETUP]=""; return 0; }
  host="$(px_managed_host)"
  say ""
  say "${C_BOLD}The nginx site and HTTPS certificate for $host${C_RESET}   ${C_DIM}(everything here is optional)${C_RESET}"
  say "  What I found on this server:"
  px_describe_server "$host"
  [[ -n "$PX_NGINX" ]] && def=1
  say ""
  say "  How do you want to do this?"
  say "   ${C_BOLD}1)${C_RESET} Do it for me, with you watching. First I show every file and command and save a safety copy of your nginx and"
  say "      certbot settings; it needs your yes; nothing existing is edited (one new site file + a certificate for $host only);"
  say "      and everything is undone automatically if anything fails."
  say "   ${C_BOLD}2)${C_RESET} I will do it myself: show me the exact commands for the setup you have (nothing is changed on this server)."
  say "   ${C_BOLD}3)${C_RESET} Skip this: it is already done, or I will deal with it later."
  while true; do
    choice="$(ask_or_quit "Your choice" "$def")" || die "The terminal was closed while waiting for an answer. Nothing was changed."
    case "$choice" in
      1)
        if [[ -z "$PX_NGINX" ]]; then
          warn "nginx was not found on this server, so I cannot set it up for you. Choose 2 for the exact steps for your web server."
          continue
        fi
        if [[ -n "$PX_ACMESH" && -z "$PX_CERTBOT" ]] && ! px_find_cert "$host"; then
          warn "Your certificates are managed by acme.sh. I only automate certbot, and I will not mix the two. Choose 2 for the exact acme.sh commands."
          continue
        fi
        if ! px_dns_wait "$host"; then
          say "  Stopped before changing anything. Choose again, or create the DNS record and run the installer again."
          continue
        fi
        email="$(ask_or_quit "E-mail for Let's Encrypt expiry notices (recommended; Enter to skip)" "${CFG[ACME_EMAIL]:-}")" || die "The terminal was closed while waiting for an answer. Nothing was changed."
        if [[ -n "$email" ]] && ! is_email "$email"; then warn "That does not look like an e-mail address; leaving it empty."; email=""; fi
        CFG[ACME_EMAIL]="$email"
        CFG[PROXY_SETUP]=nginx
        return 0
        ;;
      2) CFG[PROXY_SETUP]=manual; return 0 ;;
      3) CFG[PROXY_SETUP]=""; return 0 ;;
      *) warn "Please type 1, 2 or 3." ;;
    esac
  done
}

# --- preflight (read-only): can the managed setup be done safely? ---------------------------------------------

# Prints why the managed setup cannot be done; always returns 0 (callers return 1 themselves), so it is safe under set -e.
px_refuse() {
  err "$1"; shift
  local l
  for l in "$@"; do say "  $l"; done
  say "  ${C_BOLD}Nothing was changed.${C_RESET} You can also choose the do-it-yourself path (gatekeeper proxy-help) or skip it."
  return 0
}

px_decide_proxy() {
  P_PROXY=false; P_PROXY_CERT=""; P_PROXY_CERT_DIR=""; P_PROXY_RENEW_JOB=false; P_PROXY_CERTBOT_PKG=false
  px_managed || return 0
  local host ha_host file out
  host="$(px_managed_host)"; PX_HOST="$host"
  ha_host="$(url_host "${CFG[HA_BASE_URL]:-}" 2>/dev/null || true)"
  px_detect

  [[ "$EUID" -eq 0 ]] || { px_refuse "Setting up nginx and the certificate needs root. Run the installer with sudo."; return 1; }
  is_domain "$host" || { px_refuse "'$host' is not a valid name for a certificate."; return 1; }
  [[ "$host" != "$ha_host" ]] || { px_refuse "$host is the address of your Home Assistant. Gatekeeper needs its own new name."; return 1; }
  [[ -n "$PX_NGINX" ]] || { px_refuse "nginx was not found on this server."; return 1; }

  if ! out="$("$PX_NGINX" -t 2>&1)"; then
    px_refuse "nginx's configuration has an error RIGHT NOW, before I have touched anything:" "$(sed 's/^/    /' <<<"$out" | head -n 8)" \
      "I will not add to a configuration that does not pass its own test. Fix that first: sudo nginx -t"
    return 1
  fi

  if ! px_dns_matches "$host"; then
    px_refuse "$host does not point at this server yet (DNS says: ${PX_DNS_A:-nothing}; this server is ${PX_SERVER_IP4:-unknown}). Let's Encrypt would fail."
    px_dns_instructions "$host"
    return 1
  fi

  P_PROXY_SITE="$(px_site_path "$host")"
  [[ "$PX_NGINX_STYLE" == confd ]] && P_PROXY_LINK="" || P_PROXY_LINK="$PX_NGINX_DIR/sites-enabled/$host"
  if file="$(px_nginx_has_host "$host")"; then
    if [[ -f "$file" ]] && grep -qF "Managed by the HA Gatekeeper installer" "$file"; then
      : # our own file from an earlier run: re-applying is safe and idempotent
    else
      px_refuse "nginx already has a server block for $host in $file, written by someone else." "I never edit existing sites. Choose another name, or use the do-it-yourself path."
      return 1
    fi
  fi
  if [[ -e "$P_PROXY_SITE" ]] && ! grep -qF "Managed by the HA Gatekeeper installer" "$P_PROXY_SITE" 2>/dev/null; then
    px_refuse "$P_PROXY_SITE already exists and is not mine. I never overwrite files I did not create."
    return 1
  fi
  if [[ -n "$P_PROXY_LINK" && ( -e "$P_PROXY_LINK" || -L "$P_PROXY_LINK" ) ]] && ! grep -qF "Managed by the HA Gatekeeper installer" "$P_PROXY_LINK" 2>/dev/null; then
    px_refuse "$P_PROXY_LINK already exists and is not mine."
    return 1
  fi

  if px_find_cert "$host"; then
    P_PROXY_CERT=reuse; P_PROXY_CERT_DIR="$PX_CERT_DIR"
  else
    P_PROXY_CERT=issue; P_PROXY_CERT_DIR="$PX_LE_DIR/live/$host"
    if [[ -z "$PX_CERTBOT" ]]; then
      if [[ "$PKG" == apt ]]; then P_PROXY_CERTBOT_PKG=true
      else px_refuse "certbot is not installed and I can only install it with apt on this system." "Install certbot yourself, or use the do-it-yourself path."; return 1; fi
    elif [[ -z "$PX_CERTBOT_RENEWS" && ! -e "$(px_renew_timer_path)" && ! -e "$(px_renew_cron_path)" ]]; then
      P_PROXY_RENEW_JOB=true
    fi
  fi
  P_PROXY=true
  return 0
}

# --- the plan (exact changes, shown before anything is done) -------------------------------------------------

px_plan_proxy() {
  $P_PROXY || return 0
  local host="$PX_HOST" backup_hint
  backup_hint="$APP_DIR/backups/web-config-<time>.tar.gz"
  PLAN_SYSTEM+=("FIRST, a safety copy of your web settings: $PX_NGINX_DIR (all nginx config), $PX_LE_DIR (certificates, keys, renewal settings) and certbot's timer files, saved as $backup_hint (root-only, kept forever; put back with: sudo gatekeeper web-restore)")
  PLAN_SYSTEM+=("Create the folder $PX_WEBROOT (only for Let's Encrypt challenge files; your /var/www/html is not used)")
  PLAN_SYSTEM+=("Create ONE new nginx site file $P_PROXY_SITE for the name $host only (exact content below)${P_PROXY_LINK:+, and the link $P_PROXY_LINK that switches it on}")
  PLAN_SYSTEM+=("Check nginx with 'nginx -t' before EVERY reload; if the test fails nothing is reloaded and everything is undone. Then reload nginx (a reload keeps all your sites up; it is not a restart)")
  if [[ "$P_PROXY_CERT" == issue ]]; then
    $P_PROXY_CERTBOT_PKG && PLAN_SOFTWARE+=("Install certbot with apt (Let's Encrypt's own client; it also installs its own automatic renewal timer)")
    PLAN_SYSTEM+=("Get a Let's Encrypt certificate for $host ONLY: first a rehearsal ('certbot certonly --dry-run' on Let's Encrypt's practice server), then the real 'certbot certonly --webroot -w $PX_WEBROOT -d $host --cert-name $host'. This adds ${PX_LE_DIR}/live/$host, archive/$host and renewal/$host.conf; no other certificate is touched")
    PLAN_SYSTEM+=("Renewal: the certificate renews itself with a reload of nginx afterwards (a --deploy-hook saved in renewal/$host.conf)")
    if $P_PROXY_RENEW_JOB; then
      PLAN_SYSTEM+=("Your server has no automatic certbot renewal, so I add a small job just for this one certificate: $(px_renew_timer_path) (twice a day: 'certbot renew --cert-name $host'); it touches no other certificate")
    elif $P_PROXY_CERTBOT_PKG; then
      PLAN_SYSTEM+=("Renewal job: certbot's own timer (installed with the package) renews every certificate on this server; I verify it with a rehearsal")
    else
      PLAN_SYSTEM+=("Renewal job: your existing automatic certbot renewal (${PX_CERTBOT_RENEWS}) will renew this certificate too; I verify it with a rehearsal ('certbot renew --dry-run --cert-name $host')")
    fi
  else
    PLAN_SYSTEM+=("Certificate: a certificate that already covers $host exists in $P_PROXY_CERT_DIR (${PX_CERT_KIND}); it is used as it is. Nothing is issued and its renewal is not touched")
  fi
  PLAN_NETWORK+=("nginx keeps serving ports 80 and 443; the new name $host is added to it. No firewall change, no port change")
  PLAN_KEEP+=("Every existing nginx site and certificate: not edited. The nginx and certbot settings are copied first, and nginx's own test must pass before and after")
}

px_print_plan_files() {
  $P_PROXY || return 0
  local host="$PX_HOST" port="${CFG[GATEKEEPER_PORT]:-8080}"
  say "${C_BOLD}The exact nginx file that will be created: $P_PROXY_SITE${C_RESET}"
  say "  ${C_DIM}(first only its port-80 half is installed so Let's Encrypt can check the name; then this complete file replaces it)${C_RESET}"
  PX_MANAGED=true; PX_ACME_ROOT="$PX_WEBROOT"; px_detect
  px_https_block "$host" "$P_PROXY_CERT_DIR" "$port" | px_file
  PX_MANAGED=false; PX_ACME_ROOT="/var/www/html"
  say ""
  say "${C_BOLD}The exact commands that will run${C_RESET} ${C_DIM}(as root, in this order)${C_RESET}"
  say "      tar ... $PX_NGINX_DIR $PX_LE_DIR ...          ${C_DIM}# the safety copy${C_RESET}"
  say "      nginx -t && systemctl reload nginx            ${C_DIM}# after adding the port-80 half${C_RESET}"
  if [[ "$P_PROXY_CERT" == issue ]]; then
    say "      certbot certonly --webroot -w $PX_WEBROOT -d $host --cert-name $host --dry-run ..."
    say "      certbot certonly --webroot -w $PX_WEBROOT -d $host --cert-name $host --deploy-hook 'nginx -t -q && systemctl reload nginx' ..."
  fi
  say "      nginx -t && systemctl reload nginx            ${C_DIM}# after the complete file is in place${C_RESET}"
  say "  ${C_BOLD}To undo it all later:${C_RESET} sudo gatekeeper uninstall (removes only what is listed above), or restore the safety copy with sudo gatekeeper web-restore."
  say ""
}

# --- apply ---------------------------------------------------------------------------------------------------
