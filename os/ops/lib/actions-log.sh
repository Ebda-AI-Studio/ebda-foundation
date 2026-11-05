# shellcheck shell=bash
# ops/lib/actions-log.sh - every OS mutation is appended to ONE log: ~/.whisky-os-state/actions.jsonl
#   os_action <who> <what> <why> [evidence-path-or-text]
# One JSON object per line {ts, who, what, why, evidence}. Quoting is done by python3, so arbitrary text is safe.
# Never fails the caller: a log write must not block the action it records (the action is still printed to stderr).
os_action() {
  local f="${OS_ACTIONS_LOG:-$HOME/.whisky-os-state/actions.jsonl}"
  mkdir -p "$(dirname "$f")" 2>/dev/null || return 0
  WHO="$1" WHAT="$2" WHY="${3:-}" EVID="${4:-}" python3 - "$f" <<'PY' 2>/dev/null || true
import json, os, sys, time
rec = {"ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "who": os.environ["WHO"],
       "what": os.environ["WHAT"], "why": os.environ["WHY"], "evidence": os.environ["EVID"]}
with open(sys.argv[1], "a") as fh:
    fh.write(json.dumps(rec, ensure_ascii=False) + "\n")
PY
}
