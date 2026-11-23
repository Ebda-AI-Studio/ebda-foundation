#!/usr/bin/env bash
# Ebda AI OS - alert-drill.sh: fire ONE synthetic alert through the real alert path and prove it was delivered (obs row 44).
#   alert-drill.sh            send one message, record the proof, exit 0 delivered / 1 NOT delivered
#   alert-drill.sh --dry-run  show what would be sent; sends nothing, writes no record
# The real path = notify.sh, the OS's single alert primitive (local Telegram first, the brain's /api/telegram/send as fallback).
# Proof recorded: drill id, UTC time, which path carried it (telegram | brain) and the Telegram message_id when the local path did.
# Record: $ALERT_DRILL_LOG (default ~/Library/Logs/ebda-alert-drill.log), one JSON line per drill. Run it once per release/quarter,
# never in a loop: every run is one real Telegram message to Ahmad. Delivered = Telegram accepted it (ok:true + message_id);
# that a human saw it is the one thing a script cannot prove - the message says "reply not needed" and carries the id to match.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NOTIFY="${ALERT_DRILL_NOTIFY:-$HERE/notify.sh}"
LOG="${ALERT_DRILL_LOG:-$HOME/Library/Logs/ebda-alert-drill.log}"
DRY=0
case "${1:-}" in
  "") ;;
  --dry-run) DRY=1 ;;
  -h|--help) sed -n 2,11p "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "alert-drill: unknown option $1" >&2; exit 2 ;;
esac
at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
id="drill-$(date -u +%Y%m%dT%H%M%SZ)-$RANDOM"
body="Synthetic alert drill, no action needed. id=$id at=$at"
if [ "$DRY" = 1 ]; then echo "alert-drill: DRY RUN, would send via $NOTIFY: ALERT DRILL | $body"; exit 0; fi
[ -x "$NOTIFY" ] || [ -f "$NOTIFY" ] || { echo "alert-drill: notify primitive not found: $NOTIFY" >&2; exit 2; }
out="$(bash "$NOTIFY" "ALERT DRILL" "$body" 2>&1)"; rc=$?
path=none; mid=""
if [ "$rc" = 0 ]; then
  case "$out" in
    *"sent via brain"*) path=brain ;;
    *"telegram ok:true"*) path=telegram; mid="$(printf '%s' "$out" | sed -nE 's/.*message_id=([0-9]+).*/\1/p' | head -n1)" ;;
    *) rc=1; out="$out"$'\n'"alert-drill: notify exited 0 but reported no delivery line" ;;
  esac
fi
delivered=false; [ "$rc" = 0 ] && delivered=true
mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
printf '{"id":"%s","at":"%s","delivered":%s,"path":"%s","messageId":%s}\n' "$id" "$at" "$delivered" "$path" "${mid:-null}" >> "$LOG" 2>/dev/null \
  || echo "alert-drill: could not write the record to $LOG" >&2
if [ "$delivered" = true ]; then
  echo "alert-drill: DELIVERED id=$id path=$path${mid:+ message_id=$mid} (record: $LOG)"; exit 0
fi
echo "alert-drill: NOT DELIVERED id=$id: $(printf '%s' "$out" | sed -E 's#bot[0-9]+:[A-Za-z0-9_-]+#bot<redacted>#g' | tail -n 3 | tr '\n' ' ')" >&2
exit 1
