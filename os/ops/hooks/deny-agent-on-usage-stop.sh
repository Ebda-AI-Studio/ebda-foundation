#!/usr/bin/env bash
# claude-hook: PreToolUse
# deny-agent-on-usage-stop.sh - refuse NEW subagents while ~/.whisky-os-state/usage/fanout-stop exists.
#
# WHY (2026-10-26): ~10 parallel Sonnet agents hit the WEEKLY limit at ~00:40 local time with no warning. usage-sentinel.sh
# writes fanout-stop at >= 80 % weekly use; this hook is the deterministic enforcement (a rule in prose is a preference).
# Only the Agent/Task tools are denied; the main session keeps working. Remove the file (or Telegram /resume) to lift it.
# A malformed payload is ALLOWED (a broken hook must not brick every session). exit 2 = deny.
set -uo pipefail
payload="$(cat 2>/dev/null || true)"
STOP="${USAGE_STATE:-$HOME/.whisky-os-state/usage}/fanout-stop"
tool="$(printf '%s' "$payload" | python3 -I -c 'import json,sys
try: print(json.load(sys.stdin).get("tool_name",""))
except Exception: print("")' 2>/dev/null)"
case "$tool" in Agent|Task) ;; *) exit 0 ;; esac
[ -e "$STOP" ] || exit 0
echo "BLOCKED: weekly usage is at the fan-out limit ($(tr '\n' ' ' < "$STOP" 2>/dev/null)). No new subagents until it is lifted: rm $STOP (or Telegram /resume). Budget first: fewer agents, Sonnet only." >&2
exit 2
