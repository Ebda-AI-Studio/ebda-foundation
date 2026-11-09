#!/usr/bin/env bash
# guest_rebuild_decide — the rate limit + cooldown in front of the ONE
# destructive remedy the CI runner guard has (`umbra rebuild`, ~9 min, and it
# destroys every cache in the guest).
#
# WHY A PURE FUNCTION: the guard ticks every 30 minutes, so a verdict that
# persists is 48 rebuild opportunities a day. The arithmetic that turns "the
# disk is corrupt" into "and you may destroy it again" is the whole guardrail,
# so it is separated from the probing and unit-tested with synthesised clocks —
# no VM, no umbra, no wall clock.
set -euo pipefail
. "$(dirname "$0")/../guest-rebuild.sh"
_pass=0; _fail=0
eq() { if [ "$2" = "$3" ]; then echo "PASS: $1"; _pass=$((_pass+1)); else echo "FAIL: $1 — got '$2' want '$3'"; _fail=$((_fail+1)); fi; }

NOW=1000000
MAX=2; WIN=86400; GAP=10800

# ── the decision ─────────────────────────────────────────────────────────────
eq "no history at all → allow" \
   "$(guest_rebuild_decide $NOW $MAX $WIN $GAP)" "allow"
eq "one rebuild older than the window → allow" \
   "$(guest_rebuild_decide $NOW $MAX $WIN $GAP $((NOW-90000)))" "allow"

# Cooldown: a rebuilt guest must prove itself under CI load before it is
# eligible to be destroyed again. On 2026-09-15 a freshly rebuilt, clean-disk
# guest wedged again ~37 min later; rebuilding on that cadence loops against a
# cause that is not the disk.
eq "a rebuild 10 min ago → cooldown with the remaining seconds" \
   "$(guest_rebuild_decide $NOW $MAX $WIN $GAP $((NOW-600)))" "cooldown:$((GAP-600))"
eq "exactly at the gap boundary → allow (not still cooling)" \
   "$(guest_rebuild_decide $NOW $MAX $WIN $GAP $((NOW-GAP)))" "allow"
eq "one second short of the gap → still cooling" \
   "$(guest_rebuild_decide $NOW $MAX $WIN $GAP $((NOW-GAP+1)))" "cooldown:1"

# Rate limit: the measured worst case is 2 corruptions in 2 days. A third
# inside 24h means rebuilding is not fixing the cause — that needs Ahmad.
eq "two rebuilds inside the window → limit" \
   "$(guest_rebuild_decide $NOW $MAX $WIN $GAP $((NOW-20000)) $((NOW-40000)))" "limit:2"
eq "limit OUTRANKS cooldown (a human is needed, say so)" \
   "$(guest_rebuild_decide $NOW $MAX $WIN $GAP $((NOW-600)) $((NOW-40000)))" "limit:2"
eq "entries roll out of the window" \
   "$(guest_rebuild_decide $NOW $MAX $WIN $GAP $((NOW-90000)) $((NOW-95000)))" "allow"
eq "exactly at the window edge is already out" \
   "$(guest_rebuild_decide $NOW $MAX $WIN $GAP $((NOW-WIN)) $((NOW-WIN-1)))" "allow"

# The 2026-09-16 scenario itself: two corruptions two days apart are BOTH
# inside budget — the guardrail must not block the case it was built for.
eq "the measured fault cadence (2 days apart) is allowed" \
   "$(guest_rebuild_decide $NOW $MAX $WIN $GAP $((NOW-172800)))" "allow"

# A corrupt/garbage history must never be counted as permission NOR as a
# phantom rebuild. Non-numeric entries are ignored.
eq "garbage epochs are ignored, not counted" \
   "$(guest_rebuild_decide $NOW $MAX $WIN $GAP 'x' '')" "allow"
eq "garbage does not mask a real limit" \
   "$(guest_rebuild_decide $NOW $MAX $WIN $GAP 'x' $((NOW-20000)) $((NOW-30000)))" "limit:2"

# max=0 disables auto-rebuild outright (the kill switch).
eq "max 0 refuses every rebuild" \
   "$(guest_rebuild_decide $NOW 0 $WIN $GAP)" "limit:0"

# ── the persisted history ────────────────────────────────────────────────────
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
GUEST_REBUILD_STATE="$T/hist.json"

eq "no state file → empty history" "$(guest_rebuild_history umbra-ci6)" ""

guest_rebuild_record umbra-ci6 1000
eq "first rebuild is recorded"  "$(guest_rebuild_history umbra-ci6)" "1000"
guest_rebuild_record umbra-ci6 2000
eq "history accumulates, ascending" "$(guest_rebuild_history umbra-ci6)" "1000 2000"
eq "a different machine keeps its own history" "$(guest_rebuild_history other-guest)" ""

guest_rebuild_record other-guest 5000
eq "the second machine records independently" "$(guest_rebuild_history other-guest)" "5000"
eq "…without disturbing the first"            "$(guest_rebuild_history umbra-ci6)" "1000 2000"

# Pruning is relative to the epoch being recorded, so the file cannot grow
# without bound, and an ancient entry cannot keep the limit tripped forever.
guest_rebuild_record umbra-ci6 $((2000 + WIN + 1))
eq "recording prunes entries that fell out of the window" \
   "$(guest_rebuild_history umbra-ci6)" "$((2000 + WIN + 1))"

# A corrupt state file must not crash the guard, and must not read as
# permission either — history is empty, and the caller's own default (max>=1)
# then applies to an empty history.
echo 'not json{' > "$GUEST_REBUILD_STATE"
eq "a corrupt state file reads as empty history, not a crash" \
   "$(guest_rebuild_history umbra-ci6)" ""

echo "guest-rebuild: $_pass passed, $_fail failed"
[ "$_fail" -eq 0 ]
