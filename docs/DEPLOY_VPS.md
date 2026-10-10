# Deploy on a VPS (Docker, one script)

`install.sh` installs HA Gatekeeper on a Linux server, walks you through every setting and
secret, keeps it running, and checks that it all works when it is done. It is safe to re-run.

**Nothing on your server changes until you have seen the complete list of changes and said yes**
(see [Consent, rollback and what uninstall leaves](#consent-rollback-and-what-uninstall-leaves)).
To only look at that list: `sudo ./install.sh --dry-run`.

## Install

On the server, as root (or with `sudo`):

```bash
# minimal Debian/Ubuntu images have no git or curl yet:
apt-get update && apt-get install -y git curl
git clone https://github.com/srajones/ha-gatekeeper.git
cd ha-gatekeeper
sudo ./install.sh
```

Until the installer is merged to `main`, add `-b claude/elegant-johnson-g76r1h` to the `git clone`.

Without a checkout (the script fetches the repository itself into `/opt/ha-gatekeeper`):

```bash
curl -fsSL https://raw.githubusercontent.com/srajones/ha-gatekeeper/main/install.sh | sudo bash
# another branch or fork:  ... | sudo GK_BRANCH=my-branch GK_REPO_URL=https://github.com/me/ha-gatekeeper.git bash
```

Supported: Ubuntu, Debian, and RHEL-family servers (Docker and every other dependency are
installed for you). Other Linux distributions work if Docker with Compose v2 is already installed.

## What it asks you

| Step | What happens |
| --- | --- |
| Access | **1** HTTPS with your domain (free Let's Encrypt certificate, DNS is checked first). **2** HTTPS on the server's IP with a self-signed certificate (no domain; browsers warn once). **3** Private: nothing exposed; reach it through an SSH tunnel, or through a web server you already run (nginx, Apache...): you give its https:// address and Gatekeeper is never touched by or touches that server. Options 1 and 2 need ports 80/443; if another program owns them the installer says so and offers option 3. It never stops another web server. |
| Home Assistant | URL and long-lived access token. The connection is **tested live** and problems are explained (DNS, VPN needed, TLS, wrong token). |
| Admin password | Generate a strong one, or type your own (hidden, confirmed). |
| Advanced (optional) | Audit-log retention, alert webhook (Slack/Discord/Mattermost/generic), restrict the admin API to your IPs. |

Secrets (`ADMIN_SESSION_SECRET`, `API_KEY_HASH_SECRET`) are generated for you. Everything is
written to `.env` (mode 600). Re-running keeps existing secrets.

**Home Assistant must be reachable from the server.** A VPS cannot see `192.168.x.x` or
`homeassistant.local`. Use Nabu Casa, your own public HTTPS address, a VPN address (Tailscale or
WireGuard), or `http://localhost:8123` if Home Assistant runs on the same server.

**Why HTTPS matters.** In production the admin session cookie is `Secure`, so the admin login
only works over HTTPS (or `localhost`). That is why the installer sets up Caddy for you.

## Consent, rollback and what uninstall leaves

1. **The complete list first.** After your questions the installer prints every change it will make:
   packages, Docker (only if missing), swap file and its `/etc/fstab` line, systemd units or cron file,
   the `gatekeeper` command, firewall rules, containers, and files in its own folder. It also lists what it
   leaves alone (other containers, your web server, SSH, existing firewall rules). Then it asks
   **"Make exactly these changes?"**: the default is **No**. With `--yes` the list is approved for unattended
   runs; `--dry-run` shows it and stops. A declined or dry run leaves nothing behind (not even a log file).
2. **A stopped Docker is never started silently.** Starting it would also start all your other containers, so
   the installer asks separately (unattended: `GATEKEEPER_START_DOCKER=1`). An existing Docker is never
   reinstalled or upgraded.
3. **Automatic rollback.** Each change is recorded before it is made, with its undo. If anything fails (an
   error, Ctrl-C, or the final health check) the changes are undone newest-first and each undo is printed.
   Only things this run did are undone: packages, Docker, rules, files and folders that were already there
   are never removed. A firewall that was already on is never turned off; a firewall this run switched on is
   switched off again (before its rules are removed, so there is no lock-out). A re-run over a working
   installation restores the previous `.env` and restarts the previous settings. `--keep-on-failure` keeps a
   failed install for debugging. The only failure that does not undo the install is "the HTTPS certificate
   is not issued yet" (Caddy keeps retrying by itself).
4. **A summary at the end** lists every change that was made outside the app folder.
5. **What `gatekeeper uninstall` does not undo:** Docker and any packages installed for you, the swap file and
   its fstab line, a firewall that was switched on and its SSH rule, downloaded base images and Docker's build
   cache, the code folder, backups and the install log. It removes the containers, units/cron file, the
   `gatekeeper` command, the `HA Gatekeeper ...` firewall rules and the `secrets/` folder, and (when you
   agree, or with `--purge`) the built image, certificates, data and `.env`.

Test hook: `GK_FAIL_AT=<after-config|after-prereqs|after-swap|after-docker|after-env|after-build|after-start|after-automation|before-verify|verify>`
makes an install fail on purpose at that point, to see the rollback work.

## Secrets stay out of the container's environment

`HA_TOKEN`, `ADMIN_PASSWORD`, `ADMIN_SESSION_SECRET` and `API_KEY_HASH_SECRET` are **not** container environment
variables (those are visible with `docker inspect` and in `/proc`). `.env` (mode 600) stays the master copy; the
installer writes each secret to its own file in `secrets/` (a root-only folder, files readable only by the app's
user) and mounts them read-only; the app reads them through `HA_TOKEN_FILE` etc. `gatekeeper verify` checks that
no secret appears in the container environment. `sudo ./install.sh secrets` rewrites the files from `.env`
(for people who run `docker compose` by hand).

## Home Assistant is protected from the number of keys

Every API key shares one gate to Home Assistant: state reads are cached for 2 seconds and identical simultaneous
reads share a single request (so 100 keys reading the same entity cost Home Assistant one request); at most 8
requests are in flight at once, with a bounded queue, and when it is full callers get `503 ha_busy`
(`Retry-After: 1`) instead of piling more onto Home Assistant. A service call clears the cache so the next read
shows its effect. Tunable with `HA_STATE_CACHE_MS` (0 = off) and `HA_MAX_CONCURRENCY` in `.env`.

## What keeps it alive

1. Docker `restart: unless-stopped`: restarts a crashed container within seconds and after reboot.
2. `ha-gatekeeper.service`: brings the stack up at boot.
3. **Watchdog** (`deploy/watchdog.sh`, every minute via a systemd timer, cron where there is no
   systemd). It heals what Docker alone cannot: a hung app inside a "running" container, a stopped or
   deleted container, a missing image, an unresponsive Docker daemon. It escalates restart, then
   recreate, then Docker restart, capped at 6 actions per hour, never deletes data, and can send a
   webhook alert on *down* / *recovered*. It also prunes dangling images when the disk is nearly full.
4. Container logs are capped (5 x 10 MB) so they cannot fill the disk.
5. A daily backup of the database and `.env` (last 14 kept) in `backups/`.

## Is everything working? `gatekeeper verify`

Run automatically at the end of the install, and any time later. It really exercises the system:
containers and restart policy, health endpoint, auth gates, **admin login (through the HTTPS front
door)**, cookie flags, wrong-password rejection, Home Assistant reachable **from inside the
container**, a temporary scoped token created, used end to end and deleted, TLS certificate and
HTTP-to-HTTPS redirect, watchdog heartbeat, migrations, backups, disk and memory. After a fresh
install it also runs a **crash-recovery drill**: kills the app the way an out-of-memory kill would
and confirms Docker restarts it, then stops it the way an operator would and confirms the
watchdog brings it back.

## Commands

After install the `gatekeeper` command is available (or use `sudo ./install.sh <command>`):

```text
gatekeeper status            one-screen summary
gatekeeper verify [--quick]  full health check (--quick skips the temporary-token test, --drill adds the crash drill)
gatekeeper logs [-f] [gatekeeper|caddy|watchdog]
gatekeeper update            pull, back up, rebuild, restart, check; rolls back automatically on failure
gatekeeper backup | restore FILE
gatekeeper start | stop | restart     (stop also pauses the watchdog, also across reboots)
gatekeeper uninstall         removes services/containers; asks before touching data
                             (unattended: --yes keeps your data; add --purge to also delete data, .env, images, certificates)
gatekeeper restore FILE --yes  restores without asking (add --with-env to also restore the saved .env)
sudo ./install.sh --reconfigure       ask everything again
```

## Unattended install

```bash
sudo HA_BASE_URL=https://xxxx.ui.nabu.casa HA_TOKEN=... GATEKEEPER_MODE=domain \
  GATEKEEPER_DOMAIN=gatekeeper.example.com ACME_EMAIL=me@example.com \
  ./install.sh --yes
```

`--yes` also approves the printed list of changes. Precedence: defaults < existing `.env` < `--config FILE` <
environment < wizard answers. Accepted variables: `HA_BASE_URL HA_TOKEN ADMIN_PASSWORD GATEKEEPER_MODE
GATEKEEPER_DOMAIN GATEKEEPER_PUBLIC_URL GATEKEEPER_PORT ACME_EMAIL ALERT_WEBHOOK_URL ADMIN_ALLOWED_IPS
AUDIT_LOG_RETENTION_DAYS HA_CA_FILE`. Safety switches: `GATEKEEPER_UFW=1|0`, `GATEKEEPER_SWAP=1|0`,
`GATEKEEPER_START_DOCKER=1`, `GATEKEEPER_KEEP_ON_FAILURE=1`. A generated admin password is printed once at
the end. Every setting is documented in [`deploy/env.example`](../deploy/env.example).

### Behind a web server you already run (nginx, Apache...)

Choose private mode and give the https:// address your web server serves, for example:

```bash
sudo GATEKEEPER_MODE=local GATEKEEPER_PUBLIC_URL=https://ha.example.com GATEKEEPER_PORT=8080 \
  HA_BASE_URL=... HA_TOKEN=... ./install.sh --yes
```

Gatekeeper listens only on `127.0.0.1:8080`, opens no ports and does not touch your web server; it trusts one
proxy hop for client IPs (`TRUST_PROXY=1`). The summary prints the nginx `location` block to add
(`proxy_pass http://127.0.0.1:8080` plus the `Host` and `X-Forwarded-*` headers) and `gatekeeper verify`
checks that the public address reaches the app. A port you request with `GATEKEEPER_PORT` is never changed
silently: if it is busy the installer stops.

## Firewall

In HTTPS modes the installer adds the rules for ports 80/443 to ufw or firewalld when one is already active
(only rules that are missing; none of yours is changed). If ufw is installed but off, it offers to switch it
on allowing only your SSH port(s) (read from sshd, so you cannot lock yourself out), 80 and 443; the default
answer is No and `--yes` alone never turns a firewall on: use `GATEKEEPER_UFW=1`. **`GATEKEEPER_UFW=0` means the
installer never touches the firewall at all** (no switching on, no rules; it prints the rules you may need).
Private mode opens no ports. If Home
Assistant runs on the same server (or is addressed by the server's own IP or domain) it also allows the Docker networks to reach that one port. Rules it
adds are removed again when you switch to private mode or uninstall (the SSH rule is never touched).
Docker bypasses ufw for published ports, so the app's own port stays bound to `127.0.0.1` regardless.

## Behind the scenes

- `docker-compose.yml`: `gatekeeper` (published on `127.0.0.1` only, because Docker bypasses UFW
  for published ports) and `caddy` (ports 80/443, enabled by `COMPOSE_PROFILES=proxy`).
- `TRUST_PROXY=1` is set when Caddy is in front so audit logs and the admin-login rate limit see real
  client IPs. It is ignored in Home Assistant add-on mode.
- Docker Hub rate-limits shared VPS addresses; the installer falls back to `mirror.gcr.io` and
  `public.ecr.aws` for the base images.
- Offline tests: `bash deploy/tests/installer.test.sh`, `bash deploy/tests/watchdog.test.sh`.

## Troubleshooting

- **Certificate not issued**: DNS must point to the server (and have no stale AAAA record), and ports
  80/443 must be open in the host firewall *and* your provider's firewall. `gatekeeper verify` explains
  the cause from Caddy's logs.
- **Ports 80/443 busy**: options 1 and 2 need them. The installer never stops or reconfigures another web
  server: choose private mode (3) and let that server forward HTTPS to Gatekeeper (see above), or free the
  ports yourself and run the installer again. Nothing is changed when it refuses.
- **Home Assistant unreachable**: see the hints printed by the installer; on the same server HA must
  listen on `0.0.0.0` and the firewall must allow the Docker network (`ufw allow from 172.16.0.0/12 to any port 8123`).
- **Private Home Assistant certificate**: provide the CA file in the wizard (`k`) or `HA_CA_FILE=`.
- **Back up `.env`.** `API_KEY_HASH_SECRET` cannot be recovered; without it every issued token stops working.
- Install log: `/var/log/ha-gatekeeper-install.log`; watchdog log: `/var/log/ha-gatekeeper-watchdog.log`.
