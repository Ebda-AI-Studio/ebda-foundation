#!/usr/bin/env bash
# Test the merge gate: only a real SUCCESS makes a PR mergeable.
set -uo pipefail
. "$(dirname "$0")/../pr-merge-gate.sh"
_pass=0; _fail=0
eq() { if [ "$2" = "$3" ]; then echo "PASS: $1"; _pass=$((_pass+1)); else echo "FAIL: $1 — got '$2' want '$3'"; _fail=$((_fail+1)); fi; }
# v <conclusion> <status> ... as pairs
v() { local out=""; while [ "$#" -gt 0 ]; do out="$out$1|$2"$'\n'; shift 2; done; printf '%s' "$out" | merge_verdict; }

# ── check_state ──────────────────────────────────────────────────────────────
eq "SUCCESS passes"            "$(check_state SUCCESS COMPLETED)"        "pass"
eq "FAILURE blocks"            "$(check_state FAILURE COMPLETED)"        "block"
# THE BUG: cancelled is neither pending nor FAILURE, so it used to be invisible.
eq "CANCELLED blocks"          "$(check_state CANCELLED COMPLETED)"      "block"
eq "TIMED_OUT blocks"          "$(check_state TIMED_OUT COMPLETED)"      "block"
eq "STALE blocks"              "$(check_state STALE COMPLETED)"          "block"
eq "ACTION_REQUIRED blocks"    "$(check_state ACTION_REQUIRED COMPLETED)" "block"
eq "STARTUP_FAILURE blocks"    "$(check_state STARTUP_FAILURE COMPLETED)" "block"
# A conclusion GitHub has not invented yet must block, not merge.
eq "unknown conclusion blocks" "$(check_state SOME_NEW_STATE COMPLETED)" "block"
eq "SKIPPED is neutral"        "$(check_state SKIPPED COMPLETED)"        "neutral"
eq "NEUTRAL is neutral"        "$(check_state NEUTRAL COMPLETED)"        "neutral"
eq "running is pending"        "$(check_state '' IN_PROGRESS)"           "pending"
eq "queued is pending"         "$(check_state '' QUEUED)"                "pending"
# COMPLETED with no conclusion is a state we do not understand — block.
eq "completed+blank blocks"    "$(check_state '' COMPLETED)"             "block"
eq "lowercase is handled"      "$(check_state success completed)"        "pass"
eq "no args blocks"            "$(check_state)"                          "pending"

# ── merge_verdict ────────────────────────────────────────────────────────────
eq "all green merges" \
   "$(v SUCCESS COMPLETED SUCCESS COMPLETED SUCCESS COMPLETED)" "green"
eq "green + skipped merges" \
   "$(v SUCCESS COMPLETED SKIPPED COMPLETED)"                   "green"
eq "one failure blocks" \
   "$(v SUCCESS COMPLETED FAILURE COMPLETED)"                   "blocked"
eq "one still running is pending" \
   "$(v SUCCESS COMPLETED '' IN_PROGRESS)"                      "pending"
eq "pending outranks blocked" \
   "$(v FAILURE COMPLETED '' IN_PROGRESS)"                      "pending"

# ── THE REGRESSION: gcc-horse-market#99, merged on a cancelled CI run ────────
# Its real rollup: gitleaks passed, the CI run was cancelled.
eq "gcc#99 shape is BLOCKED, not mergeable" \
   "$(v SUCCESS COMPLETED CANCELLED COMPLETED)"                 "blocked"
# The old gate's arithmetic on that same input, for contrast:
#   pending = 0 (both COMPLETED), failed = 0 (neither is FAILURE) -> merged.

# ── "nothing failing" is not "something passed" ──────────────────────────────
eq "no checks at all is no-signal"    "$(printf '' | merge_verdict)"     "no-signal"
eq "only skipped is no-signal"        "$(v SKIPPED COMPLETED SKIPPED COMPLETED)" "no-signal"
eq "only neutral is no-signal"        "$(v NEUTRAL COMPLETED)"           "no-signal"
# An entire run cancelled — every check cancelled — must block, never merge.
eq "everything cancelled is blocked"  "$(v CANCELLED COMPLETED CANCELLED COMPLETED)" "blocked"

# A pending check's conclusion is EMPTY. With a TAB delimiter `read` collapses
# the leading empty field and the status lands in $conc — that is why the
# delimiter is "|". Assert the empty-leading-field case directly.
eq "empty conclusion parses as pending" "$(printf '|IN_PROGRESS\n' | merge_verdict)" "pending"
eq "empty conclusion among greens"      "$(v SUCCESS COMPLETED '' QUEUED)"           "pending"

echo; echo "$_pass passed, $_fail failed"; [ "$_fail" -eq 0 ]
