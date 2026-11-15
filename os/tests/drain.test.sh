#!/usr/bin/env bash
# ops/drain.sh against a stubbed gh, merge gate and curl: off-by-default, green-only, risky hold, gate backoff, stop file, lock,
# stall -> one finding -> cleared snapshot, unreadable GitHub is not a stall.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DRAIN="$ROOT/os/ops/drain.sh"
p=0; f=0
ok() { echo "PASS: $1"; p=$((p+1)); }
no() { echo "FAIL: $1"; f=$((f+1)); }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME/.claude/handoff" "$T/bin" "$T/checkout"
export OS_STATE_DIR="$T/state" OS_LOCK_DIR="$T/locks" EBDA_OS_LOCAL_ENV="$T/none.env" OS_SERVICES_ENV="$T/none.services"
export PATH="$T/bin:/usr/bin:/bin:/usr/sbin:/sbin"
SD="$OS_STATE_DIR/drain"
export PRS_FILE="$T/prs.json" GATE_LOG="$T/gate.log" GATE_RC=0 POST_LOG="$T/post.log"

cat > "$T/bin/gh" <<'STUB'
#!/bin/bash
[ -n "${GH_FAIL:-}" ] && exit 1
cat "$PRS_FILE"
STUB
cat > "$T/bin/curl" <<'STUB'
#!/bin/bash
for a in "$@"; do case "$a" in @*) cat "${a#@}" >> "$POST_LOG"; echo >> "$POST_LOG" ;; esac; done
exit 0
STUB
cat > "$T/gate.sh" <<'STUB'
#!/bin/bash
echo "$*" >> "$GATE_LOG"; exit "${GATE_RC:-0}"
STUB
chmod +x "$T/bin/gh" "$T/bin/curl" "$T/gate.sh"

# pr <num> <sha> <checks:green|pending|red|none> [labels,comma] [mergeable] [draft]
pr() {
  python3 -I - "$@" <<'PY'
import json, sys
n, sha, checks = int(sys.argv[1]), sys.argv[2], sys.argv[3]
labels = [x for x in (sys.argv[4] if len(sys.argv) > 4 else "").split(",") if x]
mer = sys.argv[5] if len(sys.argv) > 5 else "MERGEABLE"
draft = (sys.argv[6] if len(sys.argv) > 6 else "") == "draft"
roll = {"green": [{"status": "COMPLETED", "conclusion": "SUCCESS"}], "pending": [{"status": "IN_PROGRESS", "conclusion": ""}],
        "red": [{"status": "COMPLETED", "conclusion": "FAILURE"}], "none": []}[checks]
print(json.dumps({"number": n, "headRefOid": sha, "mergeable": mer, "isDraft": draft, "statusCheckRollup": roll, "labels": [{"name": l} for l in labels]}))
PY
}
prs() { { echo '['; local first=1; for j in "$@"; do [ "$first" = 1 ] || echo ','; echo "$j"; first=0; done; echo ']'; } > "$PRS_FILE"; }
run() { bash "$DRAIN" --repo o/r --dir "$T/checkout" --gate "$T/gate.sh" --name r --once "$@" 2>&1; }
reset() { rm -rf "$SD" "$GATE_LOG" "$POST_LOG" "$T/locks" "$HOME/.claude/handoff/drain.stop"; : > "$GATE_LOG"; mkdir -p "$SD"; GATE_RC=0; unset GH_FAIL; }
on() { touch "$SD/r.enabled"; }
calls() { wc -l < "$GATE_LOG" | tr -d ' '; }

reset; prs "$(pr 1 aaaaaaa1 green)"
run >/dev/null; [ "$(calls)" = 0 ] && ok "off until the enabled marker exists: no gate call" || no "ran while off"

reset; on; prs "$(pr 1 aaaaaaa1 green)"
run >/dev/null; [ "$(calls)" = 1 ] && grep -q '^1 aaaaaaa1 --repo o/r ' "$GATE_LOG" && ok "green+mergeable PR goes through the gate, head pinned, --repo passed" || no "green PR not gated ($(cat "$GATE_LOG"))"

reset; on; prs "$(pr 1 a1 pending)" "$(pr 2 a2 red)" "$(pr 3 a3 none)" "$(pr 4 a4 green '' CONFLICTING)" "$(pr 5 a5 green '' MERGEABLE draft)"
run >/dev/null; [ "$(calls)" = 0 ] && ok "pending / red / zero-check / conflicting / draft PRs are never gated" || no "gated a non-green PR"

reset; on; prs "$(pr 1 a1 green risky-path)"
run --hold-risky >/dev/null; [ "$(calls)" = 0 ] && ok "risky PR without ai-review-passed is held" || no "risky PR gated unreviewed"
prs "$(pr 1 a1 green risky-path,ai-review-passed)"
run --hold-risky >/dev/null; [ "$(calls)" = 1 ] && ok "risky PR with ai-review-passed is gated" || no "reviewed risky PR not gated"
# money gate (per label): `risky` needs money-review-passed, ai-review-passed alone is not enough
reset; on; prs "$(pr 1 a1 green risky,ai-review-passed)"
run --hold-risky >/dev/null; [ "$(calls)" = 0 ] && ok "risky + ai-review-passed WITHOUT money-review-passed is held (not merged)" || no "money gate open: risky merged without money-review-passed"
prs "$(pr 1 a1 green risky,risky-path,money-review-passed)"
run --hold-risky >/dev/null; [ "$(calls)" = 0 ] && ok "risky + risky-path + money-review-passed but NO ai-review-passed is held (gates AND)" || no "gate collapse: merged without ai-review-passed"
prs "$(pr 1 a1 green risky,ai-review-passed,money-review-passed)"
run --hold-risky >/dev/null; [ "$(calls)" = 1 ] && ok "risky + both reviews is gated/merged" || no "risky with money-review-passed not gated"
reset; on; prs "$(pr 1 a1 green risky-path)"
run >/dev/null; [ "$(calls)" = 1 ] && ok "without --hold-risky the label does not hold" || no "held without --hold-risky"

reset; on; prs "$(pr 1 a1 green)"; GATE_RC=1 run >/dev/null; GATE_RC=1 run >/dev/null
[ "$(calls)" = 1 ] && ok "a failed gate is not retried on the same head inside 10 minutes" || no "gate retried ($(calls) calls)"
prs "$(pr 1 a1b green)"; GATE_RC=1 run >/dev/null; [ "$(calls)" = 2 ] && ok "a new head is gated again" || no "new head not gated"

reset; on; prs "$(pr 1 a1 green)"; touch "$SD/r.stop"; run >/dev/null; [ "$(calls)" = 0 ] && ok "stop file halts" || no "ran with stop file"
reset; on; prs "$(pr 1 a1 green)"; touch "$HOME/.claude/handoff/drain.stop"; run >/dev/null; [ "$(calls)" = 0 ] && ok "global drain.stop halts" || no "ran with global stop"

reset; on; prs "$(pr 1 a1 green)"
sleep 30 & HOLDER=$!; mkdir -p "$T/locks/drain-r"; echo "$HOLDER" > "$T/locks/drain-r/pid"
run >/dev/null; [ "$(calls)" = 0 ] && ok "a live lock holder: second instance does nothing" || no "ran despite a live lock"
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
rm -rf "$T/locks"; mkdir -p "$T/locks/drain-r-pr1"; sleep 30 & HOLDER=$!; echo "$HOLDER" > "$T/locks/drain-r-pr1/pid"
run >/dev/null; [ "$(calls)" = 0 ] && ok "a per-PR lock held elsewhere: that PR is skipped" || no "double gating on one PR"
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null

# stall: eligible PR, gate keeps failing, no progress for 2 h -> exactly the stall finding, then a cleared snapshot
reset; on; prs "$(pr 1 a1 green)"; export OS_BRAIN_URL=http://brain.test INGEST_TOKEN=tok
echo $(( $(date +%s) - 7200 )) > "$SD/r.progress"
GATE_RC=1 run --stall-min 60 >/dev/null
grep -q '"kind": "drain-stall"' "$POST_LOG" && grep -q '"source": "drain-r"' "$POST_LOG" && grep -q '"stalled":true' "$SD/r.heartbeat" && ok "60+ min without progress while a green PR waits: drain-stall finding posted, heartbeat says stalled" || no "no stall finding ($(cat "$POST_LOG" 2>/dev/null | head -c 200))"
: > "$POST_LOG"; GATE_RC=1 run --stall-min 60 >/dev/null
[ ! -s "$POST_LOG" ] && ok "an unchanged stall is not re-posted inside 10 minutes (the brain alerts once)" || no "stall re-posted"
prs "$(pr 1 a1 pending)"; run --stall-min 60 >/dev/null
grep -q '"findings": \[\]' "$POST_LOG" && grep -q '"reconcile"' "$POST_LOG" && ok "nothing waiting: progress, and a snapshot with no findings resolves the stall" || no "stall not cleared ($(head -c 200 "$POST_LOG"))"

reset; on; prs "$(pr 1 a1 green)"; echo $(( $(date +%s) - 7200 )) > "$SD/r.progress"
GH_FAIL=1 run --stall-min 60 >/dev/null
[ ! -s "$POST_LOG" ] && ! grep -q '"stalled":true' "$SD/r.heartbeat" && ok "unreadable GitHub is not judged as a stall" || no "stall judged on unreadable GitHub"

reset; on; run --bogus >/dev/null 2>&1; [ $? = 2 ] && ok "unknown flag exits 2" || no "unknown flag accepted"
echo "drain: $p passed, $f failed"; [ "$f" = 0 ]
