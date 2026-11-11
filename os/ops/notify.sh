#!/usr/bin/env bash
# Whisky AI OS — universal notification primitive.
# EVERY OS function (cost guard, audits, remediation, builds, workflow completions,
# drift, doc-reality) notifies Ahmad through the Ebda Telegram bot via THIS script.
# One channel for the whole OS.
#
# Usage:
#   ops/notify.sh "Title" "body line one" "body line two"
#   echo "body" | ops/notify.sh "Title"
#   ops/notify.sh --silent "Title" "body"   # no sound (disable_notification)
#
# Creds come from the services env file ($OS_SERVICES_ENV, default ~/.whisky-services.env; local, chmod 600, never
# committed): TELEGRAM_BOT_TOKEN (the Ebda bot) and TELEGRAM_ALERT_CHAT_ID. No chat id is hardcoded anywhere.
# shellcheck source=lib/os-config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/os-config.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-config.sh" 2>/dev/null || true
command -v os_config_load >/dev/null 2>&1 && os_config_load
set -uo pipefail

SVC_ENV="$OS_SERVICES_ENV"
if [ ! -f "$SVC_ENV" ]; then
  echo "notify: missing services env at $SVC_ENV (needs TELEGRAM_BOT_TOKEN + TELEGRAM_ALERT_CHAT_ID)" >&2
  exit 1
fi
# shellcheck disable=SC1090
set -a; . "$SVC_ENV"; set +a
: "${TELEGRAM_BOT_TOKEN:?TELEGRAM_BOT_TOKEN unset in $SVC_ENV}" "${TELEGRAM_ALERT_CHAT_ID:?TELEGRAM_ALERT_CHAT_ID unset in $SVC_ENV}"

silent=false
if [ "${1:-}" = "--silent" ]; then silent=true; shift; fi

title="${1:-Whisky AI OS}"; shift || true
if [ "$#" -gt 0 ]; then body="$*"; else body="$(cat)"; fi

msg="🥃 Whisky AI OS — ${title}"
[ -n "${body:-}" ] && msg="${msg}"$'\n'"${body}"

curl -sS -m 15 "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  --data-urlencode "chat_id=${TELEGRAM_ALERT_CHAT_ID}" \
  --data-urlencode "disable_notification=${silent}" \
  --data-urlencode "text=${msg}" \
  | { command -v jq >/dev/null && jq -e '.ok' >/dev/null && echo "notify: sent" || echo "notify: sent (unverified)"; }
