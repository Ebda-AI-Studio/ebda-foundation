#!/usr/bin/env bash
# ci-runner-guard.sh — the wall clock, a planned VM restart, and the runner count.
#
# Three bugs seen live on 2026-09-15, each reproduced here without a VM (fake `umbra`
# and `gh` on PATH, a throwaway HOME, the notifier stubbed so nothing pages):
#
#   1. A guard run hung 27+ min on `ssh … umbra@127.0.0.1 bash`. `umbra shell` execs
#      ssh, so a bare trailing `bash` can only come from the guard's stdin-fed
#      `… | umbra shell m -- bash` calls, which were never wrapped in _ut. _ut had two
#      holes of its own: a backgrounded "$@" & gets /dev/null as stdin (bash 3.2,
#      no job control), and a descendant still holding stdout kept $(…) blocked
#      after the timeout fired.
#   2. A human `umbra stop && umbra start` (the stop took 120s) was reported as
#      "NOT running and not startable". umbra lists `stopping`/`starting` mid-op.
#   3. "20/1 runner services active": the plist pinned RUNNER_INSTANCE_COUNT=1.
set -uo pipefail
OPS="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"
_pass=0; _fail=0
pass() { echo "PASS: $1"; _pass=$((_pass+1)); }
fail() { echo "FAIL: $1"; _fail=$((_fail+1)); }

# Kill a process and everything under it, plus any pid a fake recorded (the
# leaked-descendant fixtures detach on purpose, so a tree walk cannot find them).
_tree() { local c; for c in $(pgrep -P "$1" 2>/dev/null); do _tree "$c"; echo "$c"; done; }
cleanup() {
  local p
  for p in $(cat "$T"/*.pids 2>/dev/null); do kill -KILL "$p" 2>/dev/null; done
  rm -rf "$T"
}
trap cleanup EXIT

# bounded <secs> <outfile> <cmd...> — run in the background; 0 if it finished in
# time (its output in outfile), 99 if it was still running at the limit. A test of
# a hang must never hang the suite, or CI's 10-minute job timeout hides which one.
bounded() {
  local secs="$1" out="$2" p i=0; shift 2
  "$@" >"$out" 2>&1 &
  p=$!
  while kill -0 "$p" 2>/dev/null; do
    if [ "$i" -ge $((secs * 5)) ]; then
      # shellcheck disable=SC2046
      kill -KILL $(_tree "$p") "$p" 2>/dev/null
      wait "$p" 2>/dev/null   # reap quietly (no "Killed: 9" job notice)
      return 99
    fi
    sleep 0.2; i=$((i+1))
  done
  wait "$p" 2>/dev/null
  return 0
}

# ── fixture: a guard install with fake umbra + gh ────────────────────────────
G="$T/ops"; BIN="$T/bin"; FK="$T/fake"
mkdir -p "$G/lib" "$BIN" "$FK" "$T/home/.umbra/runners"
cp "$OPS/ci-runner-guard.sh" "$G/"
cp "$OPS/runner-focus.sh" "$G/"
cp "$OPS/lib/"*.sh "$G/lib/"
# The stub records ONE line per CALL in notify.count. The message itself is
# multi-line, so counting lines in notify.log counts LINES, not pages — and
# "paged exactly once" is the assertion that matters for a down machine.
printf '#!/bin/sh\necho CALL >> "%s/notify.count"\necho "$*" >> "%s/notify.log"\n' "$FK" "$FK" > "$G/notify.sh"
chmod +x "$G/notify.sh"

cat > "$BIN/umbra" <<'FAKE'
#!/usr/bin/env bash
# Fake umbra. Behaviour comes from files in $FK so one fixture serves every case.
FK="${FAKE_DIR:?}"
echo "$*" >> "$FK/calls.log"
case "$1" in
  list)
    # One state per call from $FK/states; the last line sticks.
    n=$(( $(cat "$FK/list.n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FK/list.n"
    total=$(wc -l < "$FK/states" | tr -d ' ')
    [ "$n" -le "$total" ] || n="$total"
    st=$(sed -n "${n}p" "$FK/states")
    # The machine NAME is a fixture too: a guard pointed at a machine umbra does
    # not list at all is the 'unlisted/unreachable' case — the shape left behind
    # when fwb-ci5/fwb-ci2 were deleted under a config that still named them.
    m=$(cat "$FK/list.machine" 2>/dev/null || echo fwb-ci6)
    echo "NAME     STATE    IP              CPUS  MEM(GiB)  DISK(GiB)  AUTOSTART"
    echo "$m  $st  192.168.127.10  6     6         60         true"
    ;;
  doctor)
    # Default: a pre-0.8 binary with no `doctor` at all, so the pre-flight is
    # skipped and every pre-existing test keeps taking the legacy path. A
    # fixture file opts INTO a doctor verdict.
    [ -f "$FK/doctor.json" ] || exit 1
    case "$*" in
      *--help*) exit 0 ;;                 # feature detection: doctor exists
      *--json*)
        # FAKE_DOCTOR_SLEEP models doctor's real 65s runtime on a degraded
        # guest; FAKE_MARK_ON_DOCTOR models `umbra rebuild` starting while the
        # guard is mid-run (after its pre-flight read the marker).
        [ -n "${FAKE_DOCTOR_SLEEP:-}" ] && sleep "$FAKE_DOCTOR_SLEEP"
        if [ -n "${FAKE_MARK_ON_DOCTOR:-}" ]; then
          mkdir -p "$(dirname "$FAKE_MARK_ON_DOCTOR")"
          printf 'expires=%s\nphase=create\n' $(( $(date +%s) + 1800 )) > "$FAKE_MARK_ON_DOCTOR"
        fi
        cat "$FK/doctor.json"; exit 1 ;;   # exit 1 = faults were found
    esac
    ;;
  rebuild)
    # NEVER a real rebuild. Record the call so a test can assert it happened
    # exactly once, and with which arguments.
    echo "$*" >> "$FK/rebuild.log"
    exit "${FAKE_REBUILD_RC:-0}"
    ;;
  start) exit "${FAKE_START_RC:-0}" ;;
  stop)  exit 0 ;;
  prune) exit 0 ;;
  shell)
    shift 2; [ "${1:-}" = "--" ] && shift
    # guest_kernel_docker_ok probe (newest kernel running + docker active).
    case "$*" in *"systemctl is-active docker"*) [ "${FAKE_KDOK:-1}" = 1 ] && echo KDOK; exit 0 ;; esac
    if [ "$*" = "bash" ]; then
      # stdin-fed script. HANG models the 2026-09-15 fault: umbra execs ssh, and
      # ssh sits waiting for a banner the guest never sends.
      if [ "${FAKE_HANG_STDIN_SHELL:-0}" = 1 ]; then
        echo $$ >> "$FK/hang.pids"; exec sleep 300
      fi
      script="$(cat)"
      case "$script" in
        # The root-writable probe. RO models errors=remount-ro — the guest
        # answers ssh but its root filesystem is read-only, which is exactly
        # what ext4 does when it trips the error flag.
        *rwtest*)         echo "${FAKE_ROOT_RW:-RW}" ;;
        *"date -u +%s"*)  date -u +%s ;;
        *"df --output"*)  echo 40 ;;
        *semgrep*)        echo FRESH ;;
        # The orphaned-hook probe (ppid,pid,args). FAKE_ORPHAN_PIDS is a
        # colon-separated pid list (never space-separated — it travels as one
        # positional arg through run_guard's env invocation); unset/empty
        # means "no orphans found", matching a healthy guest.
        *"ppid,pid,args"*) [ -n "${FAKE_ORPHAN_PIDS:-}" ] && printf '%s\n' "${FAKE_ORPHAN_PIDS//:/$'\n'}" ;;
      esac
    else
      case "$*" in
        # Run the guard's REAL heal command against a stub systemctl/sudo.
        *reset-failed*) PATH="$FAKE_DIR/gbin:$PATH" bash -c "$*" ;;
        *NRestarts*) echo "${FAKE_ACTIVE:-20}" ;;
        *"sort -u"*) echo "${FAKE_INSTALLED:-20}" ;;
      esac
    fi
    ;;
esac
FAKE
cat > "$BIN/gh" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  "variable get CI_ROUTING_PIN"*) echo "${FAKE_PIN:-}" ;;
  "variable get"*)       echo "${FAKE_USE_SH:-true}" ;;
  "variable set"*)       echo "$*" >> "$FAKE_DIR/varset.log" ;;
  *actions/runners*--jq*) echo 1 ;;
  *actions/runners*)     echo '{"runners":[{"status":"online","busy":'"${FAKE_RUNNER_BUSY:-false}"'}]}' ;;
  "run list"*)           echo '[]' ;;
esac
FAKE
chmod +x "$BIN/umbra" "$BIN/gh"

# run_guard <limit> [VAR=val…] — fresh fake state, then the guard under a bound.
run_guard() {
  local limit="$1"; shift
  rm -f "$FK"/calls.log "$FK"/list.n "$FK"/notify.log "$FK"/notify.count "$FK"/rebuild.log
  [ -f "$FK/states" ] || echo running > "$FK/states"
  bounded "$limit" "$T/guard.out" env -u RUNNER_INSTANCE_COUNT \
    HOME="$T/home" PATH="$BIN:$PATH" FAKE_DIR="$FK" \
    HOST_DISK_WARN_PCT=101 HOST_DISK_CRIT_PCT=101 UMBRA_SETTLE_POLL=1 \
    "$@" bash "$G/ci-runner-guard.sh"
}

# ── 1a. _ut keeps stdin ──────────────────────────────────────────────────────
# shellcheck source=/dev/null
. "$OPS/lib/os-state.sh"
got="$(printf 'hello\n' | _ut 5 cat)"
[ "$got" = "hello" ] && pass "_ut passes stdin through to the command" \
  || fail "_ut dropped stdin — got '$got' (a backgrounded \"\$@\" & reads /dev/null)"

got="$(_ut 5 sh -c 'exit 3')"; rc=$?
[ "$rc" = 3 ] && pass "_ut returns the command's own exit code" || fail "_ut exit code — got $rc want 3"

# ── 1b. _ut bounds the CALLER even when a descendant holds stdout ───────────
cat > "$T/leaky.sh" <<EOF
#!/usr/bin/env bash
# A child in a NEW session that inherits stdout and outlives its parent.
python3 -c 'import os,time; open("$T/leak.pids","a").write(str(os.getpid())+"\n"); os.setsid(); time.sleep(300)' &
wait
EOF
chmod +x "$T/leaky.sh"
bounded 15 "$T/leak.out" bash -c ". '$OPS/lib/os-state.sh'; out=\$(_ut 2 '$T/leaky.sh'); echo rc=\$?"
if [ $? -eq 0 ] && grep -q 'rc=124' "$T/leak.out"; then
  pass "_ut 2 returns 124 within bound although a descendant held stdout"
else
  fail "_ut 2 did not return within 15s — a leaked descendant kept \$(…) open ($(cat "$T/leak.out"))"
fi

# ── 1c. the guard's fallback copy is the same code ──────────────────────────
# The guard redefines _ut so it still works when lib/ is missing. Two copies that
# drift apart are two different wall clocks; this fixes them together.
def() { awk -v n="$2" '$0 ~ "^"n"\\(\\) \\{" {f=1} f {print} f && /^\}/ {exit}' "$1"; }
for fn in _ut _ut_tree; do
  a="$(def "$OPS/lib/os-state.sh" "$fn")"; b="$(def "$OPS/ci-runner-guard.sh" "$fn")"
  if [ -n "$a" ] && [ "$a" = "$b" ]; then pass "$fn identical in lib/os-state.sh and ci-runner-guard.sh"
  else fail "$fn differs between lib/os-state.sh and ci-runner-guard.sh (or is missing)"; fi
done

# ── 1d. every umbra invocation in the guard is wall-clocked ─────────────────
# Static, so it covers call sites no fixture drives (prune, a crit clock hard-set).
# Comment lines and double-quoted strings (alert text quoting commands) are dropped.
unwrapped="$(grep -vE '^[[:space:]]*#' "$OPS/ci-runner-guard.sh" | sed 's/"[^"]*"//g' | awk '
  { line=$0; n=gsub(/umbra +(list|shell|start|stop|prune|doctor|exec|runner|rebuild)/, "&", line)
    w=gsub(/_ut +([^ ]+ +)?umbra +(list|shell|start|stop|prune|doctor|exec|runner|rebuild)/, "&", line)
    if (n > w) print NR": "$0 }')"
if [ -z "$unwrapped" ]; then pass "every umbra call in the guard goes through _ut"
else fail "umbra call(s) without _ut:"; printf '        %s\n' "$unwrapped"; fi

# ── 1e. the whole guard finishes when the guest's ssh never answers ─────────
echo running > "$FK/states"
run_guard 90 FAKE_HANG_STDIN_SHELL=1 UMBRA_TIMEOUT=2 UMBRA_TIMEOUT_SLOW=3
if [ $? -eq 0 ] && grep -q 'guest clock unreadable' "$T/guard.out"; then
  pass "guard completes (clock/disk read as unknown) when stdin-fed umbra shell hangs"
else
  fail "guard did not finish within 90s with a hung 'umbra shell -- bash' — the 2026-09-15 hang"
  sed 's/^/        /' "$T/guard.out" | tail -5
fi

# ── 2a. a planned stop && start is not an outage ────────────────────────────
printf 'stopping\nstopping\nstopped\nstarting\nrunning\n' > "$FK/states"
run_guard 60
out="$(cat "$T/guard.out")"
if grep -q 'not startable' <<<"$out"; then
  fail "planned restart reported as 'not startable'"
elif grep -qE '^start' "$FK/calls.log" 2>/dev/null; then
  fail "guard ran its own 'umbra start' against a VM a human was already restarting"
elif ! grep -q "was 'stopping'" <<<"$out"; then
  fail "planned restart left no trace in the report"; sed 's/^/        /' <<<"$out" | head -8
elif [ -s "$FK/notify.log" ]; then
  fail "planned restart paged: $(cat "$FK/notify.log" | head -2)"
else
  pass "stopping→stopped→starting→running settles quietly (no start, no page)"
fi

# ── 2b. a transition that never ends still alerts ───────────────────────────
echo stopping > "$FK/states"
run_guard 60 UMBRA_TIMEOUT_SLOW=3
grep -q "has been 'stopping' for over" "$T/guard.out" \
  && pass "VM stuck in 'stopping' past the budget is still an alert" \
  || { fail "stuck 'stopping' not alerted"; sed 's/^/        /' "$T/guard.out" | head -6; }

# ── 2c. SELF-HEALED only when the start actually worked ─────────────────────
echo stopped > "$FK/states"
run_guard 60 FAKE_START_RC=1
if grep -q 'SELF-HEALED' "$T/guard.out"; then
  fail "failed 'umbra start' reported as SELF-HEALED"
elif grep -q "did NOT bring it up" "$T/guard.out"; then
  pass "failed start on a stopped VM alerts instead of claiming a heal"
else
  fail "failed start produced neither alert nor heal"; sed 's/^/        /' "$T/guard.out" | head -6
fi

# ── 3a. expected count comes from the installed units ───────────────────────
echo running > "$FK/states"
run_guard 60
grep -q 'runner fleet: 20/20 runner services active' "$T/guard.out" \
  && pass "healthy line reads 20/20 from the installed units" \
  || { fail "healthy line wrong: $(grep 'runner fleet' "$T/guard.out")"; }

# ── 3b. …and from the umbra runner manifest when that probe fails ───────────
cat > "$T/home/.umbra/runners/fwb-ci6.json" <<'EOF'
{"machine":"fwb-ci6","entries":[{"repo":"a/x","count":2},{"repo":"a/y","count":18}]}
EOF
run_guard 60 FAKE_INSTALLED=garbage
grep -q 'runner fleet: 20/20 runner services active' "$T/guard.out" \
  && pass "installed-units probe failing falls back to the manifest (sum of count = 20)" \
  || { fail "manifest fallback wrong: $(grep 'runner fleet' "$T/guard.out")"; }

# ── 3c. the launchd template does not pin the count ─────────────────────────
if grep -q 'RUNNER_INSTANCE_COUNT' "$OPS/launchd/com.ebda.os.ci-runner-guard.plist"; then
  fail "plist pins RUNNER_INSTANCE_COUNT — an explicit value overrides the live count (the 20/1 bug)"
else
  pass "plist leaves RUNNER_INSTANCE_COUNT unset so the count is measured"
fi

# ── 4. guest-disk-corrupt → auto-rebuild, behind guardrails ─────────────────
# Ahmad, 2026-09-16: "rebuild it if it comes back". fwb-ci6 corrupted twice in
# two days (ext4 going read-only); a reboot never recovered it and
# `umbra rebuild` always did, in ~9 min.
#
# The remedy is DESTRUCTIVE and unattended, so every test below asserts a
# guardrail rather than the happy path alone. No test here runs a real rebuild:
# the fake records the call and returns.
HIST="$T/home/.whisky-os-state/guest-rebuild-history.json"

doctor_json() {   # <rung> <subject>
  cat > "$FK/doctor.json" <<EOF
{"deep":false,"healthy":false,"unknown_only":false,"verdicts":[
 {"rung":"$1","health":"fail","subject":"$2",
  "reason":"guest root filesystem carries the ext4 error flag",
  "next_action":"recreate the machine — umbra stop/rm/create"}]}
EOF
}
rebuilds() { if [ -f "$FK/rebuild.log" ]; then grep -c . "$FK/rebuild.log" | tr -d ' '; else echo 0; fi; }
seed_history() {  # <epoch…>  (all for fwb-ci6)
  mkdir -p "$(dirname "$HIST")"
  python3 -c 'import json,sys; json.dump({"fwb-ci6":[int(x) for x in sys.argv[2:]]}, open(sys.argv[1],"w"))' "$HIST" "$@"
}
NOW_S="$(date -u +%s)"
# Short clocks everywhere: no test may wait on a real umbra.
# The cooldown/rate-limit cases below were written for the old MAX=2 per 24h budget; pin it so they keep testing their own logic
# (the production default is now MAX=1 per 12h, which makes the rate limit win over the cooldown in the 10-minute case).
RB_ENV=(UMBRA_TIMEOUT=3 UMBRA_TIMEOUT_SLOW=4 UMBRA_TIMEOUT_REBUILD=15 GUEST_REBUILD_SETTLE=1 GUEST_REBUILD_MAX=2 GUEST_REBUILD_WINDOW_SEC=86400)

# ── 4a. the corrupt rung rebuilds, exactly once ─────────────────────────────
echo running > "$FK/states"
doctor_json guest-disk-corrupt fwb-ci6
rm -f "$HIST"
run_guard 120 "${RB_ENV[@]}"
n="$(rebuilds)"
if [ "$n" != 1 ]; then
  fail "guest-disk-corrupt should rebuild exactly once — got $n"; sed 's/^/        /' "$T/guard.out" | head -8
elif ! grep -q 'fwb-ci6 --yes' "$FK/rebuild.log"; then
  fail "rebuild did not name the machine with --yes: $(cat "$FK/rebuild.log")"
elif ! grep -q 'REBUILT' "$T/guard.out"; then
  fail "rebuild happened but was not reported"; sed 's/^/        /' "$T/guard.out" | head -8
else
  pass "guest-disk-corrupt → exactly one 'umbra rebuild fwb-ci6 --yes', reported"
fi

# …and it is recorded, or the rate limit can never count anything.
if [ -f "$HIST" ] && grep -q 'fwb-ci6' "$HIST"; then
  pass "the rebuild is recorded in the persisted history"
else
  fail "rebuild was not recorded — the rate limit would never trip"
fi

# ── 4a2. a rebuild that leaves the guest on the image kernel / no docker is a
# FAILED rebuild, alerts, and BLOCKS the next automatic rebuild (no loop). ───
BLK="$T/home/.whisky-os-state/umbra-rebuild-blocked"
rm -f "$BLK" "$HIST"
doctor_json guest-disk-corrupt fwb-ci6
run_guard 120 "${RB_ENV[@]}" FAKE_KDOK=0
if [ "$(rebuilds)" = 1 ] && [ -f "$BLK" ] && grep -q 'did NOT restore' "$T/guard.out"; then
  pass "rebuild onto a non-HWE/no-docker guest fails verification and writes the block marker"
else
  fail "kernel/docker verification did not fail the rebuild (rebuilds=$(rebuilds), marker=$([ -f "$BLK" ] && echo y || echo n))"
fi
rm -f "$HIST"   # budget is free; only the marker may stop the next one
run_guard 120 "${RB_ENV[@]}"
if [ "$(rebuilds)" = 0 ] && grep -q 'BLOCKED' "$T/guard.out"; then
  pass "with the block marker present the guard does not rebuild again and says why"
else
  fail "guard rebuilt despite the block marker (rebuilds=$(rebuilds))"
fi
rm -f "$BLK" "$HIST"

# ── 4b. no other rung may rebuild ───────────────────────────────────────────
# host-hardware / netstack-dead / machine-crashed are unhealable (stand down);
# guest-ssh-stall is healable (normal path). NONE may destroy the guest.
rung_ok=1
for rung in guest-ssh-stall netstack-dead host-hardware machine-crashed; do
  doctor_json "$rung" fwb-ci6
  rm -f "$HIST"
  run_guard 120 "${RB_ENV[@]}"
  if [ "$(rebuilds)" != 0 ]; then
    fail "rung '$rung' triggered a rebuild — only guest-disk-corrupt may"; rung_ok=0
  fi
done
[ "$rung_ok" = 1 ] && pass "guest-ssh-stall, netstack-dead, host-hardware, machine-crashed never rebuild"

# A corrupt verdict about a machine this guard does NOT own must not rebuild
# ours — the target comes from the verdict's subject, never from config.
doctor_json guest-disk-corrupt some-other-guest
rm -f "$HIST"
run_guard 120 "${RB_ENV[@]}"
if [ "$(rebuilds)" = 0 ]; then
  pass "a corrupt verdict about another machine does not rebuild this one"
else
  fail "rebuilt on a verdict whose subject is a different machine: $(cat "$FK/rebuild.log")"
fi

# ── 4c. cooldown and rate limit block a second rebuild, and alert ───────────
doctor_json guest-disk-corrupt fwb-ci6
seed_history $((NOW_S - 600))          # 10 min ago: inside the 3h cooldown
run_guard 120 "${RB_ENV[@]}"
if [ "$(rebuilds)" != 0 ]; then
  fail "rebuilt again 10 min after the last one — the cooldown did not hold"
elif ! grep -qi 'cooldown' "$T/guard.out"; then
  fail "cooldown blocked the rebuild but did not say so"; sed 's/^/        /' "$T/guard.out" | head -8
elif [ ! -s "$FK/notify.log" ]; then
  fail "cooldown blocked the rebuild silently — it must alert"
else
  pass "a rebuild inside the cooldown is refused, explained and alerted"
fi

seed_history $((NOW_S - 20000)) $((NOW_S - 40000))   # 2 in 24h, both past the gap
run_guard 120 "${RB_ENV[@]}"
if [ "$(rebuilds)" != 0 ]; then
  fail "a third rebuild inside 24h was allowed — the rate limit did not hold"
elif ! grep -q 'ALREADY been auto-rebuilt' "$T/guard.out"; then
  fail "rate limit blocked the rebuild but did not name the count"; sed 's/^/        /' "$T/guard.out" | head -8
elif [ ! -s "$FK/notify.log" ]; then
  fail "rate limit blocked the rebuild silently — it must alert loudly"
else
  pass "the rate limit refuses a 3rd rebuild in 24h and pages instead"
fi

# ── 4d. the busy-runner rule, in BOTH directions ────────────────────────────
# Busy + the guest still answers with a WRITABLE root ⇒ a real job may be
# running: defer rather than destroy it.
rm -f "$HIST" "$BLK"   # a failed-verification rebuild leaves the block marker; each case starts unblocked
run_guard 120 "${RB_ENV[@]}" FAKE_RUNNER_BUSY=true FAKE_ROOT_RW=RW
if [ "$(rebuilds)" != 0 ]; then
  fail "rebuilt while a runner was busy on a usable guest — a live job was destroyed"
elif ! grep -qi 'deferr' "$T/guard.out"; then
  fail "deferred for a busy runner but did not say so"; sed 's/^/        /' "$T/guard.out" | head -8
else
  pass "a busy runner on a USABLE guest defers the rebuild"
fi

# Busy + root READ-ONLY ⇒ the guest is already unusable, so 'busy' is a stale
# registration, not work in flight. Measured 2026-09-16: runners drained 20→16
# while jobs queued unrun. Deferring to that flag would defer forever.
rm -f "$HIST" "$BLK"   # a failed-verification rebuild leaves the block marker; each case starts unblocked
run_guard 120 "${RB_ENV[@]}" FAKE_RUNNER_BUSY=true FAKE_ROOT_RW=RO
if [ "$(rebuilds)" = 1 ]; then
  pass "a busy runner on an UNUSABLE guest does not block the rebuild"
else
  fail "busy+unusable did not rebuild (got $(rebuilds)) — it would defer forever"
  sed 's/^/        /' "$T/guard.out" | head -8
fi

# ── 4e. a rebuild that does not restore service must alert ──────────────────
# Root still read-only after the rebuild = the fault's own signature. A rebuild
# that exits 0 is not a restored service.
rm -f "$HIST" "$BLK"   # a failed-verification rebuild leaves the block marker; each case starts unblocked
run_guard 120 "${RB_ENV[@]}" FAKE_ROOT_RW=RO
if [ "$(rebuilds)" != 1 ]; then
  fail "expected one rebuild attempt, got $(rebuilds)"
elif ! grep -q 'did NOT restore service' "$T/guard.out"; then
  fail "rebuild left the guest broken but the guard claimed success"; sed 's/^/        /' "$T/guard.out" | head -8
elif [ ! -s "$FK/notify.log" ]; then
  fail "failed rebuild did not alert"
else
  pass "a rebuild that leaves root read-only is reported as NOT restored, and alerts"
fi

# A non-zero `umbra rebuild` exit is likewise never a success.
rm -f "$HIST" "$BLK"   # a failed-verification rebuild leaves the block marker; each case starts unblocked
run_guard 120 "${RB_ENV[@]}" FAKE_REBUILD_RC=1
if grep -q 'did NOT restore service' "$T/guard.out"; then
  pass "a failing 'umbra rebuild' is reported as NOT restored"
else
  fail "umbra rebuild exited 1 but the guard did not report a failure"
  sed 's/^/        /' "$T/guard.out" | head -8
fi

rm -f "$FK/doctor.json"

# ── 4f. guest-binaries-missing shares the SAME guarded rebuild path ─────────
# 2026-09-22: umbra doctor gained a guest-binaries-missing rung (dpkg's own
# database says packages are installed whose files are gone — the exact fault
# that froze CI fleet-wide that day). It is layered onto rebuild_corrupt_guest
# the same way guest-disk-corrupt is: same busy rule, same cooldown, same rate
# limit, same post-rebuild verification. Every guardrail test above already
# covers those mechanics for guest-disk-corrupt; this section proves
# guest-binaries-missing goes through the IDENTICAL gates rather than a
# separate, unaudited path — and that its alert text says what actually broke.
doctor_json guest-binaries-missing fwb-ci6
rm -f "$HIST" "$BLK"   # a failed-verification rebuild leaves the block marker; each case starts unblocked
run_guard 120 "${RB_ENV[@]}"
n="$(rebuilds)"
if [ "$n" != 1 ]; then
  fail "guest-binaries-missing should rebuild exactly once — got $n"; sed 's/^/        /' "$T/guard.out" | head -8
elif ! grep -q 'fwb-ci6 --yes' "$FK/rebuild.log"; then
  fail "rebuild did not name the machine with --yes: $(cat "$FK/rebuild.log")"
elif ! grep -q 'REBUILT' "$T/guard.out"; then
  fail "rebuild happened but was not reported"; sed 's/^/        /' "$T/guard.out" | head -8
elif grep -q 'root filesystem' "$T/guard.out"; then
  fail "guest-binaries-missing was reported as a root-filesystem fault — wrong evidence for a human to act on"
  sed 's/^/        /' "$T/guard.out" | head -8
elif ! grep -qi 'MISSING BINARIES' "$T/guard.out"; then
  fail "guest-binaries-missing rebuild did not name the actual fault"; sed 's/^/        /' "$T/guard.out" | head -8
else
  pass "guest-binaries-missing → exactly one 'umbra rebuild fwb-ci6 --yes', reported with the RIGHT fault named"
fi

# THE RULING (docs/plans/2026-09-22-throttle-hardening.md): the busy rule is
# NOT weakened for this rung, even though a broken throttle hook can make a
# runner look busy for longer than a real job would. Same gate, same test
# shape as 4d, just against guest-binaries-missing.
doctor_json guest-binaries-missing fwb-ci6
rm -f "$HIST" "$BLK"   # a failed-verification rebuild leaves the block marker; each case starts unblocked
run_guard 120 "${RB_ENV[@]}" FAKE_RUNNER_BUSY=true FAKE_ROOT_RW=RW
if [ "$(rebuilds)" != 0 ]; then
  fail "rebuilt guest-binaries-missing while a runner was busy on a usable guest — the busy rule was not reused"
elif ! grep -qi 'deferr' "$T/guard.out"; then
  fail "deferred for a busy runner but did not say so"; sed 's/^/        /' "$T/guard.out" | head -8
else
  pass "guest-binaries-missing also defers to a busy runner on a USABLE guest — the busy rule is shared, not weakened"
fi

rm -f "$FK/doctor.json"

# ── 5. the DOWN verdict actually PAGES ───────────────────────────────────────
# The guard's dead-machine alert was proven only by READING it: 29 `flipped`
# sites feed an ungated notify at the end, and until now no test had watched one
# of them fire. A page nobody has seen fail is not a page. (4c/4e assert that a
# blocked rebuild alerts; neither pins the count, and neither covers the machine
# being unreachable in the first place.)
#
# Scenario: umbra is alive but does not list THIS guard's machine — umbra_vm_state
# returns empty, the 'unlisted/unreachable' branch. Nothing touches the real
# fleet: umbra, gh and the notifier are the same fakes as every case above.
echo other-ci > "$FK/list.machine"
echo running  > "$FK/states"
run_guard 90 UMBRA_TIMEOUT=3 UMBRA_TIMEOUT_SLOW=4
calls=$(grep -c '^CALL' "$FK/notify.count" 2>/dev/null) || calls=0
if ! grep -q 'NOT running and not startable' "$T/guard.out"; then
  fail "an unlisted VM did not produce the down verdict"; sed 's/^/        /' "$T/guard.out" | head -8
elif [ "$calls" -ne 1 ]; then
  fail "the down verdict paged $calls time(s), want exactly 1"
elif ! grep -q 'NOT running and not startable' "$FK/notify.log"; then
  fail "it paged, but the page did not carry the down text: $(head -3 "$FK/notify.log")"
else
  pass "a VM umbra cannot list pages EXACTLY once, and the page names the fault"
fi

# MUTATION: neuter the notify call in the run COPY (never the source). The same
# scenario must then page zero times, or the assertion above proves nothing.
cp "$G/ci-runner-guard.sh" "$T/guard-pristine.sh"
python3 - "$G/ci-runner-guard.sh" <<'PYEOF'
import sys
p = sys.argv[1]
t = open(p).read()
old = '"$HERE/notify.sh" "CI Runner Guard" "$msg" >/dev/null 2>&1 || true'
if old not in t:
    sys.exit("mutation setup failed: the notify call was not found (fixture is stale)")
open(p, 'w').write(t.replace(old, ': # MUTATED: notify removed'))
PYEOF
run_guard 90 UMBRA_TIMEOUT=3 UMBRA_TIMEOUT_SLOW=4
mcalls=$(grep -c '^CALL' "$FK/notify.count" 2>/dev/null) || mcalls=0
[ "$mcalls" -eq 0 ] \
  && pass "MC: removing the notify call silences the down page (the assertion is load-bearing)" \
  || fail "MC: the guard still paged $mcalls time(s) with its notify call removed"

cp "$T/guard-pristine.sh" "$G/ci-runner-guard.sh"
if cmp -s "$OPS/ci-runner-guard.sh" "$G/ci-runner-guard.sh"; then
  pass "MC: the mutated copy was restored byte-identical to ops/ci-runner-guard.sh"
else
  fail "MC: the run copy no longer matches ops/ci-runner-guard.sh after the mutation"
fi
rm -f "$FK/list.machine"

# ── 6. orphaned CI-throttle hook processes ──────────────────────────────────
# 2026-09-22: GitHub cancelling a job stuck in the throttle hook does not
# signal the hook — 10 such orphans (parent pid 1) were found live on one
# guest. The guard now probes for them on every running guest and alerts.
# ALERT-ONLY BY DESIGN (see the probe's own comment in ci-runner-guard.sh):
# this section proves it pages, never that it kills anything — there is
# nothing here for it to kill.
echo running > "$FK/states"

run_guard 90 UMBRA_TIMEOUT=3 UMBRA_TIMEOUT_SLOW=4 FAKE_ORPHAN_PIDS=12345:12346
if ! grep -q 'orphaned CI-throttle hook' "$T/guard.out"; then
  fail "2 orphaned hook processes present but the guard did not alert"; sed 's/^/        /' "$T/guard.out" | head -8
elif ! grep -q '12345' "$T/guard.out"; then
  fail "orphan alert did not name the pids: $(grep 'orphaned' "$T/guard.out")"
elif [ ! -s "$FK/notify.log" ]; then
  fail "orphaned hook processes were found but nothing paged"
else
  pass "orphaned CI-throttle hook processes (parent pid 1) are detected, named, and paged"
fi

run_guard 90 UMBRA_TIMEOUT=3 UMBRA_TIMEOUT_SLOW=4
if grep -q 'orphaned CI-throttle hook' "$T/guard.out"; then
  fail "a healthy guest (no orphans) was reported as having orphaned hook processes"
else
  pass "no orphan alert when the probe finds nothing"
fi

# MUTATION: neuter the orphan-count comparison in the run COPY (never the
# source). The same FAKE_ORPHAN_PIDS scenario must then alert zero times, or
# the assertion above proves nothing.
cp "$G/ci-runner-guard.sh" "$T/guard-pristine2.sh"
python3 - "$G/ci-runner-guard.sh" <<'PYEOF'
import sys
p = sys.argv[1]
t = open(p).read()
old = 'if [ "${_ocount:-0}" -gt 0 ]; then'
if t.count(old) != 1:
    sys.exit("mutation setup failed: the orphan-count check was not found exactly once (fixture is stale)")
open(p, 'w').write(t.replace(old, 'if false; then', 1))
PYEOF
run_guard 90 UMBRA_TIMEOUT=3 UMBRA_TIMEOUT_SLOW=4 FAKE_ORPHAN_PIDS=12345:12346
if grep -q 'orphaned CI-throttle hook' "$T/guard.out"; then
  fail "MC: the guard still alerted on orphans with the count-check neutered"
else
  pass "MC: neutering the orphan-count check silences the alert (the assertion is load-bearing)"
fi

cp "$T/guard-pristine2.sh" "$G/ci-runner-guard.sh"
if cmp -s "$OPS/ci-runner-guard.sh" "$G/ci-runner-guard.sh"; then
  pass "MC: the mutated copy was restored byte-identical to ops/ci-runner-guard.sh"
else
  fail "MC: the run copy no longer matches ops/ci-runner-guard.sh after the mutation"
fi

# ── CI_ROUTING_PIN (2026-10-03) ─────────────────────────────────────────────
# The owner moved store CI to cloud; the guard flipped it back 7 minutes later
# (cancelled runs read as "cloud infra failing"). A pin is an owner decision the
# guard must enforce, not override.
rm -f "$FK/varset.log"
run_guard 60 FAKE_PIN=cloud FAKE_USE_SH=true
if grep -q "variable set USE_SELF_HOSTED .*--body false" "$FK/varset.log" 2>/dev/null; then
  pass "CI_ROUTING_PIN=cloud restores USE_SELF_HOSTED=false when something set it true"
else
  fail "CI_ROUTING_PIN=cloud did not restore USE_SELF_HOSTED=false — varset: $(cat "$FK/varset.log" 2>/dev/null)"
fi
if grep -q -- "--body true" "$FK/varset.log" 2>/dev/null; then
  fail "CI_ROUTING_PIN=cloud: the guard still set USE_SELF_HOSTED=true"
else
  pass "CI_ROUTING_PIN=cloud: the guard never sets USE_SELF_HOSTED=true"
fi

rm -f "$FK/varset.log"
run_guard 60 FAKE_PIN=cloud FAKE_USE_SH=false
[ ! -s "$FK/varset.log" ] && pass "CI_ROUTING_PIN=cloud with routing already cloud: no variable writes" \
  || fail "pinned + already correct still wrote: $(cat "$FK/varset.log")"

# MC: drop the pin block → the restore must stop happening.
cp "$G/ci-runner-guard.sh" "$T/guard-pristine3.sh"
python3 - "$G/ci-runner-guard.sh" <<'PY'
import sys; p=sys.argv[1]; s=open(p).read()
a='  if [ "$pin" = "cloud" ] || [ "$pin" = "self-hosted" ]; then'
assert s.count(a)==1; open(p,'w').write(s.replace(a,'  if false; then'))
PY
rm -f "$FK/varset.log"
run_guard 60 FAKE_PIN=cloud FAKE_USE_SH=true
if grep -q -- "--body false" "$FK/varset.log" 2>/dev/null; then
  fail "MC: with the pin block disabled the restore still happened — the assertion is not load-bearing"
else
  pass "MC: disabling the pin block stops the restore (the assertion is load-bearing)"
fi
cp "$T/guard-pristine3.sh" "$G/ci-runner-guard.sh"
cmp -s "$OPS/ci-runner-guard.sh" "$G/ci-runner-guard.sh" && pass "MC: pin-mutated copy restored byte-identical" \
  || fail "MC: pin-mutated copy not restored"

# ── RUNNER FOCUS (2026-10-08): a deactivated runner is not healed ──────────
mkdir -p "$FK/gbin" "$T/home/.umbra"
cat > "$FK/gbin/systemctl" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  list-units) cat "$FAKE_DIR/units" ;;
  restart) echo "$2" >> "$FAKE_DIR/restarted.log" ;;
esac
STUB
printf '#!/bin/sh\nexec "$@"\n' > "$FK/gbin/sudo"; chmod +x "$FK/gbin/systemctl" "$FK/gbin/sudo"
# units: ebda-1 is focused and dead (must be healed); quote-studio-1/2 are
# deactivated and dead (must NOT be touched); ebda-2 healthy.
cat > "$FK/units" <<'U'
actions.runner.Whisky-11.umbra-ebda-1.service loaded failed failed
actions.runner.Whisky-11.umbra-ebda-2.service loaded active running
actions.runner.Ebda-AI-Studio-ebda-studio.fwb-ci6-quote-studio-1.service loaded inactive dead
actions.runner.Ebda-AI-Studio-ebda-studio.fwb-ci6-quote-studio-2.service loaded inactive dead
U
echo '{"focus":["ebda"]}' > "$T/home/.umbra/runner-focus.json"
rm -f "$FK/restarted.log"
run_guard 90 FAKE_ACTIVE=1 FAKE_INSTALLED=2
if grep -q 'umbra-ebda-1' "$FK/restarted.log" 2>/dev/null; then pass "focus: a dead FOCUSED runner is still healed"
else fail "focus: focused dead runner was not restarted — $(cat "$FK/restarted.log" 2>/dev/null)"; fi
if grep -q 'quote-studio' "$FK/restarted.log" 2>/dev/null; then fail "focus: a DEACTIVATED runner was restarted: $(cat "$FK/restarted.log")"
else pass "focus: a deactivated runner (quote-studio) is not healed"; fi
grep -q '1/2 runner services active' "$T/guard.out" && pass "focus: expected count is the focused runners only (1/2)" \
  || { fail "focus: expected count not focus-scoped"; sed 's/^/        /' "$T/guard.out" | head -5; }
# unreadable focus file -> heal NOTHING, say so
echo 'not json' > "$T/home/.umbra/runner-focus.json"; rm -f "$FK/restarted.log"
run_guard 90 FAKE_ACTIVE=1 FAKE_INSTALLED=2
[ ! -s "$FK/restarted.log" ] && grep -q 'unreadable' "$T/guard.out" && pass "focus: unreadable focus file disables healing and alerts" \
  || fail "focus: unreadable focus file still healed or stayed silent"
# no focus file -> old behaviour (everything not active is healed)
rm -f "$T/home/.umbra/runner-focus.json" "$FK/restarted.log"
run_guard 90 FAKE_ACTIVE=1 FAKE_INSTALLED=4
grep -q 'quote-studio-1' "$FK/restarted.log" 2>/dev/null && pass "focus: no focus file = every dead runner healed (unchanged behaviour)" \
  || fail "focus: no-focus-file behaviour regressed"
rm -f "$FK/units"

# ── 7. hands-off while `umbra rebuild` provisions the guest (2026-10-16) ────
# At 02:53 the guard rebooted a brand-new fwb-ci6 mid-rebuild: a provisioning
# guest (ssh down across the HWE restart, no runner yet) looks exactly like a
# hung one. umbra rebuild now holds ~/.umbra/provisioning/<vm> with expires=.
PROV="$T/home/.umbra/provisioning"; mkdir -p "$PROV"
rm -f "$FK/doctor.json"
# Stopped VM: without the marker the guard would `umbra start` it.
echo stopped > "$FK/states"
printf 'expires=%s\nphase=kernel\npid=1\n' $(( $(date +%s) + 1800 )) > "$PROV/fwb-ci6"
doctor_json guest-disk-corrupt fwb-ci6   # would otherwise trigger the guard's own rebuild
rm -f "$HIST" "$BLK"   # a failed-verification rebuild leaves the block marker; each case starts unblocked
run_guard 90 "${RB_ENV[@]}"; rc_out="$(cat "$T/guard.out")"
if grep -qE '^(start|stop|rebuild|prune)' "$FK/calls.log" 2>/dev/null; then
  fail "provisioning: guard mutated a guest umbra rebuild is provisioning: $(grep -E '^(start|stop|rebuild|prune)' "$FK/calls.log" | tr '\n' ';')"
elif ! grep -q 'PROVISIONING' <<<"$rc_out"; then
  fail "provisioning: stand-down was silent"; sed 's/^/        /' <<<"$rc_out" | head -5
elif grep -q 'fwb-ci6' "$FK/notify.log" 2>/dev/null && grep -qiE 'HUNG|NOT running|CI is|queuing forever' "$FK/notify.log"; then
  fail "provisioning: a deliberate rebuild paged as an outage: $(head -3 "$FK/notify.log")"
else
  pass "provisioning: a fresh marker → no start/stop/rebuild/prune on that VM, no outage page, says why"
fi
if grep -rqs 'provisioning' "$T/home/.whisky-os-state/runner-status.json" 2>/dev/null; then
  pass "provisioning: the stand-down is on the dashboard status"
else
  fail "provisioning: dashboard status does not mention the provisioning stand-down"
fi
# The stand-down is PER MACHINE: findings already collected (a host disk at
# crit, which a rebuild allocating a fresh disk.img makes worse) still page,
# and the fleet-wide checks still run.
echo running > "$FK/states"; rm -f "$FK/doctor.json"
printf 'expires=%s\nphase=kernel\n' $(( $(date +%s) + 1800 )) > "$PROV/fwb-ci6"
run_guard 90 "${RB_ENV[@]}" HOST_DISK_WARN_PCT=1 HOST_DISK_CRIT_PCT=2
if ! grep -q 'HOST disk' "$FK/notify.log" 2>/dev/null; then
  fail "provisioning: the host-disk crit finding was dropped by the stand-down"; sed 's/^/        /' "$T/guard.out" | head -6
elif ! grep -q 'df --output' "$FK/calls.log" 2>/dev/null && ! grep -q 'shell' "$FK/calls.log" 2>/dev/null; then
  fail "provisioning: the fleet-wide guest checks (clock/disk) were skipped"
elif ! grep -q 'ebda-store' "$T/guard.out"; then
  fail "provisioning: the per-repo checks were skipped"; sed 's/^/        /' "$T/guard.out" | head -6
else
  pass "provisioning: stand-down is per machine — host-disk page, fleet checks and per-repo checks still run"
fi
# Check-then-act: a rebuild that starts AFTER the pre-flight read (here: while
# doctor runs) must still stop the guard's own `umbra rebuild`.
rm -f "$PROV/fwb-ci6"; doctor_json guest-disk-corrupt fwb-ci6; rm -f "$HIST"
run_guard 120 "${RB_ENV[@]}" FAKE_MARK_ON_DOCTOR="$PROV/fwb-ci6"
if [ "$(rebuilds)" != 0 ]; then
  fail "provisioning: marker written mid-run (after pre-flight) did not stop the guard's rebuild"
else
  pass "provisioning: the marker is re-checked right before acting (no rebuild on top of one that just started)"
fi
rm -f "$PROV/fwb-ci6" "$FK/doctor.json"
# Expired marker = a dead rebuild: the guard is back to normal (starts the VM).
echo stopped > "$FK/states"
printf 'expires=%s\nphase=kernel\n' $(( $(date +%s) - 60 )) > "$PROV/fwb-ci6"
rm -f "$FK/doctor.json"
run_guard 90 "${RB_ENV[@]}"
if grep -qE '^start' "$FK/calls.log" 2>/dev/null; then
  pass "provisioning: an EXPIRED marker does not disable the guard (dead rebuild)"
else
  fail "provisioning: expired marker still kept the guard hands-off"; sed 's/^/        /' "$T/guard.out" | head -5
fi
# Another machine's marker does not cover ours.
mv "$PROV/fwb-ci6" "$PROV/other-vm"; printf 'expires=%s\n' $(( $(date +%s) + 1800 )) > "$PROV/other-vm"
run_guard 90 "${RB_ENV[@]}"
grep -qE '^start' "$FK/calls.log" 2>/dev/null && pass "provisioning: a marker for another machine does not cover this one" \
  || fail "provisioning: another machine's marker silenced the guard for $UM"
rm -f "$PROV/other-vm"

# ── 8. guest-crash-damage is ALERTED, never rebuilt ─────────────────────────
# 2026-10-16: after a kernel crash, a tool-cache node died with SIGILL and dmesg
# had EXT4 warnings while every runner showed ONLINE. The remedy is local, so
# the guard pages with doctor's next action and keeps healing as normal.
echo running > "$FK/states"
doctor_json guest-crash-damage fwb-ci6
rm -f "$HIST" "$BLK"   # a failed-verification rebuild leaves the block marker; each case starts unblocked
run_guard 120 "${RB_ENV[@]}"
if [ "$(rebuilds)" != 0 ]; then
  fail "crash-damage: the guard rebuilt the guest — the remedy is local"
elif ! grep -q 'guest-crash-damage' "$FK/notify.log" 2>/dev/null; then
  fail "crash-damage: not paged"; sed 's/^/        /' "$T/guard.out" | head -6
elif ! grep -q 'runner fleet: 20/20 runner services active' "$T/guard.out"; then
  fail "crash-damage: the normal liveness path did not run"; sed 's/^/        /' "$T/guard.out" | head -6
else
  pass "crash-damage: paged with doctor's next action, no rebuild, normal liveness kept"
fi
# Doctor took 65-66s live; it must get its own wall clock, not the 45s probe
# ceiling, or the unhealable pre-flight and this page silently never fire.
doctor_json guest-crash-damage fwb-ci6
run_guard 120 "${RB_ENV[@]}" FAKE_DOCTOR_SLEEP=5 UMBRA_TIMEOUT_DOCTOR=20
grep -q 'guest-crash-damage' "$FK/notify.log" 2>/dev/null \
  && pass "doctor: a doctor slower than UMBRA_TIMEOUT still pages (own UMBRA_TIMEOUT_DOCTOR)" \
  || { fail "doctor: a slow doctor was cut off at the probe ceiling"; sed 's/^/        /' "$T/guard.out" | head -5; }
run_guard 120 "${RB_ENV[@]}" FAKE_DOCTOR_SLEEP=6 UMBRA_TIMEOUT_DOCTOR=2
grep -q 'umbra doctor returned nothing' "$T/guard.out" \
  && pass "doctor: an empty doctor result is logged, not silently treated as healthy" \
  || { fail "doctor: timed-out doctor left no trace"; sed 's/^/        /' "$T/guard.out" | head -5; }
doctor_json guest-crash-damage some-other-vm
run_guard 120 "${RB_ENV[@]}"
grep -q 'guest-crash-damage' "$FK/notify.log" 2>/dev/null \
  && fail "crash-damage: paged about a machine the guard does not own" \
  || pass "crash-damage: a verdict about another machine is not paged"
rm -f "$FK/doctor.json"

echo "ci-runner-guard: $_pass passed, $_fail failed"
[ "$_fail" -eq 0 ]
