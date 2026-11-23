#!/usr/bin/env bash
# loop-watchdog.sh (LOOP-WATCH-1): exits 0 (wakes the controller) on red main CI, a dead drain, a dead alert listener, or no merge
# for 40 min with approved PRs waiting; exits 1 when healthy; an ack silences a known issue until the loop is healthy again.
# gh, launchctl and pgrep are faked via PATH; nothing touches the network or the real launchd.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1; OPS="$(pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
_pass=0; _fail=0
pass() { echo "PASS: $1"; _pass=$((_pass+1)); }
fail() { echo "FAIL: $1"; _fail=$((_fail+1)); }
mkdir -p "$T/bin"
iso_ago() { python3 -I -c 'import sys,time; print(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time()-int(sys.argv[1])*60)))' "$1"; }
cat > "$T/bin/gh" <<SH
#!/usr/bin/env bash
case "\$*" in
  *"run list"*) cat "$T/ci" ;;
  *"--state merged"*) python3 -I -c 'import sys,json; print(json.dumps([{"mergedAt":l.strip()} for l in open(sys.argv[1]) if l.strip()]))' "$T/merged" ;;
  *"pr list"*) cat "$T/ready" ;;
esac
SH
cat > "$T/bin/launchctl" <<SH
#!/usr/bin/env bash
cat "$T/launchd"
SH
cat > "$T/bin/pgrep" <<SH
#!/usr/bin/env bash
grep -q -- "\${2:-}" "$T/procs" 2>/dev/null
SH
chmod +x "$T/bin/"*
# prs <n-eligible> [extra-json-objects]: gh pr list JSON with n drain-eligible PRs (approved, green, mergeable) plus any extras
mkpr() { # number mergeable draft labels(comma) checkstate(SUCCESS|FAILURE|PENDING|NONE)
  python3 -I -c '
import json,sys
n,m,d,l,c=sys.argv[1:6]
chk={"SUCCESS":[{"status":"COMPLETED","conclusion":"SUCCESS"}],"FAILURE":[{"status":"COMPLETED","conclusion":"FAILURE"}],"PENDING":[{"status":"IN_PROGRESS","conclusion":""}],"NONE":[]}[c]
print(json.dumps({"number":int(n),"mergeable":m,"isDraft":d=="1","labels":[{"name":x} for x in l.split(",") if x],"statusCheckRollup":chk,"headRefOid":"a"*40}))' "$@"; }
prs() { local n="$1" i out=""; shift; for i in $(seq 1 "$n"); do out="$out$(mkpr "$i" MERGEABLE 0 ai-review-passed SUCCESS),"; done; for x in "$@"; do out="$out$x,"; done; printf '[%s]' "${out%,}"; }
healthy() { echo 'completed/success/abc1234' > "$T/ci"; iso_ago 5 > "$T/merged"; prs 3 > "$T/ready"
  printf -- '-\t0\tcom.ebda.os.drain-ebda-store\n' > "$T/launchd"; echo 'alert-wait.sh' > "$T/procs"; rm -f "$T/ack"; }
run() { env ALERT_WAIT_GRACE="${GRACE:-0}" PATH="$T/bin:$PATH" OS_LOOP_REPOS="o/r" OS_STATE_DIR="$T" OS_PROJECTS_DIR="$T/proj" EBDA_OS_LOCAL_ENV="$T/none" bash "$OPS/loop-watchdog.sh" --once --ack-file "$T/ack" >"$T/out" 2>"$T/err"; }

healthy; run; rc=$?
[ "$rc" = 1 ] && [ ! -s "$T/out" ] && pass "healthy loop: exit 1, silent (must not fire)" || { fail "healthy rc=$rc"; cat "$T/out" "$T/err"; }

healthy; echo 'completed/failure/deadbee' > "$T/ci"; run; rc=$?
{ [ "$rc" = 0 ] && grep -q 'main CI red: o/r completed/failure/deadbee' "$T/out" && grep -q 'ack with' "$T/out"; } && pass "red main CI wakes (must fire)" || { fail "red CI rc=$rc"; cat "$T/out"; }

healthy; : > "$T/launchd"; run; rc=$?
{ [ "$rc" = 0 ] && grep -q 'drain not running' "$T/out"; } && pass "no drain launchd job and no process wakes" || { fail "dead drain rc=$rc"; cat "$T/out"; }
healthy; : > "$T/launchd"; echo 'alert-wait.sh ops/drain.sh' > "$T/procs"; run; rc=$?
[ "$rc" = 1 ] && pass "a drain script process counts as a live drain" || fail "drain process rc=$rc"
healthy; printf -- '-\t0\tcom.apple.something\n' > "$T/launchd"; run; rc=$?
[ "$rc" = 0 ] && pass "an unrelated launchd job is not a drain" || fail "unrelated launchd rc=$rc"

healthy; : > "$T/procs"; run; rc=$?
{ [ "$rc" = 0 ] && grep -q 'alert-wait not running' "$T/out"; } && pass "dead alert listener wakes" || { fail "dead alert-wait rc=$rc"; cat "$T/out"; }

healthy; iso_ago 55 > "$T/merged"; run; rc=$?
{ [ "$rc" = 0 ] && grep -q 'no merge for 5[0-9] min: o/r with 3 drain-eligible' "$T/out"; } && pass "55 min without a merge and 3 approved PRs wakes" || { fail "stall rc=$rc"; cat "$T/out"; }
healthy; iso_ago 55 > "$T/merged"; echo '[]' > "$T/ready"; run; rc=$?
[ "$rc" = 1 ] && pass "no merge but nothing approved is not a stall (must not fire)" || fail "idle rc=$rc"
# G15: only drain-ELIGIBLE PRs count. 64 approved PRs of which 2 can merge says 2; 64 approved and none mergeable is NOT a stall.
healthy; iso_ago 55 > "$T/merged"
inel=(); for i in $(seq 100 117); do inel+=("$(mkpr $i MERGEABLE 0 ai-review-passed FAILURE)"); done          # red checks
pend=(); for i in $(seq 120 137); do pend+=("$(mkpr $i MERGEABLE 0 ai-review-passed PENDING)"); done        # pending checks: still working, not a stall (G15 ruling), NOT counted
for i in $(seq 140 150); do inel+=("$(mkpr $i CONFLICTING 0 ai-review-passed SUCCESS)"); done                # conflicts
for i in $(seq 160 165); do inel+=("$(mkpr $i MERGEABLE 0 ai-review-passed,hold SUCCESS)"); done             # hold label
for i in $(seq 170 175); do inel+=("$(mkpr $i MERGEABLE 1 ai-review-passed SUCCESS)"); done                  # drafts
for i in $(seq 180 184); do inel+=("$(mkpr $i MERGEABLE 0 risky-path SUCCESS)"); done                        # risky, not reviewed
prs 2 ${inel[@]+"${inel[@]}"} ${pend[@]+"${pend[@]}"} > "$T/ready"; run; rc=$?
{ [ "$rc" = 0 ] && grep -q 'with 2 drain-eligible' "$T/out" && ! grep -q 'approved PRs' "$T/out"; } && pass "stall counts only drain-eligible PRs (2 of 84 approved-labelled: red/conflict/hold/draft/unreviewed-risky excluded)" || { fail "eligible count rc=$rc"; cat "$T/out"; }
printf '[%s]' "$(IFS=,; echo "${inel[*]}" "${pend[*]}" | tr ' ' ',')" > "$T/ready"; run; rc=$?
[ "$rc" = 1 ] && pass "many approved PRs but none drain-eligible is not a stall (must not fire)" || { fail "ineligible-only rc=$rc"; cat "$T/out"; }
# eligible() itself (stall mode additionally requires ai-review-passed, which would mask a collapsed gate): reviews must AND
python3 -I -c '
import sys; sys.path.insert(0, sys.argv[1]); import drain_eligible as d
mk=lambda ls: {"isDraft":False,"mergeable":"MERGEABLE","statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"}],"labels":[{"name":l} for l in ls]}
assert not d.eligible(mk(["risky","risky-path","money-review-passed"]), require_passed=False)
assert not d.eligible(mk(["risky","risky-path","ai-review-passed"]), require_passed=False)
assert d.eligible(mk(["risky","risky-path","ai-review-passed","money-review-passed"]), require_passed=False)
assert not d.eligible(mk(["risky","ai-review-passed"]), hold_risky=False, require_passed=False)   # money gate ignores hold_risky' "$OPS/lib" && pass "eligible(): risky + risky-path need BOTH reviews (no masking by require_passed)" || fail "eligible() gate collapse"
# money gate (per label): risky needs money-review-passed; risky-path needs ai-review-passed
healthy; iso_ago 55 > "$T/merged"
echo "[$(mkpr 1 MERGEABLE 0 risky,ai-review-passed SUCCESS)]" > "$T/ready"; run; rc=$?
[ "$rc" = 1 ] && pass "risky + ai-review-passed WITHOUT money-review-passed: not eligible" || { fail "money gate open rc=$rc"; cat "$T/out"; }
echo "[$(mkpr 1 MERGEABLE 0 risky,risky-path,money-review-passed SUCCESS)]" > "$T/ready"; run; rc=$?
[ "$rc" = 1 ] && pass "risky + risky-path + money-review-passed but NO ai-review-passed: not eligible (gates AND)" || { fail "gate collapse rc=$rc"; cat "$T/out"; }
echo "[$(mkpr 1 MERGEABLE 0 risky,ai-review-passed,money-review-passed SUCCESS)]" > "$T/ready"; run; rc=$?
{ [ "$rc" = 0 ] && grep -q 'with 1 drain-eligible' "$T/out"; } && pass "risky + both reviews: eligible" || { fail "risky+both rc=$rc"; cat "$T/out"; }
echo "[$(mkpr 1 MERGEABLE 0 risky-path,ai-review-passed SUCCESS)]" > "$T/ready"; run; rc=$?
{ [ "$rc" = 0 ] && grep -q 'with 1 drain-eligible' "$T/out"; } && pass "risky-path + ai-review-passed: eligible" || { fail "risky-path rc=$rc"; cat "$T/out"; }
healthy; iso_ago 20 > "$T/merged"; run; rc=$?
[ "$rc" = 1 ] && pass "a merge 20 min ago is not a stall" || fail "recent merge rc=$rc"

healthy; echo 'completed/failure/deadbee' > "$T/ci"; run; sig="$(sed -n 's/.*echo "\(.*\)" > .*/\1/p' "$T/out")"
printf '%s\n' "$sig" > "$T/ack"; run; rc=$?
[ "$rc" = 1 ] && pass "acked issue does not wake again" || fail "acked rc=$rc"
echo 'completed/failure/cafe123' > "$T/ci"; run; rc=$?
[ "$rc" = 1 ] && pass "same kind with a new sha stays acked (kinds only)" || fail "ack by kind rc=$rc"
: > "$T/procs"; run; rc=$?
[ "$rc" = 0 ] && grep -q 'alert-wait not running' "$T/out" && pass "a NEW kind wakes despite the ack" || fail "new kind rc=$rc"
healthy; echo "x" > "$T/ack"; run; [ ! -f "$T/ack" ] && pass "healthy loop clears the ack" || fail "ack not cleared"

mkdir -p "$T/proj/Biz/internal-projects/repo" "$T/proj/Biz/internal-projects/clean"
for d in repo clean; do git -C "$T/proj/Biz/internal-projects/$d" init -q; done
git -C "$T/proj/Biz/internal-projects/repo" worktree list >/dev/null 2>&1
healthy; run; rc=$?
[ "$rc" = 1 ] && pass "root checkouts with core.bare unset are clean (must not fire)" || fail "clean roots rc=$rc"
git -C "$T/proj/Biz/internal-projects/repo" config core.bare true
healthy; run; rc=$?
if [ "$rc" = 0 ] && grep -q 'root checkout bare: .*internal-projects/repo (fix: git -C' "$T/out" && ! grep -q 'internal-projects/clean' "$T/out"; then pass "a root checkout with core.bare=true wakes, naming only it (must fire)"; else fail "bare root rc=$rc"; cat "$T/out"; fi
git -C "$T/proj/Biz/internal-projects/repo" config core.bare false
healthy; run; rc=$?
[ "$rc" = 1 ] && pass "fixed (core.bare false): silent again" || fail "fixed root rc=$rc"
# a linked worktree (.git is a file) is never treated as a root
git -C "$T/proj/Biz/internal-projects/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m i
git -C "$T/proj/Biz/internal-projects/repo" worktree add -q "$T/proj/Biz/internal-projects/wt" -b wtb 2>/dev/null
healthy; run; rc=$?
[ "$rc" = 1 ] && pass "a linked worktree is not a root checkout" || fail "worktree rc=$rc"

# G40b: gh orders merged PRs by CREATION time, so the FIRST listed merged PR can have an old mergedAt while a later-listed one merged
# minutes ago. The last merge is the MAX mergedAt, not the first row (store: "no merge for 272 min" right after #805 merged).
healthy; { iso_ago 272; iso_ago 3; iso_ago 90; } > "$T/merged"; prs 3 > "$T/ready"; run; rc=$?
[ "$rc" = 1 ] && pass "newest merge is the max mergedAt, not the first listed (3 min ago: no stall)" || { fail "last-merge uses first row rc=$rc"; cat "$T/out"; }
healthy; { iso_ago 272; iso_ago 150; } > "$T/merged"; run; rc=$?
{ [ "$rc" = 0 ] && grep -q 'no merge for 15[0-9] min' "$T/out"; } && pass "a real stall still reports the max age (150 min)" || { fail "real stall lost rc=$rc"; cat "$T/out"; }

# G39: alert-wait restarts for 1-3 s after each alert; a gap shorter than the grace window must not wake, a real absence must
healthy; : > "$T/procs"; ( sleep 1; echo 'alert-wait.sh' > "$T/procs" ) & GRACE=3 run; rc=$?; wait
[ "$rc" = 1 ] && pass "alert-wait back within the grace window: silent (no false wake)" || { fail "restart race woke rc=$rc"; cat "$T/out"; }
healthy; : > "$T/procs"; GRACE=1 run; rc=$?
{ [ "$rc" = 0 ] && grep -q 'alert-wait not running' "$T/out"; } && pass "alert-wait gone past the grace window wakes" || { fail "dead alert-wait not reported rc=$rc"; cat "$T/out"; }

# G40a: ack by reason SUBSET: acking {main CI, alert-wait}; when alert-wait recovers (cleared reason) the ack still silences main CI
healthy; echo 'completed/failure/deadbee' > "$T/ci"; : > "$T/procs"; run
printf '%s\n' "alert-wait not|main CI|" > "$T/ack"; run; rc=$?
[ "$rc" = 1 ] && pass "ack silences when every current kind is acked" || fail "ack not honoured rc=$rc"
echo 'alert-wait.sh' > "$T/procs"; run; rc=$?
[ "$rc" = 1 ] && pass "a CLEARED reason (alert-wait back) does not re-wake an acked main CI (subset)" || { fail "cleared reason re-woke rc=$rc"; cat "$T/out"; }
printf '%s\n' "main CI|" > "$T/ack"; : > "$T/procs"; run; rc=$?
[ "$rc" = 0 ] && grep -q 'alert-wait not running' "$T/out" && pass "a kind NOT in the ack still wakes" || fail "unacked kind silenced rc=$rc"

echo "loop-watchdog: $_pass passed, $_fail failed"
[ "$_fail" = 0 ]
