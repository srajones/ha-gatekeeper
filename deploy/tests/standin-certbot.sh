#!/usr/bin/env bash
# A TEST-ONLY stand-in for certbot, for disposable test servers that have no real domain. It is never installed or
# used by the installer itself. Copy it to /usr/local/bin/certbot on a THROW-AWAY box (before /usr/bin in PATH) to run
# the installer's whole "Do it for me" nginx + certificate flow end to end without Let's Encrypt:
#   sudo install -m 755 deploy/tests/standin-certbot.sh /usr/local/bin/certbot
#
# It understands exactly what the installer calls:
#   certonly [--dry-run] ... -d NAME --cert-name NAME [--deploy-hook CMD]   a real run writes a self-signed certificate
#                                                                           to /etc/letsencrypt/{live,archive,renewal}/NAME
#   renew [--dry-run] --cert-name NAME                                      succeeds when the renewal config exists
#   delete --cert-name NAME                                                 removes that certificate's three paths
#   certificates | plugins                                                  harmless listings
# Failure injection (environment of the CALLER, or the file /etc/standin-certbot.fail with one word per line):
#   STANDIN_FAIL=dry     the rehearsal (certonly --dry-run) fails like a validation error ("NXDOMAIN")
#   STANDIN_FAIL=real    the real request fails
#   STANDIN_FAIL=renew   the renewal rehearsal fails
# A real run also adds the self-signed certificate to the system trust store (update-ca-certificates), because the installer's
# final check connects with curl and must trust it; `delete` removes it again. STANDIN_TRUST=0 turns that off.
# Every call is logged to /var/log/standin-certbot.log. It never touches any other certificate.
set -u
LE="${STANDIN_LE_DIR:-/etc/letsencrypt}"
LOG="${STANDIN_LOG:-/var/log/standin-certbot.log}"
echo "$(date -u +%FT%TZ) certbot $*" >>"$LOG" 2>/dev/null || true
fail="${STANDIN_FAIL:-}"
[[ -n "$fail" || ! -r /etc/standin-certbot.fail ]] || fail="$(head -n 1 /etc/standin-certbot.fail)"

cmd="${1:-}"; shift || true
dry=false; name=""; cert=""; hook=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[i]}" in
    --dry-run) dry=true ;;
    -d) name="${args[i+1]:-}" ;;
    --cert-name) cert="${args[i+1]:-}" ;;
    --deploy-hook) hook="${args[i+1]:-}" ;;
  esac
done
[[ -n "$cert" ]] || cert="$name"

case "$cmd" in
  certonly)
    if $dry; then
      if [[ "$fail" == dry ]]; then
        echo "Challenge failed for domain $name"; echo "DNS problem: NXDOMAIN looking up A for $name (stand-in)"; exit 1
      fi
      echo "The dry run was successful. (stand-in)"; exit 0
    fi
    if [[ "$fail" == real ]]; then echo "Some challenges have failed. (stand-in)"; exit 1; fi
    [[ -n "$name" ]] || { echo "no -d NAME given"; exit 2; }
    mkdir -p "$LE/live/$cert" "$LE/archive/$cert" "$LE/renewal"
    openssl req -x509 -newkey rsa:2048 -nodes -keyout "$LE/archive/$cert/privkey1.pem" -out "$LE/archive/$cert/fullchain1.pem" \
      -days 90 -subj "/CN=$name" -addext "subjectAltName=DNS:$name" >/dev/null 2>&1 || { echo "openssl failed"; exit 1; }
    cp "$LE/archive/$cert/fullchain1.pem" "$LE/archive/$cert/cert1.pem"; cp "$LE/archive/$cert/fullchain1.pem" "$LE/archive/$cert/chain1.pem"
    ln -sf "../../archive/$cert/fullchain1.pem" "$LE/live/$cert/fullchain.pem"
    ln -sf "../../archive/$cert/privkey1.pem" "$LE/live/$cert/privkey.pem"
    ln -sf "../../archive/$cert/cert1.pem" "$LE/live/$cert/cert.pem"
    ln -sf "../../archive/$cert/chain1.pem" "$LE/live/$cert/chain.pem"
    chmod 600 "$LE/archive/$cert/privkey1.pem"
    printf '# renew_before_expiry = 30 days\nversion = stand-in\narchive_dir = %s/archive/%s\ncert = %s/live/%s/cert.pem\nprivkey = %s/live/%s/privkey.pem\nchain = %s/live/%s/chain.pem\nfullchain = %s/live/%s/fullchain.pem\n\n[renewalparams]\nauthenticator = webroot\nrenew_hook = %s\n' \
      "$LE" "$cert" "$LE" "$cert" "$LE" "$cert" "$LE" "$cert" "$LE" "$cert" "$hook" >"$LE/renewal/$cert.conf"
    trust_file="/usr/local/share/ca-certificates/standin-$cert.crt"
    if [[ "${STANDIN_TRUST:-1}" != 0 && "$LE" == /etc/letsencrypt ]] && command -v update-ca-certificates >/dev/null 2>&1; then
      cp "$LE/archive/$cert/fullchain1.pem" "$trust_file" && update-ca-certificates >/dev/null 2>&1 || true
    fi
    echo "Successfully received certificate. (stand-in; self-signed)"
    [[ -z "$hook" ]] || sh -c "$hook" || true
    exit 0 ;;
  renew)
    if [[ "$fail" == renew ]]; then echo "Failed to renew certificate $cert with error: (stand-in)"; exit 1; fi
    [[ -z "$cert" || -f "$LE/renewal/$cert.conf" ]] || { echo "No renewal config for $cert"; exit 1; }
    echo "Congratulations, all simulated renewals succeeded. (stand-in)"; exit 0 ;;
  delete)
    [[ -n "$cert" ]] || exit 2
    rm -rf -- "$LE/live/$cert" "$LE/archive/$cert" "$LE/renewal/$cert.conf"
    if [[ -e "/usr/local/share/ca-certificates/standin-$cert.crt" && "$LE" == /etc/letsencrypt ]]; then
      rm -f -- "/usr/local/share/ca-certificates/standin-$cert.crt"; command -v update-ca-certificates >/dev/null 2>&1 && update-ca-certificates --fresh >/dev/null 2>&1
    fi
    echo "Deleted all files relating to certificate $cert. (stand-in)"; exit 0 ;;
  certificates) ls -1 "$LE/live" 2>/dev/null | sed 's/^/Certificate Name: /'; exit 0 ;;
  plugins) echo "* webroot"; exit 0 ;;
  *) echo "stand-in certbot: unsupported command '$cmd'"; exit 2 ;;
esac
