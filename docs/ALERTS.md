# Alerts and self-healing

HA Gatekeeper is meant to run unattended, so it heals itself first and tells you when it cannot (or when something it
depends on, Home Assistant, is gone).

## What tells you what

| Something is wrong | Who notices | How fast | You get |
| --- | --- | --- | --- |
| **Home Assistant is unreachable** (down, restarting, network, token revoked) | the app | after the delay you choose (default 2 minutes) | one *down* message, reminders (default every 6 h), one *back* message with the duration |
| The app container is unhealthy, crash-looping, missing, or Docker itself is down | the server's **watchdog** (every minute) | after 3 failed checks | *down*, *still down* hourly, *recovered* |
| The disk is almost full | the watchdog | every 10 minutes | a warning (once a day) |
| **The whole server is dead or offline** | an outside service you point `HEARTBEAT_URL` at | when the pings stop | whatever that service sends (it is the only thing that can notice) |

Short outages send nothing: if Home Assistant restarts in under the delay, you hear nothing. Change the delay and the
reminder interval in the dashboard under **Settings**.

## Channels (any number at once, each tried independently)

| Channel | What you need |
| --- | --- |
| **E-mail** | an SMTP server and login (your provider, Gmail with an app password, Brevo, Mailgun ...). Port 587 (STARTTLS) or 465 (TLS); many VPS providers block outgoing port 25. |
| **Webhook** | a Slack/Discord/Mattermost/Rocket.Chat webhook URL, or anything that accepts JSON. The body has `text`, `content` and `message`. |
| **ntfy** | a topic URL like `https://ntfy.sh/a-long-secret-topic-name` and the free ntfy phone app. Optional access token for protected topics. |
| **Telegram** | a bot token from @BotFather and your chat id. |
| **Heartbeat** | a push/ping URL from healthchecks.io, Uptime Kuma, Better Stack ... |

If one channel is down, the others still deliver; a failing one is reported in the dashboard and in `gatekeeper alerts test`.

## Setting it up

```bash
sudo gatekeeper alerts          # a short menu: pick a channel, answer a few questions, it offers a test
sudo gatekeeper alerts test     # sends a test through every channel, from the watchdog AND from the app
sudo gatekeeper alerts status   # which channels are on (secrets are never shown)
```

The installer also offers it under "advanced options". Unattended installs can pass the values as environment variables
(`ALERT_EMAIL_TO`, `SMTP_HOST`, `SMTP_PORT`, `SMTP_SECURITY`, `SMTP_USER`, `SMTP_PASSWORD`, `SMTP_FROM`,
`ALERT_WEBHOOK_URL`, `ALERT_NTFY_URL`, `ALERT_NTFY_TOKEN`, `ALERT_TELEGRAM_BOT_TOKEN`, `ALERT_TELEGRAM_CHAT_ID`,
`HEARTBEAT_URL`, `ALERT_NAME`), and every value is documented in `deploy/env.example`.

The dashboard (**Settings > Alerts**) shows which channels are on and where they go (addresses partly masked, never a
password or token), the recent alerts, and a **Send a test alert** button. Secrets are deliberately not editable
there: they live in `.env` (mode 600) and `secrets/` (root-only), never in the database or the container environment.

## How the app decides to alert

- It watches the live link to Home Assistant (the one websocket). When the live subscription is not in use (the "ask
  Home Assistant" modes, or no key reads an entity yet) it makes one tiny request a minute instead.
- Down for longer than the delay: **one** message, with the last problem in plain words ("cannot connect (ECONNREFUSED)",
  "no answer within 8 s", "Home Assistant rejected the access token (HTTP 401)" with what to do about it).
- Still down: a reminder every N minutes (0 = none). Back: one message with how long it lasted.
- Blips shorter than the delay, however many, send nothing.
- Settings changes apply to an outage that is already running.

## What heals itself, and how fast

| Failure | Healed by | Typical time |
| --- | --- | --- |
| The app crashes or is killed (including out-of-memory) | Docker (`restart: unless-stopped`) | seconds |
| The app's database stops answering | the app exits after 90 s; Docker restarts it. `/healthz` also turns 503 so the watchdog sees it | 1.5 min |
| The app hangs without exiting | Docker marks it unhealthy; the watchdog restarts, then recreates it | 3-5 min |
| The container is stopped or deleted | the watchdog starts / recreates it | about a minute |
| Docker's daemon stops or wedges | the watchdog starts / restarts it | 1-3 min |
| The server reboots | Docker restarts the containers; `ha-gatekeeper.service` brings the whole stack up | boot time + ~1 min |
| Home Assistant is down | nothing to heal here: the app keeps serving last-known data (marked `X-HA-Stale`) or errors as you chose, reconnects by itself (5 s up to 60 s), and alerts you | until Home Assistant is back |
| Memory runaway | the container is fenced (768 MB app, 384 MB proxy by default); Docker restarts it, your other containers are not affected | seconds |

Corrective actions are bounded (at most 6 an hour), never delete data, volumes or images, and are paused by
`gatekeeper stop` so an intentional stop stays stopped. `/healthz` never depends on Home Assistant: an outage there is
not a reason to restart this server.

## What no software on the same machine can do

If the server itself loses power or network, nothing running on it can send a message. That is what `HEARTBEAT_URL` is
for: an outside service that expects a ping every minute and alerts you when they stop. Use it; it is the one alert that
survives the machine dying.
