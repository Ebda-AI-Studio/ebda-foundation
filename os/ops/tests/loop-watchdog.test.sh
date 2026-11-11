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
  *"--state merged"*) cat "$T/merged" ;;
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
healthy() { echo 'completed/success/abc1234' > "$T/ci"; iso_ago 5 > "$T/merged"; echo 3 > "$T/ready"
  printf -- '-\t0\tcom.ebda.os.drain-ebda-store\n' > "$T/launchd"; echo 'alert-wait.sh' > "$T/procs"; rm -f "$T/ack"; }
run() { env PATH="$T/bin:$PATH" OS_LOOP_REPOS="o/r" OS_STATE_DIR="$T" OS_PROJECTS_DIR="$T/proj" EBDA_OS_LOCAL_ENV="$T/none" bash "$OPS/loop-watchdog.sh" --once --ack-file "$T/ack" >"$T/out" 2>"$T/err"; }

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
{ [ "$rc" = 0 ] && grep -q 'no merge for 5[0-9] min: o/r with 3 approved' "$T/out"; } && pass "55 min without a merge and 3 approved PRs wakes" || { fail "stall rc=$rc"; cat "$T/out"; }
healthy; iso_ago 55 > "$T/merged"; echo 0 > "$T/ready"; run; rc=$?
[ "$rc" = 1 ] && pass "no merge but nothing approved is not a stall (must not fire)" || fail "idle rc=$rc"
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

echo "loop-watchdog: $_pass passed, $_fail failed"
[ "$_fail" = 0 ]
