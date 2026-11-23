#!/usr/bin/env bash
# Whisky AI OS - CI alert poller (plan 2026-10-26 S1). Runs on the Mac every 5 min, independent of the CI fleet.
# Pages main/nightly/deploy failures, PR runs red on a 2nd attempt, runs queued > 20 min (dead-runner signature) and
# an unreadable repo (UNKNOWN). Cancelled runs never page. Deduplicated per run. Exit 0 quiet / 1 alerted / 3 UNKNOWN.
# Env: CI_ALERT_REPOS="owner/repo ..." (default: ebda-store, ebda-foundation), CI_ALERT_QUEUED_MIN.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/args.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/args.sh" || exit 2
. "$(dirname "${BASH_SOURCE[0]}")/lib/single-instance.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/single-instance.sh" || exit 2
args_help "${BASH_SOURCE[0]}" "$@"
single_instance ci-alert
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="$HERE/lib/ci_alert.py"; [ -f "$PY" ] || PY="$HOME/.claude/scripts/lib/ci_alert.py"
export CI_ALERT_NOTIFY="${CI_ALERT_NOTIFY:-$HERE/notify.sh}"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
python3 "$PY" "$@"; rc=$?
. "$HERE/lib/os-state.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-state.sh" 2>/dev/null || true
if command -v write_status >/dev/null 2>&1; then
  case "$rc" in 0) s=true ;; 1) s=warn ;; *) s=false ;; esac
  write_status ci-alert "$s" "exit $rc" '{}'
fi
exit "$rc"
