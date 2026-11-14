#!/usr/bin/env bash
# host-lock.sh <command...> - host-wide mutex for HEAVY test runs: only ONE full suite on this Mac at a time.
#
# WHY (2026-10-25). Several agents pushed in parallel and every pre-push ran the whole vitest suite (measured 105
# concurrent vitest processes) on a 16 GB host beside the CI runners: swap 3 of 4 GB, load 30+, the runners wedged on
# I/O and its ext4 corrupted three times in two days. The gate is never skipped; it QUEUES.
#
# ONE lock for everything heavy: ~/.claude/locks/heavy-test.lock (macOS lockf(1); no flock(1) on macOS; Linux falls
# back to flock on the same path). The kernel drops it when the holder dies, so a killed push never wedges the queue.
#
# RE-ENTRANT (the 2026-10-25 deadlock): BSD lockf is not re-entrant. A manual "wrap git push in lockf" rule plus a
# pre-push hook taking the same lock made the push wait on its own parent for 3600 s. So the lock holder exports
# HOST_LOCK_HELD=<lockfile> to its child; a nested host-lock.sh sees the marker, VERIFIES the lock really is held
# (a stale marker inherited by a long-lived process must not bypass the queue) and runs the command directly.
#
# usage: host-lock.sh <command...>     env: HOST_LOCK_FILE (tests), HOST_LOCK_MAX_WAIT_S (3600)
# exit: the command's status; 64 usage; 75 = timed out waiting or no lock tool (never runs unlocked, never skips)
set -uo pipefail
[ "$#" -gt 0 ] || { echo "host-lock: no command" >&2; exit 64; }
file="${HOST_LOCK_FILE:-$HOME/.claude/locks/heavy-test.lock}"
max="${HOST_LOCK_MAX_WAIT_S:-3600}"
mkdir -p "$(dirname "$file")"
if command -v lockf >/dev/null 2>&1; then
  try() { lockf -k -t 0 "$file" true 2>/dev/null; }
  run() { lockf -k -t "$max" "$file" sh -c "$inner" sh "$file" "$@"; }
elif command -v flock >/dev/null 2>&1; then
  touch "$file"
  try() { flock -n -E 75 "$file" true; }
  run() { flock -w "$max" -E 75 "$file" sh -c "$inner" sh "$file" "$@"; }
else
  echo "host-lock: neither lockf nor flock is available; refusing to run the heavy gate unlocked" >&2; exit 75
fi
# inner: record the owner (so a waiter can say who is ahead) and hand the marker to the child
inner='f=$1; shift; printf "%s %s %s\n" "$$" "$(date +%FT%T)" "$*" > "$f.owner" 2>/dev/null; HOST_LOCK_HELD=$f; export HOST_LOCK_HELD; exec "$@"'

# already inside a holder? the marker only counts while the lock is genuinely held (try fails = busy = held by someone)
if [ "${HOST_LOCK_HELD:-}" = "$file" ] && ! try; then exec "$@"; fi

if ! try; then
  echo "-> host-lock: another heavy test run holds $file; this one queues (never skipped)." >&2
  [ -r "$file.owner" ] && echo "   ahead of us: $(cut -c1-160 "$file.owner")" >&2
  start=$SECONDS
  run "$@"; rc=$?
  if [ "$rc" -eq 75 ] && [ $((SECONDS - start)) -ge "$max" ]; then
    echo "host-lock: waited ${max}s for the heavy-test lock; refusing to run unlocked or skip." >&2
  fi
  exit "$rc"
fi
run "$@"
