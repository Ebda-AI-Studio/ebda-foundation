#!/usr/bin/env bash
# S0 sweep safety (incident I12, 2026-10-26): ~7 workspace-hygiene runs at once hung du/df, and `--help` ran a real sweep.
#   1. 7 parallel sweeps -> exactly 1 runs, 6 exit "already running"
#   2. 7 parallel --repo runs -> 1 runs, 6 are queued, the queue is drained when the first finishes
#   3. --help (hygiene, every watcher, maintenance, post-merge-cleanup) makes ZERO shimmed calls and deletes nothing
#   4. an unknown flag is exit 2 and runs nothing
#   5. a hung du reports "?" and the sweep still finishes; a hung df makes the run a DRY RUN that deletes nothing
#   6. a held lock stops every watcher; a stale (dead pid) lock is reclaimed
#   7. mutation: without the lock check test 1 goes red
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; OPS="$(cd "$HERE/.." && pwd)"
pass=0; fail=0
ok(){ if [ "$2" = "$3" ]; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1 - got '$2' want '$3'"; fail=$((fail+1)); fi; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; P="$HOME/Desktop/projects"
mkdir -p "$P/Ebda-AI-Studio/internal-projects/ebda-store/.git" "$P/_worktrees" "$HOME/.whisky-os-state"
export HYGIENE_LIVE_CWDS="" OS_LOCK_DIR="$TMP/locks" HYGIENE_QUEUE="$TMP/queue" OS_SHIM_DIR="$TMP/shim" CALLS="$TMP/calls"
mkdir -p "$OS_SHIM_DIR" "$TMP/ops"; cp "$OPS/workspace-hygiene.sh" "$TMP/ops/"; cp -R "$OPS/lib" "$TMP/ops/lib"
mk() { # shim <name> <real-path>: log, optionally sleep $SHIM_<NAME>_SLEEP, then pass through
  local n="$1" real="$2" up; up="$(echo "$n" | tr a-z A-Z)"
  printf '#!/bin/bash\necho "%s $*" >> "$CALLS"\ns="${SHIM_%s_SLEEP:-0}"; [ "$s" != 0 ] && sleep "$s"\nexec %s "$@"\n' "$n" "$up" "$real" > "$OS_SHIM_DIR/$n"
  chmod +x "$OS_SHIM_DIR/$n"
}
mk df /bin/df; mk du /usr/bin/du; mk rm /bin/rm; mk umbra /usr/bin/true; mk gh /usr/bin/true
H() { bash "$TMP/ops/workspace-hygiene.sh" "$@"; }

# ---- 1. seven parallel sweeps
: > "$CALLS"; H > "$TMP/solo.out" 2>&1; solo_df=$(grep -c '^df' "$CALLS")
rm -rf "$OS_LOCK_DIR"; : > "$CALLS"
for i in 1 2 3 4 5 6 7; do SHIM_DF_SLEEP=2 H > "$TMP/p1.$i" 2>&1 & done; wait
ok "1 seven parallel sweeps: six say already running" "$(cat "$TMP"/p1.* | grep -c 'already running')" "6"
ok "1 only one sweep did the work (df calls == one solo run)" "$(grep -c '^df' "$CALLS")" "$((solo_df))"
ok "1 the lock is released afterwards" "$(ls "$OS_LOCK_DIR" 2>/dev/null | grep -c .)" "0"

# ---- 2. seven parallel repo-scoped runs queue instead of piling up
rm -f "$HYGIENE_QUEUE"; : > "$CALLS"
for i in 1 2 3 4 5 6 7; do SHIM_DF_SLEEP=2 H --repo Acme/App > "$TMP/p2.$i" 2>&1 & done; wait
ok "2 six repo runs were queued" "$(cat "$TMP"/p2.* | grep -c 'queued acme/app')" "6"
ok "2 the queue was drained by the running sweep" "$([ -s "$HYGIENE_QUEUE" ] && echo left || echo empty)" "empty"

# ---- 3. --help acts on nothing
mkdir -p "$P/_worktrees/victim__orphan"
for s in workspace-hygiene mac-maintenance post-merge-cleanup anomaly-watch cf-workers-watch drift-watch guest-wedge-watch os-watch sentry-stale-watch world-watch; do
  : > "$CALLS"; out="$(bash "$OPS/$s.sh" --help 2>&1)"; rc=$?
  ok "3 $s --help: exit 0, prints its header, zero shimmed calls" "$rc/$(grep -c . "$CALLS")/$([ -n "$out" ] && echo text)" "0/0/text"
done
ok "3 the orphan dir is untouched" "$([ -d "$P/_worktrees/victim__orphan" ] && echo kept)" "kept"
ok "3 -h works too" "$(H -h 2>&1 | head -1 | grep -c 'Whisky AI OS')" "1"

# ---- 4. unknown flag
: > "$CALLS"; H --bogus >/dev/null 2>&1; rc=$?
ok "4 unknown flag: exit 2, nothing ran" "$rc/$(grep -c . "$CALLS")" "2/0"

# ---- 5. hung du / hung df
rm -rf "$OS_LOCK_DIR"; start=$(date +%s)
out="$(SHIM_DU_SLEEP=100 HYGIENE_DU_TIMEOUT=1 H 2>&1)"; el=$(( $(date +%s) - start ))
ok "5 hung du: sweep still finishes (<40 s)" "$([ "$el" -lt 40 ] && echo fast)" "fast"
ok "5 hung du: the orphan is removed, size shows ?" "$(echo "$out" | grep -c 'victim__orphan (?)')/$([ -d "$P/_worktrees/victim__orphan" ] && echo kept || echo gone)" "1/gone"
mkdir -p "$P/_worktrees/victim__orphan2"; rm -rf "$OS_LOCK_DIR"
out="$(SHIM_DF_SLEEP=100 HYGIENE_DF_TIMEOUT=1 H 2>&1)"
ok "5 hung df: UNKNOWN, dry run, nothing deleted" "$(echo "$out" | grep -q UNKNOWN && echo unknown)/$([ -d "$P/_worktrees/victim__orphan2" ] && echo kept)" "unknown/kept"

# ---- 6. held / stale lock
sleep 30 & holder=$!
for s in anomaly-watch cf-workers-watch drift-watch guest-wedge-watch os-watch sentry-stale-watch world-watch mac-maintenance; do
  rm -rf "$OS_LOCK_DIR"; mkdir -p "$OS_LOCK_DIR/$s"; echo "$holder" > "$OS_LOCK_DIR/$s/pid"
  out="$(bash "$OPS/$s.sh" 2>&1)"; rc=$?
  ok "6 $s: live holder -> already running, exit 0" "$rc/$(echo "$out" | grep -c 'already running')" "0/1"
done
kill "$holder" 2>/dev/null
rm -rf "$OS_LOCK_DIR"; mkdir -p "$OS_LOCK_DIR/workspace-hygiene"; echo 999999 > "$OS_LOCK_DIR/workspace-hygiene/pid"
out="$(H 2>&1)"
ok "6 a dead-pid lock is reclaimed" "$(echo "$out" | grep -c 'already running')" "0"

# ---- 7. mutation: no lock check -> seven sweeps run
mkdir -p "$TMP/mut/ops"; cp -R "$OPS/lib" "$TMP/mut/ops/lib"
sed 's/if ! holder="\$(si_acquire workspace-hygiene 2>&1)"; then/if false; then/' "$OPS/workspace-hygiene.sh" > "$TMP/mut/ops/workspace-hygiene.sh"
if cmp -s "$OPS/workspace-hygiene.sh" "$TMP/mut/ops/workspace-hygiene.sh"; then echo "FAIL: MC mutation did not apply"; fail=$((fail+1)); else
  rm -rf "$OS_LOCK_DIR"
  for i in 1 2 3; do SHIM_DF_SLEEP=1 bash "$TMP/mut/ops/workspace-hygiene.sh" > "$TMP/m.$i" 2>&1 & done; wait
  ok "7 MC without the lock check nobody says already running (test 1 is a real test)" "$(cat "$TMP"/m.* | grep -c 'already running')" "0"
fi
echo; echo "passed=$pass failed=$fail"; [ "$fail" = 0 ]
