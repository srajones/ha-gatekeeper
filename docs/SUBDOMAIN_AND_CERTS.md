# Putting Gatekeeper on its own subdomain (nginx + Let's Encrypt you already run)

For a server that **already** runs nginx (and certbot or acme.sh) for other sites. In the installer choose **option 3**
("private, behind my own web server") and enter the new name, for example `gatekeeper.epicfury4d.live`.
Then the installer asks one optional question and **you choose how much it does**:

```text
1) Do it for me, with you watching   (every file and command shown first, safety copy, automatic undo)
2) I will do it myself               (prints the exact commands for the setup it found; changes nothing)
3) Skip this                         (already done, or later)
```

Everything is optional. Nothing is changed on this server until you have seen the complete plan and said yes.

## Choice 1: "Do it for me" step by step

1. **DNS first, with Namecheap hand-holding.** It tells you exactly what to click:
   *Domain List → MANAGE → Advanced DNS → ADD NEW RECORD*, type **A Record**, host = the first part of your name
   (for `gk.epicfury4d.live` that is `gk`), value = this server's IPv4 address (it prints it), TTL Automatic, then
   the green checkmark. It then waits: press Enter to re-check as often as you like (`q` stops, nothing changed).
   If the domain does not use Namecheap's nameservers it says to add the record where the DNS really lives.
2. **Pre-checks (read-only).** It refuses, changing nothing, when: `nginx -t` already fails (it will not add to a broken
   configuration), the name does not point here yet, the name is your Home Assistant's, nginx already has a server
   block for the name that is not the installer's, a file with that name is not the installer's, or certbot is
   missing on a system without apt.
3. **The complete plan** lists every file and command, then prints **the exact nginx file** that will be created and the
   exact commands that will run. Default answer is No.
4. **A safety copy first.** `/etc/nginx`, `/etc/letsencrypt` (certificates, keys, renewal settings) and certbot's
   timer files are saved as one root-only file, `<install dir>/backups/web-config-<time>.tar.gz`. It is verified,
   never overwritten, never deleted automatically and kept even when the install is undone.
5. **Apply**, each step journaled for undo:
   - a folder `/var/www/ha-gatekeeper-acme` (only for challenge files; your `/var/www/html` is not used);
   - ONE new site file for the new name (port 80 only first), enabled with a link;
   - `nginx -t`; only if it passes, a reload (a reload keeps all your sites up). It is never reloaded after a failing test;
   - the certificate for **this name only**: first `certbot certonly --dry-run` on Let's Encrypt's practice server (a
     typo cannot use up your weekly limit), then the real `certbot certonly --webroot ... --cert-name <name>` with
     a `--deploy-hook` that reloads nginx after every renewal. No other certificate is touched;
   - the complete site file (HTTP redirects to HTTPS, HTTPS forwards to Gatekeeper), `nginx -t`, reload.
6. **Auto-renewal for just that certificate.** If your server already renews certbot certificates (systemd timer or
   cron) that job renews this one too; the installer then proves it with `certbot renew --dry-run --cert-name <name>`.
   If the server has no renewal job at all, it adds a small one for only this certificate (twice a day).
7. **Verification** (also available later as `sudo gatekeeper proxy-check`): DNS, certificate name and expiry, the
   whole trip browser → nginx → Gatekeeper, login and the secure cookie, Gatekeeper's address settings, and renewal.
   A failure undoes the file changes automatically.

### What the generated nginx file never does

It never edits an existing file, never sets `http2`, `default_server` or `ipv6only` (which could change how your other
sites listen), and only adds IPv6 `listen` lines if your nginx already uses IPv6.

### If something goes wrong

The undo removes the new files and link and challenge folder, reloads nginx (only after `nginx -t` passes) and prints
what it did. **The new certificate is kept on purpose** (re-issuing it repeatedly can hit Let's Encrypt's weekly
limits; a retry reuses it); the undo prints the one command that deletes it. The safety copy is kept as well.

```text
sudo gatekeeper web-backup           save a safety copy of your nginx and certbot settings right now (changes nothing)
sudo gatekeeper web-restore [FILE]   put a saved copy back; takes a fresh copy of the current state first, asks first,
                                     refuses any file that is not a safety copy, runs nginx -t afterwards
sudo gatekeeper uninstall            removes only what the installer created (files that carry its marker comment),
                                     asks before deleting the certificate
```

## Choice 2: "I will do it myself"

After the install it prints a long guide **built from what it detected** on your server: whether nginx uses
`sites-enabled` or `conf.d`, the nginx version, which certbot/acme.sh exists and whether it renews, any existing or
wildcard certificate that already covers the name (it then skips issuing), the server's IP, the current DNS answer, and
the ready-to-copy files (written to `<install dir>/proxy/`). The same guide is available any time:

```text
sudo gatekeeper proxy-help [name]    the guide; read-only
sudo gatekeeper proxy-check [name]   tests the finished setup and says what to fix; read-only
```

`proxy-help` and `proxy-check` never run certbot and only run read-only commands (`nginx -v`, `nginx -T`,
`systemctl is-active/is-enabled`, `ufw status`, DNS lookups, TLS handshakes, HTTP requests to your own names).

## The tests behind this

- `deploy/tests/proxy.test.sh` (read-only guide and checks) stubs nginx, certbot, systemctl, ufw and docker with
  logging stubs and fails on any call that is not read-only, any change to the fake `/etc/nginx` or `/etc/letsencrypt`,
  or any mutating command / write outside its own folder in `deploy/proxy.sh`.
- `deploy/tests/proxy-apply.test.sh` (the managed setup) covers every refusal, the plan, the safety copy (including
  two copies in the same second), apply, idempotent re-run, rollback after each kind of failure (nginx rejects the
  file, rehearsal fails, real request fails, a later health-check failure), the certificate-kept behaviour and the
  retry that reuses it, the renewal job, restore (and refusing a hostile tar), uninstall (only files with the
  marker), the wizard and the DNS wait, and that **nginx is only ever reloaded right after a passing `nginx -t`**.
  After each failure the fake nginx and certbot trees are byte-identical to before (apart from the kept certificate).
- The generated files and the whole flow were also run against a real nginx 1.24 (Ubuntu 24.04): `nginx -t` passes,
  an existing site on the same ports kept answering, apply, uninstall and a forced failure after the certificate
  restored the real `/etc/nginx` byte for byte, and `proxy-check` passed all 17 checks (login through the proxy,
  Secure cookie, renewal rehearsal). The certificate authority was a stand-in: a real Let's Encrypt issuance needs a
  real public domain and has not been run by the developer.

## Testing the whole "Do it for me" flow on a throw-away server (no real domain)

`deploy/tests/standin-certbot.sh` is a **test-only** stand-in for certbot. On a disposable box, install it as
`/usr/local/bin/certbot`, map the test name to the server's own IP in `/etc/hosts`, and run the real installer with
`PROXY_SETUP=nginx`: the plan, the safety copy, the nginx files, the "certificate", the renewal rehearsal and all 17
checks run for real against the real nginx. Set `STANDIN_FAIL=dry|real|renew` (or put the word in
`/etc/standin-certbot.fail`) to make the rehearsal, the real request or the renewal fail and watch the automatic undo.
It adds the self-signed certificate to the system trust store so the installer's own checks can connect, and
`certbot delete` removes it again. Never put it on a server you care about.
