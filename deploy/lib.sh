# shellcheck shell=bash
#
# Shared helpers for install.sh and deploy/watchdog.sh. Source this file; never execute it.
# It deliberately sets no shell options and defines only functions.

# ---------------------------------------------------------------------------------------------
# .env reading and writing
#
# Values are written double-quoted with \ " and $ escaped. That is the one encoding Docker
# Compose reads back byte for byte for every printable character: unquoted or single-quoted
# values break on $, #, quotes and trailing backslashes (verified against Compose itself).
# ---------------------------------------------------------------------------------------------

# env_quote VALUE  ->  "VALUE" (escaped) on stdout
env_quote() {
  local v="$1"
  v="${v//\\/\\\\}"
  v="${v//\"/\\\"}"
  v="${v//\$/\\\$}"
  printf '"%s"' "$v"
}

# env_unquote RAW  ->  the value a .env line holds. Understands the double-quoted form written
# by env_quote, plus single-quoted and bare values so hand-edited files keep working.
env_unquote() {
  local v="$1" out="" ch next i
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"

  if [[ ${#v} -ge 2 && "${v:0:1}" == '"' && "${v: -1}" == '"' ]]; then
    v="${v:1:${#v}-2}"
    for ((i = 0; i < ${#v}; i++)); do
      ch="${v:i:1}"
      if [[ "$ch" == "\\" && $((i + 1)) -lt ${#v} ]]; then
        next="${v:i+1:1}"
        if [[ "$next" == "\\" || "$next" == '"' || "$next" == '$' ]]; then
          out+="$next"
          i=$((i + 1))
          continue
        fi
      fi
      out+="$ch"
    done
    printf '%s' "$out"
  elif [[ ${#v} -ge 2 && "${v:0:1}" == "'" && "${v: -1}" == "'" ]]; then
    printf '%s' "${v:1:${#v}-2}"
  else
    # Bare value: drop a trailing " # comment".
    v="${v%%[[:space:]]#*}"
    printf '%s' "$v"
  fi
}

# env_file_get FILE KEY  ->  value on stdout; returns 1 if the file or key is missing.
# The last assignment wins, like Compose. KEY must be a plain identifier.
env_file_get() {
  local file="$1" key="$2" line
  [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
  [[ -r "$file" ]] || return 1
  line="$(grep -E "^[[:space:]]*(export[[:space:]]+)?${key}[[:space:]]*=" "$file" | tail -n 1)" || true
  [[ -n "$line" ]] || return 1
  env_unquote "${line#*=}"
}

# ---------------------------------------------------------------------------------------------
# Alerts
# ---------------------------------------------------------------------------------------------

# json_escape TEXT  ->  TEXT escaped for use inside a JSON string
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

# send_webhook URL TEXT
# POSTs {"text","content","message"} so Slack, Discord, Mattermost, Rocket.Chat and most
# generic webhook receivers all accept it. The URL usually embeds a secret, so it goes to
# curl through stdin instead of the process list.
send_webhook() {
  local url="$1" text esc
  text="$2"
  esc="$(json_escape "$text")"
  printf 'url = "%s"\n' "$url" | curl -fsS --max-time 10 -o /dev/null -K - \
    -H 'Content-Type: application/json' \
    -d "{\"text\":\"${esc}\",\"content\":\"${esc}\",\"message\":\"${esc}\"}"
}

# ---------------------------------------------------------------------------------------------
# Multi-channel alerts for the host watchdog (the app has its own sender in packages/server/src/alerts.ts;
# both read the same keys from .env). Channels: webhook, ntfy, Telegram, e-mail (through curl's SMTP).
# Secrets reach curl through stdin/config files, never the process list.
# ---------------------------------------------------------------------------------------------

# alert_ascii TEXT -> TEXT with anything outside printable ASCII replaced by "?" (headers must be ASCII)
alert_ascii() { printf '%s' "$1" | LC_ALL=C tr -c '\040-\176' '?'; }

# alert_channels_configured ENVFILE -> names of the channels that have enough settings to be tried
alert_channels_configured() {
  local f="$1" v
  v="$(env_file_get "$f" ALERT_WEBHOOK_URL 2>/dev/null || true)"; [[ -n "$v" ]] && echo webhook
  v="$(env_file_get "$f" ALERT_NTFY_URL 2>/dev/null || true)"; [[ -n "$v" ]] && echo ntfy
  v="$(env_file_get "$f" ALERT_TELEGRAM_BOT_TOKEN 2>/dev/null || true)"; [[ -n "$v" ]] && echo telegram
  v="$(env_file_get "$f" ALERT_EMAIL_TO 2>/dev/null || true)"
  [[ -n "$v" && -n "$(env_file_get "$f" SMTP_HOST 2>/dev/null || true)" ]] && echo email
  return 0
}

# send_email_curl ENVFILE SUBJECT BODY  (0 = accepted by the SMTP server)
send_email_curl() {
  local f="$1" subject="$2" body="$3" to host port sec user pass from msg cfg scheme rcpt rc=0 addr
  to="$(env_file_get "$f" ALERT_EMAIL_TO 2>/dev/null || true)"
  host="$(env_file_get "$f" SMTP_HOST 2>/dev/null || true)"
  port="$(env_file_get "$f" SMTP_PORT 2>/dev/null || true)"; port="${port:-587}"
  sec="$(env_file_get "$f" SMTP_SECURITY 2>/dev/null || true)"; sec="${sec:-starttls}"
  user="$(env_file_get "$f" SMTP_USER 2>/dev/null || true)"
  pass="$(env_file_get "$f" SMTP_PASSWORD 2>/dev/null || true)"
  from="$(env_file_get "$f" SMTP_FROM 2>/dev/null || true)"
  [[ -n "$from" ]] || from="$user"
  [[ -n "$to" && -n "$host" && "$from" == *@* ]] || return 2

  msg="$(mktemp)"; cfg="$(mktemp)"; chmod 600 "$msg" "$cfg"
  {
    printf 'From: HA Gatekeeper <%s>\r\n' "$from"
    printf 'To: %s\r\n' "$to"
    printf 'Subject: %s\r\n' "$(alert_ascii "$subject")"
    printf 'Date: %s\r\n' "$(LC_ALL=C date -R)"
    printf 'MIME-Version: 1.0\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: 8bit\r\n\r\n'
    printf '%s\r\n' "${body//$'\n'/$'\r\n'}"
  } >"$msg"

  case "$sec" in tls) scheme="smtps" ;; *) scheme="smtp" ;; esac
  {
    printf 'url = "%s://%s:%s"\n' "$scheme" "$host" "$port"
    printf 'mail-from = "%s"\n' "$from"
    IFS=',' read -r -a rcpt <<<"$to"
    for addr in "${rcpt[@]}"; do addr="${addr//[[:space:]]/}"; [[ -n "$addr" ]] && printf 'mail-rcpt = "%s"\n' "$addr"; done
    printf 'upload-file = "%s"\n' "$msg"
    [[ "$sec" == starttls ]] && printf 'ssl-reqd\n'
    if [[ -n "$user" ]]; then
      pass="${pass//\\/\\\\}"; pass="${pass//\"/\\\"}"
      printf 'user = "%s:%s"\n' "$user" "$pass"
    fi
  } >"$cfg"
  curl -sS --connect-timeout 10 --max-time 30 -K "$cfg" >/dev/null 2>&1 || rc=$?
  rm -f "$msg" "$cfg"
  return "$rc"
}

# send_alert_all ENVFILE LABEL TEXT [verbose]
# Tries every configured channel independently. Returns 0 if at least one delivered (or none is configured),
# 1 if every configured channel failed. With "verbose" prints one line per channel (for the test command).
send_alert_all() {
  local f="$1" label="$2" text="$3" verbose="${4:-}" subject head url tok chat base delivered=0 tried=0 line
  head="${text%%:*}"; [[ ${#head} -lt 70 && "$head" != "$text" ]] || head="${text:0:60}"
  subject="[HA Gatekeeper @ ${label}] ${head}"
  report() { # report CHANNEL RC
    tried=$((tried + 1))
    if [[ "$2" == 0 ]]; then delivered=$((delivered + 1)); line="delivered"; else line="FAILED"; fi
    [[ -z "$verbose" ]] || printf '%-9s %s\n' "$1" "$line"
  }

  url="$(env_file_get "$f" ALERT_WEBHOOK_URL 2>/dev/null || true)"
  if [[ -n "$url" ]]; then send_webhook "$url" "[HA Gatekeeper @ ${label}] ${text}" >/dev/null 2>&1; report webhook $?; fi

  url="$(env_file_get "$f" ALERT_NTFY_URL 2>/dev/null || true)"
  if [[ -n "$url" ]]; then
    tok="$(env_file_get "$f" ALERT_NTFY_TOKEN 2>/dev/null || true)"
    {
      printf 'url = "%s"\n' "$url"
      printf 'header = "Title: %s"\n' "$(alert_ascii "$subject")"
      printf 'header = "Priority: high"\n'
      [[ -z "$tok" ]] || printf 'header = "Authorization: Bearer %s"\n' "$tok"
    } | curl -fsS --max-time 15 -o /dev/null -K - -d "$text" >/dev/null 2>&1
    report ntfy $?
  fi

  tok="$(env_file_get "$f" ALERT_TELEGRAM_BOT_TOKEN 2>/dev/null || true)"
  chat="$(env_file_get "$f" ALERT_TELEGRAM_CHAT_ID 2>/dev/null || true)"
  if [[ -n "$tok" ]]; then
    base="$(env_file_get "$f" ALERT_TELEGRAM_API_BASE 2>/dev/null || true)"; base="${base:-https://api.telegram.org}"
    printf 'url = "%s/bot%s/sendMessage"\n' "${base%/}" "$tok" | curl -fsS --max-time 15 -o /dev/null -K - \
      --data-urlencode "chat_id=${chat}" --data-urlencode "text=${subject}"$'\n\n'"${text}" >/dev/null 2>&1
    report telegram $?
  fi

  if [[ -n "$(env_file_get "$f" ALERT_EMAIL_TO 2>/dev/null || true)" && -n "$(env_file_get "$f" SMTP_HOST 2>/dev/null || true)" ]]; then
    send_email_curl "$f" "$subject" "$text" >/dev/null 2>&1
    report email $?
  fi

  (( tried == 0 || delivered > 0 ))
}

