#!/usr/bin/env bash
# new-task-worktree.sh must leave a NEW branch one commit ahead (empty start commit): a 0-ahead branch is
# indistinguishable from "merged" by ancestry, and the 2026-10-25 sweep deleted such a worktree with a plan in it.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; OPS="$HERE/.."
pass=0; fail=0
ok(){ if [ "$2" = "$3" ]; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1 - got '$2' want '$3'"; fail=$((fail+1)); fi; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"; export PROJECTS_ROOT="$HOME/Desktop/projects"
export OS_SSD_ROOT="$TMP/no-ssd"   # never touch the real /Volumes/Ebda (lib/wt-roots.sh)
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
git init -q --bare -b main "$TMP/origin.git"
R="$PROJECTS_ROOT/Whisky-11/internal-projects/demo"; mkdir -p "$R"
git -C "$R" init -q -b main; git -C "$R" config user.email t@example.invalid; git -C "$R" config user.name t
git -C "$R" remote add origin "$TMP/origin.git"; echo a > "$R/a"; git -C "$R" add a; git -C "$R" commit -q -m init; git -C "$R" push -q origin main
git -C "$R" fetch -q; git -C "$R" remote set-head origin main >/dev/null 2>&1
WT_MIN_FREE_GB=0 WT_SKIP_DEPS=1 bash "$OPS/new-task-worktree.sh" demo feat/x >"$TMP/out" 2>&1
WT="$PROJECTS_ROOT/_worktrees/demo__feat-x"
ok "worktree created" "$([ -d "$WT" ] && echo yes || echo no)" "yes"
ok "new branch is 1 commit ahead of origin/main" "$(git -C "$WT" rev-list --count origin/main..HEAD)" "1"
ok "that commit is empty (no file changes)" "$(git -C "$WT" diff --name-only HEAD~1 HEAD | wc -l | tr -d ' ')" "0"
ok "message names the branch" "$(git -C "$WT" log -1 --format=%s)" "chore: start feat/x"
# resuming an EXISTING branch must not add another empty commit
git -C "$R" worktree remove --force "$WT"
WT_MIN_FREE_GB=0 WT_SKIP_DEPS=1 bash "$OPS/new-task-worktree.sh" demo feat/x >"$TMP/out2" 2>&1
ok "resume of an existing branch adds no extra commit" "$(git -C "$WT" rev-list --count origin/main..HEAD)" "1"
# the disk-floor REFUSAL must be cheap: df only, no du scan (a du over _worktrees took 5+ minutes on a loaded host, 2026-10-25)
mkdir -p "$TMP/bin"; printf '#!/bin/sh\necho "$@" >> "%s/du.calls"\nexit 0\n' "$TMP" > "$TMP/bin/du"; chmod +x "$TMP/bin/du"
: > "$TMP/du.calls"
PATH="$TMP/bin:$PATH" WT_MIN_FREE_GB=999999 WT_SKIP_DEPS=1 bash "$OPS/new-task-worktree.sh" demo feat/refused >"$TMP/out3" 2>&1; rc=$?
ok "below the free-space floor the script refuses (exit 3)" "$rc" "3"
ok "the refusal ran NO du scan" "$(grep -c . "$TMP/du.calls")" "0"
ok "the refusal says how to get the breakdown" "$(grep -c 'WT_REPORT=1' "$TMP/out3")" "1"
ok "no worktree was created by the refused call" "$([ -d "$PROJECTS_ROOT/_worktrees/demo__feat-refused" ] && echo yes || echo no)" "no"
PATH="$TMP/bin:$PATH" WT_REPORT=1 WT_MIN_FREE_GB=999999 WT_SKIP_DEPS=1 bash "$OPS/new-task-worktree.sh" demo feat/refused >"$TMP/out4" 2>&1
ok "WT_REPORT=1 still gives the du breakdown on request" "$([ "$(grep -c . "$TMP/du.calls")" -ge 1 ] && echo yes || echo no)" "yes"
echo "---"; echo "new-task-worktree: $pass passed, $fail failed"; [ "$fail" = 0 ]
