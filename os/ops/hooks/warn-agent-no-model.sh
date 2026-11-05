#!/usr/bin/env bash
# claude-hook: PreToolUse
# warn-agent-no-model.sh — PreToolUse advisory for the Agent tool. NEVER blocks.
#
# WHY: subagents default to the parent's (expensive) model. Mechanical work belongs on
# model "sonnet" (Ahmad 2026-10-01). A subagent spawned without `model` is the silent
# cost leak, so surface it as a non-blocking systemMessage.
set -uo pipefail
payload="$(cat 2>/dev/null || true)"
printf '%s' "$payload" | python3 -I -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if d.get("tool_name") not in ("Agent", "Task"):
    sys.exit(0)
if (d.get("tool_input") or {}).get("model"):
    sys.exit(0)
print(json.dumps({"systemMessage": "subagent without model: set model: \"sonnet\" for mechanical work"}))
sys.exit(0)
'
exit 0
