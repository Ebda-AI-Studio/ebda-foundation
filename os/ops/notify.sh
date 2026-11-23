#!/usr/bin/env bash
# Ebda AI OS — universal notification primitive.
# EVERY OS function (cost guard, audits, remediation, builds, workflow completions,
# drift, doc-reality) notifies Ahmad through the Ebda Telegram bot via THIS script.
# One channel for the whole OS.
#
# Usage:
#   ops/notify.sh "Title" "body line one" "body line two"
#   echo "body" | ops/notify.sh "Title"
#   ops/notify.sh --silent "Title" "body"   # no sound (disable_notification)
#
# Credentials, first hit wins (F-TG-1: the services env no longer holds them; the bot token lives in the macOS Keychain):
#   1. environment                   TELEGRAM_BOT_TOKEN / TELEGRAM_ALERT_CHAT_ID
#   2. macOS Keychain                services `ebda-telegram-bot` (token) and `ebda-telegram-alert-chat-id` (chat id)
#   3. $OS_SERVICES_ENV              legacy ~/.whisky-services.env keys of the same names
# If local delivery fails (no creds, Bot API not ok, network) it falls back to the brain (brain-send.sh text, POST /api/telegram/send,
# which owns the same bot, Ruling RR-tg-brain-owns). Both paths failing exits 1 with a loud stderr line: never a silent "sent".
# The token is never printed or logged (curl reads it from a 0600 config file, not argv).
# shellcheck source=lib/os-config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/os-config.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-config.sh" 2>/dev/null || true
command -v os_config_load >/dev/null 2>&1 && os_config_load
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

silent=false
if [ "${1:-}" = "--silent" ]; then silent=true; shift; fi
title="${1:-Ebda AI OS}"; shift || true
if [ "$#" -gt 0 ]; then body="$*"; else body="$(cat)"; fi
msg="🥃 Ebda AI OS — ${title}"
[ -n "${body:-}" ] && msg="${msg}"$'\n'"${body}"

kc() { security find-generic-password -s "$1" -w 2>/dev/null; }

local_send() {
  local token="${TELEGRAM_BOT_TOKEN:-}" chat="${TELEGRAM_ALERT_CHAT_ID:-}"
  [ -n "$token" ] || token="$(kc ebda-telegram-bot)"
  [ -n "$chat" ] || chat="$(kc ebda-telegram-alert-chat-id)"
  if [ -z "$token" ] || [ -z "$chat" ]; then
    local svc="${OS_SERVICES_ENV:-$HOME/.whisky-services.env}"
    if [ -f "$svc" ]; then
      local t2 c2
      # shellcheck disable=SC1090
      { IFS= read -r t2; IFS= read -r c2; } < <( set -a; . "$svc"; set +a; printf '%s\n%s\n' "${TELEGRAM_BOT_TOKEN:-}" "${TELEGRAM_ALERT_CHAT_ID:-}" )
      [ -n "$token" ] || token="$t2"
      [ -n "$chat" ] || chat="$c2"
    fi
  fi
  [ -n "$token" ] && [ -n "$chat" ] || { echo "notify: no local Telegram credentials (env, Keychain ebda-telegram-bot / ebda-telegram-alert-chat-id, services env)" >&2; return 1; }
  local cfg resp; cfg="$(mktemp)"; chmod 600 "$cfg"
  printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$token" > "$cfg"
  resp="$(curl -sS -m 15 -K "$cfg" --data-urlencode "chat_id=${chat}" --data-urlencode "disable_notification=${silent}" --data-urlencode "text=${msg}" 2>&1)"
  rm -f "$cfg"
  if grep -q '"ok":[[:space:]]*true' <<<"$resp"; then echo "notify: sent (telegram ok:true)"; return 0; fi
  # never echo the raw response on failure paths that could contain the URL/token (curl errors can)
  echo "notify: Telegram API did not return ok:true ($(printf '%s' "$resp" | sed -E 's#bot[0-9]+:[A-Za-z0-9_-]+#bot<redacted>#g' | head -c 160))" >&2
  return 1
}

if local_send; then exit 0; fi
echo "notify: local delivery failed, falling back to the brain" >&2
if [ -x "$HERE/brain-send.sh" ] && "$HERE/brain-send.sh" text "$msg" >/dev/null 2>&1; then echo "notify: sent via brain"; exit 0; fi
if [ -x "$HOME/.claude/scripts/brain-send.sh" ] && "$HOME/.claude/scripts/brain-send.sh" text "$msg" >/dev/null 2>&1; then echo "notify: sent via brain"; exit 0; fi
echo "notify: FAILED - local Telegram and the brain both refused; the alert '${title}' was NOT delivered" >&2
exit 1
