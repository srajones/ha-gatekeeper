#!/usr/bin/env bash
# Offline tests for the pure functions in install.sh (validators, URL handling, secrets). Run: bash deploy/tests/installer.test.sh
# Unit tests for the pure functions of install.sh (parts 1-2). Scratch-only for now.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export GK_SOURCE_ONLY=1 GK_LOG_FILE=/dev/null
source "$REPO/install.sh"
set -uo pipefail
pass=0; failn=0
t()   { # t "name" expected actual
  if [[ "$2" == "$3" ]]; then pass=$((pass+1)); else failn=$((failn+1)); echo "  FAIL: $1"; echo "     want: [$2]"; echo "      got: [$3]"; fi
}
yes() { if "${@:2}"; then pass=$((pass+1)); else failn=$((failn+1)); echo "  FAIL (expected success): $1"; fi; }
no()  { if "${@:2}"; then failn=$((failn+1)); echo "  FAIL (expected failure): $1"; else pass=$((pass+1)); fi; }

echo "is_ipv4"
yes "1.2.3.4" is_ipv4 1.2.3.4; yes "255.255.255.255" is_ipv4 255.255.255.255; yes "leading zeros 010.001.1.1" is_ipv4 010.001.1.1
no "256.1.1.1" is_ipv4 256.1.1.1; no "1.2.3" is_ipv4 1.2.3; no "1.2.3.4.5" is_ipv4 1.2.3.4.5; no "abc" is_ipv4 abc; no "empty" is_ipv4 ""; no "1.2.3.4 " is_ipv4 "1.2.3.4 "
no "08.08.08.999" is_ipv4 08.08.08.999

echo "is_domain"
yes "example.com" is_domain example.com; yes "sub.example.co.uk" is_domain sub.example.co.uk; yes "my-name.duckdns.org" is_domain my-name.duckdns.org
yes "UPPER.Example.COM" is_domain UPPER.Example.COM; yes "punycode tld" is_domain example.xn--p1ai; yes "1a.example.com" is_domain 1a.example.com
no "localhost" is_domain localhost; no "ip" is_domain 1.2.3.4; no "-bad.example.com" is_domain -bad.example.com; no "bad-.example.com" is_domain bad-.example.com
no "double dot" is_domain a..example.com; no "space" is_domain "a b.example.com"; no "trailing dot" is_domain example.com.; no "empty" is_domain ""
no "underscore" is_domain a_b.example.com; no "scheme" is_domain https://example.com; no "path" is_domain example.com/x; no "one letter tld" is_domain example.c
no "63+ label" is_domain "$(printf 'a%.0s' {1..64}).example.com"

echo "is_email"
yes "a@b.co" is_email a@b.co; yes "first.last+tag@sub.example.org" is_email first.last+tag@sub.example.org
no "no at" is_email abc; no "space" is_email "a b@c.co"; no "brace" is_email 'a}@c.co'; no "quote" is_email 'a"@c.co'; no "no tld" is_email a@b

echo "is_safe_url"
yes "http" is_safe_url http://a.b:8123; yes "https path" is_safe_url https://hooks.slack.com/services/T0/B0/xyz; yes "query" is_safe_url "https://x.io/a?b=c&d=e"
no "quote" is_safe_url 'https://a"b'; no "space" is_safe_url "https://a b"; no "backslash" is_safe_url 'https://a\b'; no "dollar" is_safe_url 'https://a$b'; no "backtick" is_safe_url 'https://a`b'
no "ftp" is_safe_url ftp://a.b; no "no scheme" is_safe_url a.b; no "newline" is_safe_url $'https://a\nb'

echo "normalize_ha_url"
n() { normalize_ha_url "$1" || echo "<<invalid>>"; }
t "bare host"          "http://homeassistant.local:8123" "$(n homeassistant.local)"
t "bare ip"            "http://192.168.1.10:8123"        "$(n 192.168.1.10)"
t "ip with port"       "http://100.64.1.2:8123"          "$(n 100.64.1.2:8123)"
t "http host no port"  "http://ha.example.com:8123"      "$(n http://ha.example.com)"
t "https keeps no port" "https://ha.example.com"         "$(n https://ha.example.com)"
t "trailing slash"     "https://ha.example.com"          "$(n https://ha.example.com/)"
t "nabu casa bare"     "https://abc.ui.nabu.casa"        "$(n abc.ui.nabu.casa)"
t "port 443 bare"      "https://ha.example.com:443"      "$(n ha.example.com:443)"
t "lovelace path"      "http://ha:8123"                  "$(n http://ha:8123/lovelace/0)"
t "config path"        "https://ha.example.com"          "$(n https://ha.example.com/config/dashboard)"
t "api path"           "https://ha.example.com"          "$(n https://ha.example.com/api/)"
t "dashboard-x path"   "https://ha.example.com"          "$(n https://ha.example.com/dashboard-home/0)"
t "custom subpath kept" "https://example.com/ha"         "$(n https://example.com/ha/)"
t "query+fragment"     "https://ha.example.com"          "$(n 'https://ha.example.com/?a=b#frag')"
t "whitespace"         "http://ha:8123"                  "$(n '  http://ha:8123  ')"
t "ftp rejected"       "<<invalid>>"                     "$(n ftp://ha)"
t "empty rejected"     "<<invalid>>"                     "$(n '')"
t "userinfo rejected"  "<<invalid>>"                     "$(n 'https://user:pw@ha.example.com')"
t "ipv6 bracket http"  "http://[fd00::1]:8123"           "$(n 'http://[fd00::1]')"

echo "ha_url_class"
c() { ha_url_class "$1"; }
t "localhost" local "$(c http://localhost:8123)"; t "127.0.0.1" local "$(c http://127.0.0.1:8123)"; t "::1" local "$(c 'http://[::1]:8123')"
t "host.docker.internal" local "$(c http://host.docker.internal:8123)"
t ".local" mdns "$(c http://homeassistant.local:8123)"; t "single label" mdns "$(c http://homeassistant:8123)"
t "10/8" private "$(c http://10.1.2.3:8123)"; t "192.168" private "$(c http://192.168.1.5:8123)"; t "172.16" private "$(c http://172.16.0.1:8123)"; t "172.31" private "$(c http://172.31.255.1:8123)"
t "172.32 is public" public "$(c http://172.32.0.1:8123)"; t "172.15 is public" public "$(c http://172.15.0.1:8123)"
t "tailscale 100.64" vpn "$(c http://100.64.0.1:8123)"; t "tailscale 100.100" vpn "$(c http://100.100.1.1:8123)"; t "100.127" vpn "$(c http://100.127.255.255:8123)"; t "100.128 public" public "$(c http://100.128.0.1:8123)"; t "100.63 public" public "$(c http://100.63.0.1:8123)"
t "public domain" public "$(c https://abc.ui.nabu.casa)"; t "public ip" public "$(c http://8.8.8.8:8123)"

echo "ha_url_rewrite_local / for_host_test"
t "rewrite localhost" "http://host.docker.internal:8123" "$(ha_url_rewrite_local http://localhost:8123)"
t "rewrite keeps path" "https://host.docker.internal:8443/ha" "$(ha_url_rewrite_local https://127.0.0.1:8443/ha)"
t "rewrite no port" "http://host.docker.internal" "$(ha_url_rewrite_local http://localhost)"
t "host test reverse" "http://127.0.0.1:8123" "$(ha_url_for_host_test http://host.docker.internal:8123)"
t "host test reverse path" "https://127.0.0.1:8443/ha" "$(ha_url_for_host_test https://host.docker.internal:8443/ha)"
t "host test passthrough" "https://abc.ui.nabu.casa" "$(ha_url_for_host_test https://abc.ui.nabu.casa)"

echo "token_problem / password_problem"
GOOD_TOKEN="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJhYmMifQ.abcDEF-_123"
t "good token" "" "$(token_problem "$GOOD_TOKEN")"
[[ -n "$(token_problem '')" ]] && pass=$((pass+1)) || { failn=$((failn+1)); echo "  FAIL: empty token accepted"; }
[[ -n "$(token_problem 'short')" ]] && pass=$((pass+1)) || { failn=$((failn+1)); echo "  FAIL: short token accepted"; }
[[ -n "$(token_problem 'has space in it xxxxxxxxxxxx')" ]] && pass=$((pass+1)) || { failn=$((failn+1)); echo "  FAIL: token with space accepted"; }
[[ -n "$(token_problem 'quote"inside-xxxxxxxxxxxxxxxxxxxx')" ]] && pass=$((pass+1)) || { failn=$((failn+1)); echo "  FAIL: token with quote accepted"; }
t "good password" "" "$(password_problem 'Sup3r-Secret!')"
t "password with everything" "" "$(password_problem "aB3\$#\"'\\ x%^&*()")"
[[ -n "$(password_problem 'short')" ]] && pass=$((pass+1)) || { failn=$((failn+1)); echo "  FAIL: short password accepted"; }
[[ -n "$(password_problem ' leading-space-pw')" ]] && pass=$((pass+1)) || { failn=$((failn+1)); echo "  FAIL: leading space accepted"; }
[[ -n "$(password_problem 'trailing-space-pw ')" ]] && pass=$((pass+1)) || { failn=$((failn+1)); echo "  FAIL: trailing space accepted"; }
[[ -n "$(password_problem $'tab\tinside-pw')" ]] && pass=$((pass+1)) || { failn=$((failn+1)); echo "  FAIL: tab accepted"; }
[[ -n "$(password_problem 'pässword-with-accent')" ]] && pass=$((pass+1)) || { failn=$((failn+1)); echo "  FAIL: non-ascii accepted"; }
t "exactly 8 ok" "" "$(password_problem 'abcdefgh')"
[[ -n "$(password_problem 'abcdefg')" ]] && pass=$((pass+1)) || { failn=$((failn+1)); echo "  FAIL: 7 chars accepted"; }
t "internal spaces ok" "" "$(password_problem 'correct horse battery staple')"

echo "normalize_ip_list"
t "single" "1.2.3.4" "$(normalize_ip_list 1.2.3.4)"
t "cidr + list" "1.2.3.4 10.0.0.0/8" "$(normalize_ip_list '1.2.3.4, 10.0.0.0/8')"
t "v6" "fd00::1 2001:db8::/32" "$(normalize_ip_list 'fd00::1 2001:db8::/32')"
t "bad prefix" "<<invalid>>" "$(normalize_ip_list 1.2.3.4/33 || echo '<<invalid>>')"
t "bad ip" "<<invalid>>" "$(normalize_ip_list 999.1.1.1 || echo '<<invalid>>')"
t "empty" "<<invalid>>" "$(normalize_ip_list '' || echo '<<invalid>>')"
t "injection" "<<invalid>>" "$(normalize_ip_list '1.2.3.4; respond 200' || echo '<<invalid>>')"
t "glob not expanded" "<<invalid>>" "$(normalize_ip_list '*' || echo '<<invalid>>')"
t "v6 bad prefix" "<<invalid>>" "$(normalize_ip_list 'fd00::/129' || echo '<<invalid>>')"

echo "secret generators"
s1="$(gen_session_secret)"; s2="$(gen_session_secret)"
t "session secret decodes to 32 bytes" 32 "$(printf '%s' "$s1" | base64 -d 2>/dev/null | wc -c)"
[[ "$s1" != "$s2" ]] && pass=$((pass+1)) || { failn=$((failn+1)); echo "  FAIL: session secrets identical"; }
h="$(gen_hash_secret)"; t "hash secret length >= 16" yes "$([[ ${#h} -ge 16 ]] && echo yes || echo no)"
[[ "$h" =~ ^[A-Za-z0-9_-]+$ ]] && pass=$((pass+1)) || { failn=$((failn+1)); echo "  FAIL: hash secret has unsafe chars: $h"; }
for len in 8 12 24 40; do a="$(gen_alnum $len)"; t "gen_alnum $len length" "$len" "${#a}"; [[ "$a" =~ ^[A-Za-z0-9]+$ ]] || { failn=$((failn+1)); echo "  FAIL: gen_alnum non-alnum: $a"; }; done
# node's base64 decoder must also give 32 bytes for the session secret (that is how the app reads it)
nbytes="$(node -e 'console.log(Buffer.from(process.argv[1],"base64").length)' "$s1")"; t "node decodes session secret to 32 bytes" 32 "$nbytes"

echo; echo "RESULT: $pass passed, $failn failed"
[[ $failn -eq 0 ]]
