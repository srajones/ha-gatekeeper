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
