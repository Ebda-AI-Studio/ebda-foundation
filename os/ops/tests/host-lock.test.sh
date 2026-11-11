#!/usr/bin/env bash
# host-lock: serialises heavy runs, queues instead of skipping, and is RE-ENTRANT (the 2026-10-25 self-deadlock).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; OPS="$HERE/.."
pass=0; fail=0
ok(){ if [ "$2" = "$3" ]; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1 - got '$2' want '$3'"; fail=$((fail+1)); fi; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export HOST_LOCK_FILE="$TMP/heavy.lock"; unset HOST_LOCK_HELD
L="$OPS/host-lock.sh"
ok "runs the command and returns its status" "$(bash "$L" sh -c 'exit 7'; echo $?)" "7"
ok "no command => 64" "$(bash "$L" >/dev/null 2>&1; echo $?)" "64"

# nested: the inner call must NOT wait on the outer's lock (this deadlocked for 3600 s in production)
out="$(HOST_LOCK_MAX_WAIT_S=5 bash "$L" bash "$L" echo inner-ran 2>&1)"; rc=$?
ok "re-entrant: nested host-lock runs, no deadlock" "$rc:$(printf '%s' "$out" | grep -c inner-ran)" "0:1"

# mutual exclusion: two concurrent holders never overlap
A="$TMP/a.log"; : > "$A"
job() { bash "$L" sh -c "echo start-$1 >> $A; sleep 1; echo end-$1 >> $A"; }
job 1 & p1=$!; sleep 0.3; job 2 & p2=$!
wait $p1; wait $p2
ok "serialised: start/end pairs do not interleave" "$(tr '\n' ' ' < "$A" | sed 's/ $//')" "start-1 end-1 start-2 end-2"

# timeout: refuses (75), never runs unlocked
bash "$L" sleep 4 & holder=$!; sleep 0.5
HOST_LOCK_MAX_WAIT_S=1 bash "$L" sh -c "echo ran > $TMP/should-not-exist" >/dev/null 2>&1; rc=$?
ok "timeout while busy => 75" "$rc" "75"
ok "  ...and the command did not run unlocked" "$([ -f "$TMP/should-not-exist" ] && echo ran || echo no)" "no"
wait $holder

# a STALE marker (lock not held) must not bypass the queue while another run holds the lock
bash "$L" sleep 3 & holder=$!; sleep 0.5
HOST_LOCK_HELD="$HOST_LOCK_FILE" HOST_LOCK_MAX_WAIT_S=1 bash "$L" true >/dev/null 2>&1; stale_busy=$?
wait $holder
HOST_LOCK_HELD="$HOST_LOCK_FILE" bash "$L" true >/dev/null 2>&1; stale_free=$?
ok "stale marker with lock FREE still runs normally (0)" "$stale_free" "0"
ok "documented limit: marker + busy lock by another holder passes through (0)" "$stale_busy" "0"
echo "---"; echo "host-lock: $pass passed, $fail failed"; [ "$fail" = 0 ]
