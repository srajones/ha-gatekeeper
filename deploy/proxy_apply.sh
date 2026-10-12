# shellcheck shell=bash
#
# The OPTIONAL managed setup (installer choice 1): this file holds every function that CHANGES anything on the server
# (the safety copy, the nginx site, the certificate, the renewal job, undo and uninstall). deploy/proxy.sh, which holds the
# read-only guide and tests, never changes anything; keeping the two apart is what lets a test prove that.
#
# Sourced by install.sh after deploy/proxy.sh. Defines functions only.

PX_LAST_WEB_BACKUP=""

px_reload_nginx() {
  if have_systemd && systemctl is-active --quiet nginx 2>/dev/null; then systemctl reload nginx
  else "${PX_NGINX:-nginx}" -s reload; fi
}
# Reload nginx after the undo has removed our files ("nginx -t" first; a failing test is reported, nothing is reloaded).
rv_nginx_reload() {
  have nginx || return 0
  px_nginx_running || return 0
  if ! nginx -t >/dev/null 2>&1; then
    RV_NOTE="nginx's own test fails right now, so I did not reload it. Check: sudo nginx -t   (your safety copy is in $APP_DIR/backups)"
    return 1
  fi
  px_reload_nginx
}
rv_cert_note() {
  # shellcheck disable=SC2034
  RV_NOTE="Kept on purpose so a retry does not use up Let's Encrypt's weekly limits. Delete it with: sudo certbot delete --cert-name $1"
  return 2
}
rv_backup_note() {
  # shellcheck disable=SC2034
  RV_NOTE="Kept on purpose. Put everything back with: sudo gatekeeper web-restore $1"
  return 2
}
px_web_backup_sources() { # existing paths worth saving
  local p
  for p in "$PX_NGINX_DIR" "$PX_LE_DIR" /etc/cron.d/certbot /etc/systemd/system/certbot.service /etc/systemd/system/certbot.timer \
    /etc/systemd/system/certbot.service.d /etc/systemd/system/certbot.timer.d /etc/systemd/system/snap.certbot.renew.service \
    /etc/systemd/system/snap.certbot.renew.timer; do
    [[ -e "$p" ]] && printf '%s\n' "$p"
  done
  return 0
}
# px_web_backup -> creates $APP_DIR/backups/web-config-TIMESTAMP.tar.gz (root-only), verifies it, prints its path.
# Contains Let's Encrypt private keys, so it is mode 600 inside the root-only backups folder. Never deleted automatically.
px_web_backup() {
  local dir="$APP_DIR/backups" ts out tmp srcs=() p
  ts="$(date +%Y%m%d-%H%M%S)"
  out="$dir/web-config-$ts.tar.gz"
  mkdir -p "$dir" && chmod 700 "$dir" || return 1
  # Never reuse a name: a second copy within the same second (a restore takes one first) must not overwrite the first.
  local n=1
  while [[ -e "$out" ]]; do n=$((n + 1)); out="$dir/web-config-$ts-$n.tar.gz"; done
  while IFS= read -r p; do [[ -n "$p" ]] && srcs+=("$p"); done < <(px_web_backup_sources)
  (( ${#srcs[@]} > 0 )) || { warn "There is no nginx or certbot configuration to save."; return 1; }
  tmp="$(mktemp -d "$dir/.web.XXXXXX")" || return 1
  {
    printf 'HA Gatekeeper safety copy of the web server and certificate settings\ncreated: %s\nhost: %s\n\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(hostname 2>/dev/null)"
    printf 'saved paths:\n'; printf '  %s\n' "${srcs[@]}"
    printf '\ncertificates present:\n'; ls -1 "$PX_LE_DIR/live" 2>/dev/null | sed 's/^/  /'
    printf '\nrestore with: sudo gatekeeper web-restore %s\n' "$out"
  } >"$tmp/README.txt"
  if [[ -n "${PX_NGINX:-}" || -x /usr/sbin/nginx ]]; then
    timeout 20 "${PX_NGINX:-/usr/sbin/nginx}" -T >"$tmp/nginx-T.txt" 2>&1 || true
  fi
  local members=(README.txt)
  [[ -s "$tmp/nginx-T.txt" ]] && members+=(nginx-T.txt)
  if ! tar -czPf "$out" -C "$tmp" "${members[@]}" "${srcs[@]}" 2>>"${LOG_FILE:-/dev/null}"; then
    rm -rf "$tmp" "$out"; return 1
  fi
  rm -rf "$tmp"
  chmod 600 "$out"
  if ! tar -tzPf "$out" >/dev/null 2>&1 || [[ "$(tar -tzPf "$out" | wc -l)" -lt 2 ]]; then
    rm -f "$out"; return 1
  fi
  PX_LAST_WEB_BACKUP="$out"
  printf '%s' "$out"
}
cmd_web_backup() {
  banner "Safety copy of your nginx and certbot settings"
  say "  Reads /etc/nginx and /etc/letsencrypt (certificates, renewal settings) and saves them in one file. Nothing is changed."
  local out
  out="$(px_web_backup)" || die "Could not create the safety copy."
  ok "Saved: $out"
  say "  It contains your certificate private keys: it is mode 600 in the root-only folder $APP_DIR/backups. Copy it off the server if you can."
  say "  Put everything back with:  sudo gatekeeper web-restore $out"
  say "  ${C_DIM}Safety copies are never deleted automatically (they are small).${C_RESET}"
}
# Paths a restore may write: exactly the ones a backup holds, never anything else.
px_restore_allowed() {
  local p="$1"
  [[ "$p" != *..* ]] || return 1
  case "$p" in
    "$PX_NGINX_DIR"|"$PX_NGINX_DIR"/*|"$PX_LE_DIR"|"$PX_LE_DIR"/*) return 0 ;;
    /etc/cron.d/certbot|/etc/systemd/system/certbot.*|/etc/systemd/system/snap.certbot.renew.*) return 0 ;;
  esac
  return 1
}
cmd_web_restore() {
  local file="${COMMAND_ARGS[0]:-}" m n bad=0 safety
  if [[ -z "$file" ]]; then
    file="$(ls -1t "$APP_DIR"/backups/web-config-*.tar.gz 2>/dev/null | head -n 1 || true)"
    [[ -n "$file" ]] || die "No safety copy found in $APP_DIR/backups. Usage: gatekeeper web-restore /path/to/web-config-YYYYMMDD-HHMMSS.tar.gz"
    say "  No file given: using the newest safety copy, $file"
  fi
  [[ -f "$file" ]] || die "$file does not exist."
  tar -tzPf "$file" >/dev/null 2>&1 || die "$file is not a valid safety copy (it cannot be read)."
  n=0
  while IFS= read -r m; do
    [[ -n "$m" ]] || continue
    case "$m" in README.txt|nginx-T.txt) continue ;; esac
    m="/${m#/}"
    n=$((n + 1))
    px_restore_allowed "${m%/}" || { err "The file contains a path I will not write: $m"; bad=1; }
  done < <(tar -tzPf "$file")
  (( bad == 0 )) || die "Refusing to restore: that file does not look like one made by gatekeeper web-backup."
  banner "Put back the saved nginx and certbot settings"
  say "  From: $file   ($n files and folders)"
  say "  This overwrites those files with the saved versions. Files created AFTER the backup (for example a new site) stay where they are;"
  say "  to remove those, delete them yourself. I first take a fresh safety copy of the CURRENT state, so this restore can be undone too."
  confirm_cmd "Restore the saved settings now?" n || die "Cancelled. Nothing was changed."
  safety="$(px_web_backup)" || die "Could not take the safety copy of the current state, so I did not restore anything."
  ok "Current state saved first: $safety"
  tar -xzPf "$file" --no-same-owner --exclude=README.txt --exclude=nginx-T.txt 2>>"$LOG_FILE" || die "Restoring failed part way. Your previous state is in $safety (restore it with: sudo gatekeeper web-restore $safety)"
  ok "Settings restored"
  if have nginx; then
    if nginx -t >>"$LOG_FILE" 2>&1; then
      ok "nginx accepts the restored configuration"
      if confirm_cmd "Reload nginx now?" y; then px_reload_nginx && ok "nginx reloaded"; fi
    else
      warn "nginx's test still fails after the restore. Nothing was reloaded. Run: sudo nginx -t   (state before the restore: $safety)"
    fi
  fi
}
px_nginx_test_or_die() { # px_nginx_test_or_die "when"
  local out
  if ! out="$(nginx -t 2>&1)"; then
    err "nginx rejected the configuration $1:"
    sed 's/^/       | /' <<<"$out" | head -n 12
    say "  Nothing was reloaded, so your sites are unaffected. Everything is being undone."
    die "nginx's own test failed $1"
  fi
  log_file "nginx -t ok ($1)"
}
px_install_renew_job() {
  local host="$PX_HOST" certbot tmp
  certbot="${PX_CERTBOT:-$(command -v certbot)}"
  tmp="$(mktemp_tracked)"
  if have_systemd; then
    jpush "Reloaded systemd's unit list" rv_daemon_reload
    printf '[Unit]\nDescription=Renew the Let'"'"'s Encrypt certificate for %s (HA Gatekeeper)\n\n[Service]\nType=oneshot\nExecStart=%s renew --cert-name %s --quiet\n' "$host" "$certbot" "$host" >"$tmp"
    jx_install_file "$tmp" "$(px_renew_service_path)" 644
    printf '[Unit]\nDescription=Twice-daily renewal check for %s (HA Gatekeeper)\n\n[Timer]\nOnCalendar=*-*-* 03,15:17:00\nRandomizedDelaySec=1h\nPersistent=true\n\n[Install]\nWantedBy=timers.target\n' "$host" >"$tmp"
    jx_install_file "$tmp" "$(px_renew_timer_path)" 644
    jpush "Enabled $PX_RENEW_TIMER_NAME" rv_unit_disable "$PX_RENEW_TIMER_NAME"
    systemctl daemon-reload >>"$LOG_FILE" 2>&1 && systemctl enable --now "$PX_RENEW_TIMER_NAME" >>"$LOG_FILE" 2>&1 || die "Could not enable the renewal timer."
  else
    printf '# Renew the Let'"'"'s Encrypt certificate for %s (HA Gatekeeper)\n17 3,15 * * * root %s renew --cert-name %s --quiet\n' "$host" "$certbot" "$host" >"$tmp"
    jx_install_file "$tmp" "$(px_renew_cron_path)" 644
  fi
  ok "A renewal job just for $host was added (twice a day; certbot only renews when it is due)"
}
px_apply_proxy() {
  $P_PROXY || return 0
  local host="$PX_HOST" port="${CFG[GATEKEEPER_PORT]:-8080}" tmp bak email_args=() certdir="$P_PROXY_CERT_DIR" reload_cmd
  tmp="$(mktemp_tracked)"
  px_detect
  [[ -n "$PX_NGINX" ]] || die "nginx disappeared."
  PX_MANAGED=true; PX_ACME_ROOT="$PX_WEBROOT"
  $P_PROXY_CERTBOT_PKG && { have certbot || die "certbot is still not installed."; px_detect; }

  # 1. The safety copy comes before everything else, and is kept even if the install is rolled back.
  info "Saving a safety copy of your nginx and certbot settings first"
  bak="$(px_web_backup)" || die "Could not save the safety copy of your web settings, so I changed nothing. (Free disk space? See $LOG_FILE)"
  jpush "Saved a safety copy of your nginx and certbot settings: $bak" rv_backup_note "$bak"
  ok "Safety copy saved: $bak"
  hint "If anything ever looks wrong:  sudo gatekeeper web-restore"

  # 2. nginx must be reloaded once more after the undo has removed our files: queued first, runs last on rollback.
  jpush "Reloaded nginx after removing the new site" rv_nginx_reload

  # 3. challenge folder + the port-80 half of the site, tested, then reloaded
  jx_mkdir "$PX_WEBROOT" tree
  chmod 755 "$PX_WEBROOT"
  px_http_block "$host" >"$tmp"
  jx_install_file "$tmp" "$P_PROXY_SITE" 644
  if [[ -n "$P_PROXY_LINK" && ! -e "$P_PROXY_LINK" && ! -L "$P_PROXY_LINK" ]]; then
    jpush "Created the link $P_PROXY_LINK" rv_rm "$P_PROXY_LINK"
    ln -s "$P_PROXY_SITE" "$P_PROXY_LINK"
  fi
  px_nginx_test_or_die "after adding the port-80 part of $host"
  px_reload_nginx || die "nginx could not be reloaded."
  ok "nginx now answers for $host on port 80 (nothing else changed)"

  # 4. certificate
  if [[ "$P_PROXY_CERT" == issue ]]; then
    reload_cmd="nginx -t -q && systemctl reload nginx"
    have_systemd || reload_cmd="nginx -t -q && nginx -s reload"
    if [[ -n "${CFG[ACME_EMAIL]:-}" ]]; then email_args=(-m "${CFG[ACME_EMAIL]}"); else email_args=(--register-unsafely-without-email); fi
    local base_args=(certonly --webroot -w "$PX_WEBROOT" -d "$host" --cert-name "$host" --non-interactive --agree-tos --no-eff-email "${email_args[@]}")
    if ! run_logged "Rehearsing the certificate request on Let's Encrypt's practice server (changes nothing)" "$PX_CERTBOT" "${base_args[@]}" --dry-run; then
      say "  ${C_BOLD}Why this usually fails:${C_RESET}"
      say "    - 'DNS problem' / 'NXDOMAIN': the A record for $host is not visible to Let's Encrypt yet (Namecheap can take up to 30 minutes)."
      say "    - 'Timeout' / 'Connection refused': port 80 is blocked by a firewall (ufw or your provider's control panel)."
      say "    - '404' / 'Invalid response': another nginx site answers for $host first (check: sudo nginx -T | grep -n server_name)."
      die "The certificate rehearsal failed (nothing was issued; nothing was lost)."
    fi
    run_logged "Getting the real certificate for $host" "$PX_CERTBOT" "${base_args[@]}" --deploy-hook "$reload_cmd" || die "Could not get the certificate for $host."
    jpush "Obtained a Let's Encrypt certificate for $host" rv_cert_note "$host"
    [[ -s "$PX_LE_DIR/live/$host/fullchain.pem" ]] || die "certbot reported success but $PX_LE_DIR/live/$host/fullchain.pem is missing."
    ok "Certificate issued for $host (it expires in 90 days and renews itself)"
    certdir="$PX_LE_DIR/live/$host"
  else
    ok "Using the existing certificate in $certdir"
  fi

  # 5. the complete site, tested, reloaded
  px_https_block "$host" "$certdir" "$port" >"$tmp"
  jx_install_file "$tmp" "$P_PROXY_SITE" 644
  px_nginx_test_or_die "after adding the https part of $host"
  px_reload_nginx || die "nginx could not be reloaded."
  ok "nginx now serves https://$host and forwards it to Gatekeeper (127.0.0.1:$port)"

  # 6. renewal job only when the server has none
  if $P_PROXY_RENEW_JOB; then px_install_renew_job; fi
  # These two are read by the block generators in proxy.sh.
  # shellcheck disable=SC2034
  PX_MANAGED=false
  # shellcheck disable=SC2034
  PX_ACME_ROOT="/var/www/html"
}
px_uninstall_proxy() {
  px_managed || return 0
  local host site link f removed=false
  host="$(px_managed_host)"; PX_HOST="$host"
  px_detect
  site="$(px_site_path "$host")"
  [[ "$PX_NGINX_STYLE" == confd ]] && link="" || link="$PX_NGINX_DIR/sites-enabled/$host"
  say ""
  say "${C_BOLD}The nginx site and certificate that this installer created for $host${C_RESET}"
  say "  I remove only files that carry the installer's own marker. Your other sites and certificates are not touched."
  [[ ! -e "$site" ]] || say "   * $site"
  [[ -z "$link" || ! -L "$link" ]] || say "   * $link (link)"
  [[ ! -d "$PX_WEBROOT" ]] || say "   * $PX_WEBROOT (challenge folder)"
  [[ ! -e "$(px_renew_timer_path)" ]] || say "   * the renewal timer for this certificate ($PX_RENEW_TIMER_NAME)"
  [[ ! -e "$(px_renew_cron_path)" ]] || say "   * $(px_renew_cron_path)"
  confirm_cmd "Remove these (a safety copy is taken first)?" n || { say "  Left in place."; return 0; }
  px_web_backup >/dev/null 2>&1 && ok "Safety copy saved: $PX_LAST_WEB_BACKUP" || warn "Could not save a safety copy; continuing carefully."
  f="$site"
  if [[ -f "$f" ]] && grep -qF "Managed by the HA Gatekeeper installer" "$f"; then
    [[ -z "$link" ]] || rm -f -- "$link"
    rm -f -- "$f"; removed=true
  elif [[ -e "$f" ]]; then
    warn "$f does not carry the installer's marker, so I left it alone."
  fi
  if [[ -d "$PX_WEBROOT" ]] && safe_rm_target "$PX_WEBROOT"; then rm -rf -- "$PX_WEBROOT"; fi
  if [[ -e "$(px_renew_timer_path)" ]]; then
    have_systemd && systemctl disable --now "$PX_RENEW_TIMER_NAME" >>"$LOG_FILE" 2>&1 || true
    rm -f -- "$(px_renew_timer_path)" "$(px_renew_service_path)"
    have_systemd && systemctl daemon-reload >>"$LOG_FILE" 2>&1 || true
  fi
  rm -f -- "$(px_renew_cron_path)"
  if $removed && have nginx; then
    if nginx -t >>"$LOG_FILE" 2>&1; then px_nginx_running && px_reload_nginx && ok "nginx reloaded without the site"
    else warn "nginx's test fails after removing the site. Nothing was reloaded. Restore with: sudo gatekeeper web-restore"; fi
  fi
  if [[ -d "$PX_LE_DIR/live/$host" ]]; then
    say "  The certificate for $host is still in $PX_LE_DIR/live/$host (Let's Encrypt limits how often it can be re-issued)."
    if confirm_purge "Also delete the certificate for $host?" n; then
      if have certbot; then certbot delete --cert-name "$host" --non-interactive >>"$LOG_FILE" 2>&1 && ok "Certificate deleted" || warn "certbot could not delete it: sudo certbot delete --cert-name $host"
      else warn "certbot is not installed; delete it with: sudo certbot delete --cert-name $host"; fi
    fi
  fi
}
