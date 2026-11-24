#!/usr/bin/env bash
# ops/relabel-after-review.sh against a stubbed gh: relabels only on a clean review CONCLUSION at the current head.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RL="$ROOT/os/ops/relabel-after-review.sh"
p=0; f=0
ok() { echo "PASS: $1"; p=$((p+1)); }
no() { echo "FAIL: $1"; f=$((f+1)); }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"; export PATH="$T/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export RUNS_FILE="$T/runs.json" CALLS="$T/calls" HEAD_FILE="$T/head" RELABEL_GAP=0
cat > "$T/bin/gh" <<'STUB'
#!/bin/bash
echo "$*" >> "$CALLS"
case "$1 $2" in
  "pr view") cat "$HEAD_FILE" ;;
  "run list") cat "$RUNS_FILE" ;;
  "pr edit") exit 0 ;;
esac
STUB
chmod +x "$T/bin/gh"
run1() { echo "{\"headSha\":\"$1\",\"status\":\"$2\",\"conclusion\":\"$3\"}"; }
runs() { { echo '['; local first=1; for j in "$@"; do [ "$first" = 1 ] || echo ','; echo "$j"; first=0; done; echo ']'; } > "$RUNS_FILE"; }
go() { : > "$CALLS"; echo "${HEADSHA:-h1}" > "$HEAD_FILE"; bash "$RL" --repo o/r --interval 0 --max-polls 2 "$@" 2>&1; }
added() { grep -q -- '--add-label ai-review-passed' "$CALLS"; }

runs "$(run1 h1 completed success)"; out="$(go 7)"; rc=$?
[ $rc = 0 ] && added && grep -q -- '--remove-label ai-review-passed' "$CALLS" && ok "clean success at head: relabelled (remove then add)" || no "not relabelled ($out)"
runs "$(run1 h1 completed failure)"; out="$(go 7)"; rc=$?
[ $rc = 1 ] && ! added && ok "completed but FAILED review: NOT relabelled" || no "relabelled after a failed review (rc=$rc)"
for bad in cancelled timed_out action_required startup_failure; do
  runs "$(run1 h1 completed success)" "$(run1 h1 completed $bad)"; go 7 >/dev/null; rc=$?
  [ $rc = 1 ] && ! added && ok "success + $bad on the same head: NOT relabelled" || no "relabelled with a $bad run (rc=$rc)"
done
runs "$(run1 h1 completed skipped)"; go 7 >/dev/null; rc=$?; [ $rc = 1 ] && ! added && ok "no success run (skipped only): NOT relabelled" || no "relabelled without a success"
runs "$(run1 h1 in_progress '')"; go 7 >/dev/null; rc=$?; [ $rc = 1 ] && ! added && ok "review still running past --max-polls: NOT relabelled" || no "relabelled while running"
runs; go 7 >/dev/null; rc=$?; [ $rc = 1 ] && ! added && ok "no review run at all: NOT relabelled" || no "relabelled with no review"
runs "$(run1 old completed success)"; go 7 >/dev/null; rc=$?; [ $rc = 1 ] && ! added && ok "success on another sha does not count" || no "old-head success counted"
runs "$(run1 h1 completed success)"; : > "$CALLS"; echo h1 > "$HEAD_FILE"
cat > "$T/bin/gh" <<'STUB'
#!/bin/bash
echo "$*" >> "$CALLS"
case "$1 $2" in
  "pr view") n=$(grep -c '^pr view' "$CALLS"); if [ "$n" -ge 2 ]; then echo h2; else echo h1; fi ;;
  "run list") cat "$RUNS_FILE" ;;
esac
STUB
bash "$RL" --repo o/r --interval 0 --max-polls 2 7 >/dev/null 2>&1; rc=$?; [ $rc = 1 ] && ! added && ok "head moved while waiting: NOT relabelled" || no "relabelled after the head moved (rc=$rc)"
bash "$RL" --repo o/r >/dev/null 2>&1; [ $? = 2 ] && ok "no PR number exits 2" || no "missing PR accepted"
bash "$RL" --repo o/r "7 8" >/dev/null 2>&1; [ $? = 2 ] && ok "quoted list exits 2" || no "quoted list accepted"
bash "$RL" 7 >/dev/null 2>&1; [ $? = 2 ] && ok "no --repo exits 2" || no "missing --repo accepted"
echo "relabel-after-review: $p passed, $f failed"; [ "$f" = 0 ]
