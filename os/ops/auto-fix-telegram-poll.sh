#!/usr/bin/env bash
#
# auto-fix-telegram-poll.sh — listens for Telegram commands sent to the bot.
# Polls /getUpdates every minute (via launchd). Recognized commands:
#
#   /autofix       — reset state + fire auto-fix-check.sh
#   /status        — reply with current auto-fix-state.json contents
#   /help          — list commands
#
# Only responds to messages from TELEGRAM_ALERT_CHAT_ID (Ahmad's DM).
# Other chats are silently ignored.
#
# Designed to be called from launchd every 60s:
#   ~/Library/LaunchAgents/com.ahmadsharaf.auto-fix-telegram.plist
#
# State:
#   ~/.claude/auto-fix-telegram-update-id — last processed update_id
#   (prevents re-handling the same /autofix on every poll)

# shellcheck source=lib/os-config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/os-config.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-config.sh" 2>/dev/null || true
command -v os_config_load >/dev/null 2>&1 && os_config_load
set -uo pipefail

# Telegram creds live in a local env file (chmod 600, never committed). They were hard-coded
# defaults here until 2026-10-08; that token sits in git history and must be rotated.
TG_ENV="${TG_ENV:-$OS_SERVICES_ENV}"
# shellcheck source=/dev/null
[ -f "$TG_ENV" ] && { set -a; . "$TG_ENV"; set +a; }
: "${TELEGRAM_BOT_TOKEN:?TELEGRAM_BOT_TOKEN unset — put it in $TG_ENV}"
: "${TELEGRAM_ALERT_CHAT_ID:?TELEGRAM_ALERT_CHAT_ID unset — put it in $TG_ENV}"
UPDATE_ID_FILE="$HOME/.claude/auto-fix-telegram-update-id"
LOG_FILE="$HOME/Library/Logs/auto-fix-telegram.log"
LOCK_DIR="/tmp/auto-fix-telegram.lock.d"

mkdir -p "$(dirname "$LOG_FILE")"

log() { echo "[$(date '+%Y-%m-%dT%H:%M:%S')] $*" >> "$LOG_FILE"; }

# Reply to user via Telegram
reply() {
  local msg="$1"
  curl -sS -m 10 -X POST \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d chat_id="${TELEGRAM_ALERT_CHAT_ID}" \
    -d parse_mode=Markdown \
    -d disable_web_page_preview=true \
    -d text="$msg" >/dev/null
}

# Lock — don't double-poll if previous still running
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  exit 0   # silent: previous still running, normal case
fi
trap 'rm -rf "$LOCK_DIR"' EXIT

# Get the last-processed update_id
LAST_ID=0
if [[ -f "$UPDATE_ID_FILE" ]]; then
  LAST_ID=$(cat "$UPDATE_ID_FILE" 2>/dev/null || echo 0)
fi

# Fetch new updates — long-poll for 0s (immediate return)
RESP=$(curl -sS -m 10 \
  "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getUpdates?offset=$((LAST_ID + 1))&timeout=0&limit=10" 2>/dev/null)

if [[ -z "$RESP" ]] || ! echo "$RESP" | jq -e '.ok == true' >/dev/null 2>&1; then
  log "telegram getUpdates failed or returned non-ok"
  exit 0
fi

# Process each update
echo "$RESP" | jq -c '.result[]' 2>/dev/null | while IFS= read -r upd; do
  UPDATE_ID=$(echo "$upd" | jq -r '.update_id')
  TEXT=$(echo "$upd" | jq -r '.message.text // empty')
  CHAT_ID=$(echo "$upd" | jq -r '.message.chat.id // empty')
  FROM=$(echo "$upd" | jq -r '.message.from.username // .message.from.first_name // "unknown"')

  # Track this update as seen (regardless of whether we act on it)
  echo "$UPDATE_ID" > "$UPDATE_ID_FILE"

  # Only respond to Ahmad's chat
  if [[ "$CHAT_ID" != "$TELEGRAM_ALERT_CHAT_ID" ]]; then
    log "ignored msg from chat=$CHAT_ID user=$FROM"
    continue
  fi

  # Strip command from message — match command name only (ignore args + bot suffix)
  CMD=$(echo "$TEXT" | awk '{print $1}' | sed 's/@.*$//')

  case "$CMD" in
    /autofix)
      log "$FROM triggered /autofix"
      reply "🔧 Manual auto-fix triggered. Resetting state + scanning all 3 repos now. Investigation runs typically take 10-15 min per failing repo. You'll get a PR-link Telegram per fix."
      # Reset state file so latest failures are re-evaluated
      if [[ -f ~/.claude/auto-fix-state.json ]]; then
        jq '
          .["$OS_ORG/ebda-store"] = "0"
          | .["$OS_ORG/ebda-whatsapp"] = "0"
          | .["$OS_ORG/ebda-studio"] = "0"
        ' ~/.claude/auto-fix-state.json > /tmp/auto-fix-state.json.tmp
        mv /tmp/auto-fix-state.json.tmp ~/.claude/auto-fix-state.json
      fi
      # Fire the main script in background (don't block this poller)
      nohup bash "$HOME/.claude/scripts/auto-fix-check.sh" >> "$HOME/Library/Logs/auto-fix.log" 2>&1 &
      disown
      ;;

    /status)
      log "$FROM requested /status"
      STATE=$(cat ~/.claude/auto-fix-state.json 2>/dev/null || echo "{}")
      # Get latest CI run state for each repo
      STORE_LATEST=$(gh run list --repo $OS_ORG/ebda-store --workflow=ci.yml --limit 1 --json status,conclusion,headSha 2>/dev/null \
                    | jq -r '.[0] | "\(.status) \(.conclusion // "-") sha=\(.headSha[0:8])"' 2>/dev/null || echo "?")
      WA_LATEST=$(gh run list --repo $OS_ORG/ebda-whatsapp --workflow=pr-validation.yml --limit 1 --json status,conclusion,headSha 2>/dev/null \
                    | jq -r '.[0] | "\(.status) \(.conclusion // "-") sha=\(.headSha[0:8])"' 2>/dev/null || echo "?")
      CRM_LATEST=$(gh run list --repo $OS_ORG/ebda-studio --workflow=ci.yml --limit 1 --json status,conclusion,headSha 2>/dev/null \
                    | jq -r '.[0] | "\(.status) \(.conclusion // "-") sha=\(.headSha[0:8])"' 2>/dev/null || echo "?")
      OPEN_PRS=$(gh pr list --repo $OS_ORG/ebda-store --state=open --head "auto-fix/" --json number,title 2>/dev/null \
                   | jq -r '.[] | "  #\(.number) \(.title[0:60])"' 2>/dev/null || echo "  none")
      reply "📊 *CI Status*
*STORE:* \`$STORE_LATEST\`
*WA:* \`$WA_LATEST\`
*CRM:* \`$CRM_LATEST\`

*Open auto-fix PRs:*
$OPEN_PRS"
      ;;

    /help)
      log "$FROM requested /help"
      reply "🤖 *Ebda OS auto-fix bot commands*

\`/autofix\` — reset state + scan all 3 repos for failures right now (don't wait for the 2h cron). Telegrams a PR link per fix.

\`/status\` — current CI state for store / whatsapp / studio + open auto-fix PRs.

\`/help\` — this message.

Auto-fixes also run automatically every 2 hours (Layer A in-session + Layer B launchd + Layer C cloud watchdog). And the existing notify-failure workflows still alert you within 2 min of any new CI failure."
      ;;

    "")
      # Empty or non-message update (e.g. edited message, callback query)
      ;;

    /*)
      log "$FROM unknown command: $CMD"
      reply "Unknown command \`$CMD\`. Try \`/help\`."
      ;;

    *)
      # Non-command message — silently ignore (don't be chatty)
      log "$FROM non-command msg: $TEXT"
      ;;
  esac
done
