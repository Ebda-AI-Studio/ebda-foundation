#!/usr/bin/env bash
# Whisky AI OS - weekly-usage sentinel (plan 2026-10-26 section 2.2). See lib/usage_sentinel.py for the rules.
#   usage-sentinel.sh [--json]          check; exit 0 ok / 1 act (checkpoint or fanout-stop) / 3 UNKNOWN
#   usage-sentinel.sh calibrate <n>     feed the Usage-page weekly % (Telegram /usage <n> calls this)
# At >= 80 % it writes ~/.whisky-os-state/usage/fanout-stop; agent-dispatch.sh refuses new agents while it exists.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PY="$HERE/lib/usage_sentinel.py"; [ -f "$PY" ] || PY="$HOME/.claude/scripts/lib/usage_sentinel.py"
export USAGE_NOTIFY="${USAGE_NOTIFY:-$HERE/notify.sh}"
python3 "$PY" "$@"; rc=$?
. "$HERE/lib/os-state.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-state.sh" 2>/dev/null || true
if command -v write_status >/dev/null 2>&1 && [ "${1:-}" != calibrate ]; then
  case "$rc" in 0) s=true ;; 1) s=warn ;; *) s=false ;; esac
  write_status usage-sentinel "$s" "exit $rc ($(sed -n 's/.*"status": *"\([a-z]*\)".*/\1/p' "${USAGE_STATE:-$HOME/.whisky-os-state/usage}/status.json" 2>/dev/null | head -1))" '{}'
fi
exit "$rc"
