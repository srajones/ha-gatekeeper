# Deploy on a VPS (Docker, one script)

`install.sh` installs HA Gatekeeper on a Linux server, walks you through every setting and
secret, keeps it running, and checks that it all works when it is done. It is safe to re-run.

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
| Access | **1** HTTPS with your domain (free Let's Encrypt certificate, DNS is checked first). **2** HTTPS on the server's IP with a self-signed certificate (no domain; browsers warn once). **3** Private: nothing exposed, reach it through an SSH tunnel. |
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

Precedence: defaults < existing `.env` < `--config FILE` < environment < wizard answers. Accepted
variables: `HA_BASE_URL HA_TOKEN ADMIN_PASSWORD GATEKEEPER_MODE GATEKEEPER_DOMAIN ACME_EMAIL
ALERT_WEBHOOK_URL ADMIN_ALLOWED_IPS AUDIT_LOG_RETENTION_DAYS HA_CA_FILE`. A generated admin password
is printed once at the end. Every setting is documented in [`deploy/env.example`](../deploy/env.example).

## Firewall

The installer opens ports 80/443 in ufw or firewalld when one is active. If ufw is installed but off, it
offers to switch it on allowing only your SSH port(s) (read from sshd, so you cannot lock yourself out),
80 and 443; set `GATEKEEPER_UFW=1` to do that unattended or `GATEKEEPER_UFW=0` to never ask. If Home
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
- **Ports 80/443 busy**: stop the other web server (`systemctl disable --now nginx apache2`).
- **Home Assistant unreachable**: see the hints printed by the installer; on the same server HA must
  listen on `0.0.0.0` and the firewall must allow the Docker network (`ufw allow from 172.16.0.0/12 to any port 8123`).
- **Private Home Assistant certificate**: provide the CA file in the wizard (`k`) or `HA_CA_FILE=`.
- **Back up `.env`.** `API_KEY_HASH_SECRET` cannot be recovered; without it every issued token stops working.
- Install log: `/var/log/ha-gatekeeper-install.log`; watchdog log: `/var/log/ha-gatekeeper-watchdog.log`.
