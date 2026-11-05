#!/usr/bin/env bash
#
# auto-fix-telegram-daemon.sh — long-polling Telegram listener.
#
# Holds one HTTP request open against Telegram's getUpdates endpoint with
# timeout=25s. Telegram returns immediately when a new message arrives, OR
# returns empty after 25s and we re-call. Effective latency from /autofix
# being sent to action being taken: 1-3 seconds.
#
# Runs as a single long-lived daemon under launchd with KeepAlive:true.
# If it crashes, launchd restarts it automatically.
#
# Recognized commands (from TELEGRAM_ALERT_CHAT_ID only):
#   /autofix       — reset state + fire auto-fix-check.sh on all 3 repos
#   /status        — reply with current CI state + open auto-fix PRs
#   /help          — list commands

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

mkdir -p "$(dirname "$LOG_FILE")"

log() { echo "[$(date '+%Y-%m-%dT%H:%M:%S')] $*" >> "$LOG_FILE"; }

# Remediation approve helper (parse_process_it) — from the installed scripts, or the
# source tree when run in-repo. Function defs only, no side effects at source time.
HERE_D="$(cd "$(dirname "$0")" && pwd)"
. "$HERE_D/remediation/approve.sh" 2>/dev/null || . "$HOME/.claude/scripts/remediation/approve.sh" 2>/dev/null || true
. "$HERE_D/lib/autonomy.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/autonomy.sh" 2>/dev/null || true

reply() {
  curl -sS -m 10 -X POST \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d chat_id="${TELEGRAM_ALERT_CHAT_ID}" \
    -d parse_mode=Markdown \
    -d disable_web_page_preview=true \
    -d text="$1" >/dev/null
}

log "=== daemon starting (PID $$) ==="

# Main loop
while true; do
  LAST_ID=0
  if [[ -f "$UPDATE_ID_FILE" ]]; then
    LAST_ID=$(cat "$UPDATE_ID_FILE" 2>/dev/null || echo 0)
  fi

  # Long-poll: blocks up to 30s on Telegram's server. Returns immediately
  # when a message arrives. -m 35 = curl overall timeout slightly above
  # Telegram's poll timeout so we don't kill mid-response.
  RESP=$(curl -sS -m 35 \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getUpdates?offset=$((LAST_ID + 1))&timeout=30&limit=10" 2>/dev/null)

  CURL_EXIT=$?
  if (( CURL_EXIT != 0 )) || [[ -z "$RESP" ]] || ! echo "$RESP" | jq -e '.ok == true' >/dev/null 2>&1; then
    log "getUpdates failed (curl=$CURL_EXIT) — backoff 5s"
    sleep 5
    continue
  fi

  # Process each update
  echo "$RESP" | jq -c '.result[]' 2>/dev/null | while IFS= read -r upd; do
    UPDATE_ID=$(echo "$upd" | jq -r '.update_id')
    TEXT=$(echo "$upd" | jq -r '.message.text // empty')
    CHAT_ID=$(echo "$upd" | jq -r '.message.chat.id // empty')
    FROM=$(echo "$upd" | jq -r '.message.from.username // .message.from.first_name // "unknown"')

    echo "$UPDATE_ID" > "$UPDATE_ID_FILE"

    if [[ "$CHAT_ID" != "$TELEGRAM_ALERT_CHAT_ID" ]]; then
      log "ignored msg from chat=$CHAT_ID user=$FROM"
      continue
    fi

    CMD=$(echo "$TEXT" | awk '{print $1}' | sed 's/@.*$//')

    case "$CMD" in
      /autofix)
        log "$FROM triggered /autofix"
        reply "🔧 Manual auto-fix triggered. Resetting state + scanning all 3 repos. Investigation runs typically take 10-15 min per failing repo. You'll get a PR-link Telegram per fix."
        if [[ -f ~/.claude/auto-fix-state.json ]]; then
          jq '
            .["$OS_ORG/ebda-store"] = "0"
            | .["$OS_ORG/ebda-whatsapp"] = "0"
            | .["$OS_ORG/ebda-studio"] = "0"
          ' ~/.claude/auto-fix-state.json > /tmp/auto-fix-state.json.tmp
          mv /tmp/auto-fix-state.json.tmp ~/.claude/auto-fix-state.json
        fi
        nohup bash "$HOME/.claude/scripts/auto-fix-check.sh" >> "$HOME/Library/Logs/auto-fix.log" 2>&1 &
        disown
        ;;

      /status)
        log "$FROM requested /status"
        STORE_LATEST=$(gh run list --repo $OS_ORG/ebda-store --workflow=ci.yml --limit 1 --json status,conclusion,headSha 2>/dev/null \
                      | jq -r '.[0] | "\(.status) \(.conclusion // "-") sha=\(.headSha[0:8])"' 2>/dev/null || echo "?")
        WA_LATEST=$(gh run list --repo $OS_ORG/ebda-whatsapp --workflow=pr-validation.yml --limit 1 --json status,conclusion,headSha 2>/dev/null \
                      | jq -r '.[0] | "\(.status) \(.conclusion // "-") sha=\(.headSha[0:8])"' 2>/dev/null || echo "?")
        CRM_LATEST=$(gh run list --repo $OS_ORG/ebda-studio --workflow=ci.yml --limit 1 --json status,conclusion,headSha 2>/dev/null \
                      | jq -r '.[0] | "\(.status) \(.conclusion // "-") sha=\(.headSha[0:8])"' 2>/dev/null || echo "?")
        OPEN_PRS=$(gh pr list --repo $OS_ORG/ebda-store --state=open --head "auto-fix/" --json number,title 2>/dev/null \
                     | jq -r '.[] | "  #\(.number) \(.title[0:60])"' 2>/dev/null || echo "  none")
        if [[ -z "$OPEN_PRS" ]]; then OPEN_PRS="  none"; fi
        reply "📊 *CI Status*
*STORE:* \`$STORE_LATEST\`
*WA:* \`$WA_LATEST\`
*CRM:* \`$CRM_LATEST\`

*Open auto-fix PRs:*
$OPEN_PRS"
        ;;

      /help|/start)
        log "$FROM requested /help"
        reply "🤖 *Ebda OS auto-fix bot commands*

\`/autofix\` — reset state + scan all 3 repos for failures right now (don't wait for the 2h cron). Telegrams a PR link per fix.

\`/status\` — current CI state for store / whatsapp / studio + open auto-fix PRs.

\`/kill\` freeze all autonomy · \`/resume\` re-enable it.

\`process it #<pr>\` — approve a large (>150-line) remediation fix so it flows through the gate.

\`/help\` — this message.

Auto-fixes also run automatically every 2h via Layer A (in-session) + Layer B (launchd) + Layer C (cloud watchdog). And the existing notify-failure workflows still alert you within 2 min of any new CI failure."
        ;;

      "")
        ;;

      process)
        _pr="$(parse_process_it "$TEXT")"
        if [[ -n "$_pr" ]]; then
          log "$FROM approved remediation PR #$_pr via 'process it'"
          reply "⏳ Approving remediation PR #$_pr — enqueueing it into the gate."
          nohup bash "$HOME/.claude/scripts/remediate.sh" --approve "$_pr" \
            >> "$HOME/Library/Logs/auto-fix.log" 2>&1 &
          disown
        else
          reply "To approve a remediation fix, send \`process it #<pr>\`."
        fi
        ;;

      /kill)
        autonomy_kill; log "$FROM froze autonomy"
        reply "🛑 Autonomy FROZEN. All auto-fix/auto-merge paused — detect + notify only. Send \`/resume\` to re-enable."
        ;;

      /resume)
        autonomy_resume; log "$FROM resumed autonomy"
        reply "✅ Autonomy RESUMED. Real-time remediation is live again."
        ;;

      # Catch-all for unknown slash commands. MUST stay after every explicit /cmd arm: bash
      # takes the first matching pattern, and while this sat above /kill and /resume it
      # shadowed both (shellcheck SC2221/SC2222) — the kill switch replied "Unknown command".
      /*)
        log "$FROM unknown command: $CMD"
        reply "Unknown command \`$CMD\`. Try \`/help\`."
        ;;

      *)
        log "$FROM non-command msg: $TEXT"
        ;;
    esac
  done
  # Test seam: one poll iteration, then stop (the real daemon never sets this).
  [[ -n "${TG_ONESHOT:-}" ]] && exit 0
done
