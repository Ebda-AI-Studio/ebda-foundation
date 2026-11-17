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
export RERUN_WAIT=0 RERUN_VERIFY_SLEEP=0 STARVE_SLEEP=0 PRS_FILE="$T/prs.json" GATE_LOG="$T/gate.log" GATE_RC=0 POST_LOG="$T/post.log" MAIN_RUNS="$T/main-runs.json" RERUN_LOG="$T/rerun.log" T

# gh stub: pr list -> $PRS_FILE; run list -> main runs ($MAIN_RUNS) or, with --commit SHA, $T/runs-SHA.json; run rerun -> $RERUN_LOG;
# api compare -> {"ahead_by": $AHEAD}; api commits/SHA/statuses -> $T/status-SHA.json ([] when absent; STATUS_FAIL=1 = API error)
cat > "$T/bin/gh" <<'STUB'
#!/bin/bash
[ -n "${GH_FAIL:-}" ] && exit 1
case "$1 $2" in
  "pr list") case "$*" in *--label*) cat "$T/fixes-list.txt" 2>/dev/null ;; *) cat "$PRS_FILE" ;; esac ;;
  "run cancel") echo "$*" >> "$RERUN_LOG"; echo "completed $(cut -d' ' -f2 "$T/rs-$3" 2>/dev/null || echo 1)" > "$T/rs-$3" ;;
  "run view") rs="$(cat "$T/rs-$3" 2>/dev/null || echo "completed 1")"; case "$*" in *status,attempt*) echo "$rs" ;; *"json status"*) echo "${rs% *}" ;; *"json attempt"*) [ -n "${RUNVIEW_FAIL_ATTEMPT:-}" ] && exit 1; echo "${rs#* }" ;; esac ;;
  "run list") [ -n "${MAIN_FAIL:-}" ] && exit 1
    sha=""; while [ $# -gt 0 ]; do [ "$1" = --commit ] && sha="$2"; shift; done
    if [ -n "$sha" ]; then cat "$T/runs-$sha.json" 2>/dev/null || echo '[]'; else cat "$MAIN_RUNS"; fi ;;
  "run rerun") echo "$*" >> "$RERUN_LOG"
    case " ${REFUSE_RERUN:-} " in *" $3 "*) ;; *) a="$(cut -d' ' -f2 "$T/rs-$3" 2>/dev/null || echo 1)"; echo "queued $((a + 1))" > "$T/rs-$3" ;; esac ;;
  "api repos"*|"api "*)
    case "$2" in
      */compare/*) echo "{\"ahead_by\": ${AHEAD:-0}}" ;;
      */statuses) [ -n "${STATUS_FAIL:-}" ] && exit 1; n="${2#*/commits/}"; cat "$T/status-${n%/statuses}.json" 2>/dev/null || echo '[]' ;;
      *) echo '{}' ;;
    esac ;;
  *) exit 1 ;;
esac
STUB
cat > "$T/bin/curl" <<'STUB'
#!/bin/bash
for a in "$@"; do case "$a" in @*) cat "${a#@}" >> "$POST_LOG"; echo >> "$POST_LOG" ;; esac; done
exit 0
STUB
cat > "$T/gate.sh" <<'STUB'
#!/bin/bash
echo "$*" >> "$GATE_LOG"
# GATE_FLIP_MAIN=<main-runs file content>: the gate leaves main in that state (main turns red / pending while a gate runs)
[ -n "${GATE_FLIP_MAIN:-}" ] && printf '%s' "$GATE_FLIP_MAIN" > "$MAIN_RUNS"
exit "${GATE_RC:-0}"
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
# unique repo slug per run: drain.sh `gate_running` is a host-wide pgrep on "merge-gate.sh <pr> .*--repo <repo> ", and merge-gate.test.sh
# runs real "merge-gate.sh 1 ... --repo o/r" processes; with o/r a concurrent suite on the same runner made every gate look "already running" (main CI red 2026-11-15)
REPO_SLUG="drain-test-$$/r"
run() { bash "$DRAIN" --repo "$REPO_SLUG" --dir "$T/checkout" --gate "$T/gate.sh" --name r --once "$@" 2>&1; }
main_runs() { echo "$1" > "$MAIN_RUNS"; }   # newest first: id sha status conclusion attempt
mr() { printf '{"databaseId":%s,"headSha":"%s","status":"%s","conclusion":"%s","attempt":%s}' "$1" "$2" "$3" "$4" "${5:-1}"; }
reset() { rm -rf "$SD" "$GATE_LOG" "$POST_LOG" "$RERUN_LOG" "$T/locks" "$HOME/.claude/handoff/drain.stop" "$T"/status-*.json "$T"/runs-*.json "$T/fixes-list.txt" "$T"/rs-*; : > "$GATE_LOG"; mkdir -p "$SD"; GATE_RC=0; unset GH_FAIL MAIN_FAIL REFUSE_RERUN; AHEAD=0; export AHEAD
  main_runs "[$(mr 900 m000000aa completed success)]"; }
on() { touch "$SD/r.enabled"; }
# money fixtures (Ruling MONEY-SHA-1): the controller's commit status on a head sha. money_ok SHA [state] [created_at]
money_ok() { echo "[{\"context\":\"controller/money-review\",\"state\":\"${2:-success}\",\"created_at\":\"${3:-2026-11-16T10:00:00Z}\"}]" > "$T/status-$1.json"; }
calls() { wc -l < "$GATE_LOG" | tr -d ' '; }

reset; prs "$(pr 1 aaaaaaa1 green)"
run >/dev/null; [ "$(calls)" = 0 ] && ok "off until the enabled marker exists: no gate call" || no "ran while off"

reset; on; prs "$(pr 1 aaaaaaa1 green)"
run >/dev/null; [ "$(calls)" = 1 ] && grep -q "^1 aaaaaaa1 --repo $REPO_SLUG " "$GATE_LOG" && ok "green+mergeable PR goes through the gate, head pinned, --repo passed" || no "green PR not gated ($(cat "$GATE_LOG"))"

reset; on; prs "$(pr 1 a1 pending)" "$(pr 2 a2 red)" "$(pr 3 a3 none)" "$(pr 4 a4 green '' CONFLICTING)" "$(pr 5 a5 green '' MERGEABLE draft)"
run >/dev/null; [ "$(calls)" = 0 ] && ok "pending / red / zero-check / conflicting / draft PRs are never gated" || no "gated a non-green PR"

reset; on; prs "$(pr 1 a1 green risky-path)"
run --hold-risky >/dev/null; [ "$(calls)" = 0 ] && ok "risky PR without ai-review-passed is held" || no "risky PR gated unreviewed"
prs "$(pr 1 a1 green risky-path,ai-review-passed)"
run --hold-risky >/dev/null; [ "$(calls)" = 1 ] && ok "risky PR with ai-review-passed is gated" || no "reviewed risky PR not gated"
# money gate is UNCONDITIONAL: even without --hold-risky a risky PR lacking money-review-passed is never merged
reset; on; prs "$(pr 1 a1 green risky,ai-review-passed)"
run >/dev/null; [ "$(calls)" = 0 ] && ok "no --hold-risky: risky PR without money-review-passed is NOT merged" || no "money gate bypassed without --hold-risky"
prs "$(pr 1 a1 green risky,money-review-passed)"; money_ok a1
run >/dev/null; [ "$(calls)" = 1 ] && ok "no --hold-risky: risky PR with money-review-passed is merged" || no "risky with money-review-passed not merged"
# money gate (per label): `risky` needs money-review-passed, ai-review-passed alone is not enough
reset; on; prs "$(pr 1 a1 green risky,ai-review-passed)"
run --hold-risky >/dev/null; [ "$(calls)" = 0 ] && ok "risky + ai-review-passed WITHOUT money-review-passed is held (not merged)" || no "money gate open: risky merged without money-review-passed"
prs "$(pr 1 a1 green risky,risky-path,money-review-passed)"
run --hold-risky >/dev/null; [ "$(calls)" = 0 ] && ok "risky + risky-path + money-review-passed but NO ai-review-passed is held (gates AND)" || no "gate collapse: merged without ai-review-passed"
prs "$(pr 1 a1 green risky,ai-review-passed,money-review-passed)"; money_ok a1
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

# ---- MONEY-SHA-1: a risky PR merges only with controller/money-review = success on the EXACT head sha; every doubt refuses
reset; on; prs "$(pr 1 a1 green risky,money-review-passed)"
run >/dev/null; [ "$(calls)" = 0 ] && ok "risky + label but NO money-review status on the head: held" || no "merged without a status"
money_ok a1; run >/dev/null; [ "$(calls)" = 1 ] && ok "money-review success on the head sha: merged" || no "status success not merged"
reset; on; prs "$(pr 1 a2 green risky,money-review-passed)"; money_ok a1
run >/dev/null; [ "$(calls)" = 0 ] && ok "a status on an OLD head does not cover the new head (a PASS covers one head)" || no "old-head status merged a new head"
reset; on; prs "$(pr 1 a1 green risky,money-review-passed)"; echo '[{"context":"controller/money-review","state":"success","created_at":"2026-11-16T10:00:00Z"},{"context":"controller/money-review","state":"failure","created_at":"2026-11-16T11:00:00Z"}]' > "$T/status-a1.json"
run >/dev/null; [ "$(calls)" = 0 ] && ok "the NEWEST money-review status wins: a later failure revokes an earlier success" || no "revoked status merged"
reset; on; prs "$(pr 1 a1 green risky,money-review-passed)"; money_ok a1 pending
run >/dev/null; [ "$(calls)" = 0 ] && ok "a pending money-review status is not a pass" || no "pending merged"
reset; on; prs "$(pr 1 a1 green risky,money-review-passed)"; echo '[{"context":"ci/other","state":"success","created_at":"2026-11-16T10:00:00Z"}]' > "$T/status-a1.json"
run >/dev/null; [ "$(calls)" = 0 ] && ok "a success of ANOTHER context is not the money review" || no "other context merged"
reset; on; prs "$(pr 1 a1 green risky,money-review-passed)"; money_ok a1; STATUS_FAIL=1; export STATUS_FAIL
run >/dev/null; [ "$(calls)" = 0 ] && ok "statuses API error: refused (fails closed; it used to fail open)" || no "merged on a statuses API error"
unset STATUS_FAIL
reset; on; prs "$(pr 1 a1 green risky,money-review-passed)"; echo '{"message":"Server Error","documentation_url":"x"}' > "$T/status-a1.json"
run >/dev/null; [ "$(calls)" = 0 ] && ok "an error BODY (not a list) is refused" || no "error body merged"
reset; on; prs "$(pr 1 a1 green risky,money-review-passed)"; echo '[]' > "$T/status-a1.json"
run >/dev/null; [ "$(calls)" = 0 ] && ok "an empty statuses list is refused" || no "empty list merged"
reset; on; prs "$(pr 1 a1 green risky,money-review-passed)"; echo 'not json' > "$T/status-a1.json"
run >/dev/null; [ "$(calls)" = 0 ] && ok "an unparsable body is refused" || no "garbage merged"

# ---- G74 / main gate
reset; on; prs "$(pr 1 a1 green)"; main_runs "[$(mr 902 m2 completed failure),$(mr 901 m1 completed success)]"
run >/dev/null; [ "$(calls)" = 0 ] && ok "newest main run failed: nothing merges (G74)" || no "merged on a red main"
reset; on; prs "$(pr 1 a1 green)"; main_runs "[$(mr 902 m2 in_progress ''),$(mr 901 m1 completed success)]"
run >/dev/null; [ "$(calls)" = 0 ] && ok "a main run is in progress: nothing merges" || no "merged while main CI pending"
reset; on; prs "$(pr 1 a1 green)"; MAIN_FAIL=1; export MAIN_FAIL
run >/dev/null; [ "$(calls)" = 0 ] && ok "main CI unreadable: fail closed" || no "merged with main unreadable"
unset MAIN_FAIL
reset; on; prs "$(pr 1 a1 green)"; AHEAD=3; export AHEAD
run >/dev/null; [ "$(calls)" = 0 ] && ok "3 merges already on the last green main: batch full, waits" || no "batch cap ignored"
AHEAD=2; export AHEAD; prs "$(pr 1 a1 green)" "$(pr 2 a2 green)" "$(pr 3 a3 green)"
run >/dev/null; [ "$(calls)" = 1 ] && ok "batch room 1: exactly one PR merges this cycle" || no "batch cap exceeded ($(calls))"
reset; on; prs "$(pr 1 a1 green)"; main_runs "[$(mr 902 m2 completed cancelled 1),$(mr 901 m1 completed success)]"
run >/dev/null; [ "$(calls)" = 0 ] && grep -q "^run rerun 902 " "$RERUN_LOG" && ok "newest main commit's run cancelled: nothing merges and the run is re-run (every main commit gets a full run)" || no "cancelled main tip not handled ($(cat "$RERUN_LOG" 2>/dev/null))"
run >/dev/null; [ "$(wc -l < "$RERUN_LOG" | tr -d ' ')" = 1 ] && ok "the main re-run is requested once per run id and attempt" || no "main re-run repeated"
reset; on; prs "$(pr 1 a1 green fixes-main)" "$(pr 2 a2 green fixes-main)" "$(pr 3 a3 green)"; main_runs "[$(mr 902 m2 completed failure)]"
run >/dev/null; [ "$(calls)" = 1 ] && grep -q "^1 a1 " "$GATE_LOG" && ok "red main: only a fixes-main PR merges, one per cycle" || no "fixes-main handling wrong ($(cat "$GATE_LOG"))"
reset; on; prs "$(pr 1 a1 green fixes-main)"; main_runs "[$(mr 902 m2 in_progress '')]"
run >/dev/null; [ "$(calls)" = 0 ] && ok "pending main: even a fixes-main PR waits" || no "fixes-main merged while main pending"
reset; on; prs "$(pr 1 a1 green)"; main_runs "[$(mr 902 m2 completed failure)]"
run --main-workflow none >/dev/null; [ "$(calls)" = 1 ] && ok "--main-workflow none switches the main checks off" || no "main checks not switchable"

# ---- G47 / DRAIN-HEAL-6/7: heal cancelled runs of otherwise-eligible PRs
cpr() { python3 -I - "$@" <<'PY'
import json, sys
n, sha = int(sys.argv[1]), sys.argv[2]
print(json.dumps({"number": n, "headRefOid": sha, "mergeable": "MERGEABLE", "isDraft": False, "labels": [],
 "statusCheckRollup": [{"name": "CI", "status": "COMPLETED", "conclusion": "SUCCESS"}, {"name": sys.argv[3], "status": "COMPLETED", "conclusion": sys.argv[4]}]}))
PY
}
wr() { echo "[$2]" > "$T/runs-$1.json"; }   # runs on a head
rr() { printf '{"databaseId":%s,"workflowName":"%s","status":"completed","conclusion":"%s","attempt":%s}' "$1" "$2" "$3" "${4:-1}"; }
reset; on; prs "$(cpr 7 h7 'Deploy change label' CANCELLED)"; wr h7 "$(rr 71 CI success),$(rr 72 'Deploy change label' cancelled)"
run >/dev/null; [ "$(calls)" = 0 ] && grep -q "^run rerun 72 .*--failed" "$RERUN_LOG" && ok "a cancelled non-CI workflow ('Deploy change label') is re-run, not only CI (G47)" || no "cancelled label workflow not healed ($(cat "$RERUN_LOG" 2>/dev/null))"
run >/dev/null; [ "$(wc -l < "$RERUN_LOG" | tr -d ' ')" = 1 ] && ok "a run id+attempt is healed once" || no "healed twice"
reset; on; prs "$(cpr 7 h7 'Deploy change label' FAILURE)"; wr h7 "$(rr 72 'Deploy change label' failure)"
run >/dev/null; [ ! -s "$RERUN_LOG" ] && ok "a real failure is never re-run" || no "re-ran a real failure"
reset; on; prs "$(cpr 7 h7 CI CANCELLED)"; wr h7 "$(rr 72 CI cancelled)"; main_runs "[$(mr 902 m2 in_progress ''),$(mr 901 m1 completed success)]"
run >/dev/null; [ ! -s "$RERUN_LOG" ] && ok "no heal while a main run is queued/in progress (DRAIN-HEAL-7)" || no "healed while main pending"
reset; on; prs "$(cpr 7 h7 CI CANCELLED)"; wr h7 "$(rr 72 CI cancelled)"; main_runs "[$(mr 902 m2 completed failure)]"
run >/dev/null; [ ! -s "$RERUN_LOG" ] && ok "no heal while main is red (DRAIN-HEAL-6)" || no "healed while main red"
reset; on; prs "$(cpr 7 h7 CI CANCELLED)"; wr h7 "$(rr 72 CI cancelled)"; AHEAD=3; export AHEAD
run >/dev/null; [ ! -s "$RERUN_LOG" ] && ok "no heal while the 3-merge batch is full (DRAIN-HEAL-6)" || no "healed with a full batch"
reset; on; prs "$(cpr 7 h7 CI CANCELLED)"; wr h7 "$(rr 72 CI cancelled 20)"
run >/dev/null; [ ! -s "$RERUN_LOG" ] && ok "heal stops at attempt 20" || no "healed past the cap"
reset; on; prs "$(cpr 7 h7 CI CANCELLED)" "$(cpr 8 h8 CI CANCELLED)"; wr h7 "$(rr 72 CI cancelled)"; wr h8 "$(rr 82 CI cancelled)"; AHEAD=2; export AHEAD
run >/dev/null; [ "$(wc -l < "$RERUN_LOG" | tr -d ' ')" = 1 ] && grep -q "^run rerun 72 " "$RERUN_LOG" && ok "heal is bounded by the batch room, oldest PR first (DRAIN-HEAL-4)" || no "heal not bounded ($(cat "$RERUN_LOG"))"

# ---- DRAIN-STARVE-1: a run queued >20 min on a fixes-main PR head is cancelled and re-queued, once
qr() { printf '{"databaseId":%s,"status":"queued","createdAt":"%s","attempt":%s}' "$1" "$2" "${3:-1}"; }
reset; on; prs; echo "5 hs5" > "$T/fixes-list.txt"; wr hs5 "$(qr 55 2026-11-17T05:14:00Z)"; main_runs "[$(mr 902 m2 completed failure)]"
run >/dev/null; grep -q "^run cancel 55 " "$RERUN_LOG" && grep -q "^run rerun 55 " "$RERUN_LOG" && ok "fixes-main run queued >20 min: cancelled then re-run (DRAIN-STARVE-1), even with main red" || no "starved run not requeued ($(cat "$RERUN_LOG" 2>/dev/null))"
run >/dev/null; [ "$(grep -c '^run cancel 55 ' "$RERUN_LOG")" = 1 ] && ok "a starved run id+attempt is requeued once" || no "requeued repeatedly"
reset; on; prs; echo "5 hs5" > "$T/fixes-list.txt"; wr hs5 "$(qr 55 "$(date -u +%Y-%m-%dT%H:%M:%SZ)")"
run >/dev/null; [ ! -s "$RERUN_LOG" ] && ok "a freshly queued fixes-main run is left alone" || no "requeued a fresh run"
reset; on; prs; : > "$T/fixes-list.txt"; wr hs5 "$(qr 55 2026-11-17T05:14:00Z)"
run >/dev/null; [ ! -s "$RERUN_LOG" ] && ok "queued runs on non-fixes-main heads (ghost runs) are never touched" || no "touched a non-fixes-main run"

# ---- re-run is VERIFIED (2026-11-17: #811's CI and a main run stayed cancelled because the re-run silently did not take)
reset; on; prs "$(cpr 7 h7 CI CANCELLED)"; wr h7 "$(rr 72 CI cancelled)"; REFUSE_RERUN="72"; export REFUSE_RERUN
run >/dev/null; [ "$(grep -c '^run rerun 72 ' "$RERUN_LOG")" = 3 ] && [ ! -f "$SD/r.healed-72-a1" ] && ok "a re-run that does not take is retried (3 tries) and the run is NOT marked healed (G47)" || no "unverified rerun marked or not retried ($(grep -c '^run rerun 72 ' "$RERUN_LOG"))"
run >/dev/null; run >/dev/null
grep -qx 72 "$SD/r.rerun-failed" && ok "after 3 cycles the failure is reported once (RERUN-FAILED) and left to a human" || no "no RERUN-FAILED record"
n=$(grep -c '^run rerun 72 ' "$RERUN_LOG"); run >/dev/null; [ "$(grep -c '^run rerun 72 ' "$RERUN_LOG")" = "$n" ] && ok "a run given up on is not retried forever" || no "kept retrying a given-up run"
reset; on; prs "$(cpr 7 h7 CI CANCELLED)"; wr h7 "$(rr 72 CI cancelled)"; unset REFUSE_RERUN
run >/dev/null; [ -f "$SD/r.healed-72-a1" ] && ok "a confirmed re-run is marked healed" || no "confirmed re-run not marked"
reset; on; prs; echo "5 hs5" > "$T/fixes-list.txt"; wr hs5 "$(qr 55 2026-11-17T05:14:00Z)"; REFUSE_RERUN="55"; export REFUSE_RERUN
run >/dev/null; run >/dev/null
[ ! -f "$SD/r.starved-55-a1" ] && [ "$(grep -c '^run rerun 55 ' "$RERUN_LOG")" = 6 ] && [ "$(grep -c '^run cancel 55 ' "$RERUN_LOG")" = 1 ] && ok "starve: cancelled once, then the re-run is retried on later cycles until it takes (never left cancelled)" || no "starve left a run cancelled ($(grep -c '^run cancel 55 ' "$RERUN_LOG") cancels, $(grep -c '^run rerun 55 ' "$RERUN_LOG") reruns)"
unset REFUSE_RERUN
if command -v jq >/dev/null 2>&1; then
  out="$(printf '%s' '[{"number":1,"headRefOid":"aa","labels":[{"name":"fixes-main"},{"name":"hold"}]},{"number":2,"headRefOid":"bb","labels":[{"name":"fixes-main"}]}]' | jq -r '.[]|select(all(.labels[]; .name != "hold"))|"\(.number) \(.headRefOid)"')"
  grep -qF 'select(all(.labels[]; .name != "hold"))' "$DRAIN" && [ "$out" = "2 bb" ] && ok "starve never touches a PR labelled hold (the filter the drain passes to gh keeps only #2)" || no "hold filter wrong ($out)"
fi

# ---- review fixes (2026-11-17)
# main is re-read before EVERY gate call: it turns red after the first merge of a batch, the second and third must not merge
reset; on; prs "$(pr 1 a1 green)" "$(pr 2 a2 green)" "$(pr 3 a3 green)"; AHEAD=0; export AHEAD
GATE_FLIP_MAIN="[$(mr 902 m2 completed failure)]"; export GATE_FLIP_MAIN
run >/dev/null; [ "$(calls)" = 1 ] && ok "main turns red after the first merge of a batch: the second and third are NOT gated (main re-read before each gate)" || no "gated on after main went red ($(calls) gates)"
unset GATE_FLIP_MAIN
reset; on; prs "$(pr 1 a1 green)" "$(pr 2 a2 green)"; GATE_FLIP_MAIN="[$(mr 902 m2 in_progress ''),$(mr 900 m000000aa completed success)]"; export GATE_FLIP_MAIN
run >/dev/null; [ "$(calls)" = 1 ] && ok "main goes pending mid-cycle: the next PR waits" || no "gated while main pending ($(calls))"
unset GATE_FLIP_MAIN
# a wrong --main-workflow name (no run of that name = unknown) merges nothing, and says so after 3 cycles in a row
reset; on; prs "$(pr 1 a1 green)"; echo '[]' > "$MAIN_RUNS"
o1="$(run)"; o2="$(run)"; [ "$(calls)" = 0 ] && ! printf '%s\n%s\n' "$o1" "$o2" | grep -q "ALERT" && ok "two unreadable cycles: nothing merges, no alert yet" || no "alert too early or merged"
o3="$(run)"; [ "$(calls)" = 0 ] && printf '%s' "$o3" | grep -q "ALERT: no main CI run could be read for 3 cycles" && ok "third unreadable cycle in a row: loud ALERT naming --main-workflow" || no "no ALERT after 3 unreadable cycles"
grep -q '"cycleRc":3' "$SD/r.heartbeat" && ok "the heartbeat records the unreadable cycle (rc 3)" || no "heartbeat missing"
# starve: keyed by RUN ID with a hard cap and spacing (createdAt does not move on a re-run; the old attempt-keyed marker never matched, endless loop)
reset; on; prs; echo "5 hs5" > "$T/fixes-list.txt"; wr hs5 "$(qr 55 2026-11-17T05:14:00Z)"
for i in 1 2 3 4; do run >/dev/null; done
[ "$(grep -c '^run cancel 55 ' "$RERUN_LOG")" = 1 ] && ok "starve: a re-queued run still looks old (createdAt unchanged) but is NOT cancelled again within --starve-min" || no "starve loop: $(grep -c '^run cancel 55 ' "$RERUN_LOG") cancels in 4 cycles"
reset; on; prs; echo "5 hs5" > "$T/fixes-list.txt"; wr hs5 "$(qr 55 2026-11-17T05:14:00Z)"
for i in 1 2 3 4 5; do run --starve-min 0 >/dev/null; done
[ "$(grep -c '^run cancel 55 ' "$RERUN_LOG")" = 2 ] && ok "starve: a hard cap of 2 requeues per run id even with no spacing" || no "starve cap: $(grep -c '^run cancel 55 ' "$RERUN_LOG") cancels"
# rerun_verified: a failed FIRST read of the attempt never confirms (any later read used to look like progress)
reset; on; prs "$(cpr 7 h7 CI CANCELLED)"; wr h7 "$(rr 72 CI cancelled)"; echo "completed 1" > "$T/rs-72"; REFUSE_RERUN="72"; export REFUSE_RERUN; RUNVIEW_FAIL_ATTEMPT=1; export RUNVIEW_FAIL_ATTEMPT
run >/dev/null; [ ! -f "$SD/r.healed-72-a1" ] && ok "an unreadable attempt number is a failed try, never a confirmation" || no "confirmed on a failed first read"
unset RUNVIEW_FAIL_ATTEMPT REFUSE_RERUN

reset; on; run --bogus >/dev/null 2>&1; [ $? = 2 ] && ok "unknown flag exits 2" || no "unknown flag accepted"
echo "drain: $p passed, $f failed"; [ "$f" = 0 ]
