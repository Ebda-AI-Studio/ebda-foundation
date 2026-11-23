#!/usr/bin/env bash
# git-hooks/dispatch.sh root-checkout guard: pre-commit + pre-merge-commit refuse in a repo's MAIN checkout on main
# under a business-folder slot; linked worktrees, ff merges, outside-slot repos and the escape hatch stay allowed.
# Fully isolated: temp HOME + projects dir, hooks installed as symlinks in a temp dir (nothing touches ~/.claude).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; OPS="$HERE/.."
# shellcheck source=/dev/null
. "$OPS/test-git-env.sh"
clean_git_env
pass=0; fail=0
ok(){ if [ "$2" = "$3" ]; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1 - got '$2' want '$3'"; fail=$((fail+1)); fi; }
TMP="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"
P="$HOME/Desktop/projects"; export OS_PROJECTS_DIR="$P"
HK="$TMP/hooks"; mkdir -p "$HK"; cp "$OPS/git-hooks/dispatch.sh" "$HK/dispatch.sh"
for h in pre-commit pre-merge-commit post-merge; do ln -s dispatch.sh "$HK/$h"; done
export ROOT_GUARD_BIN="$OPS/root-checkout-guard.sh"
LOG="$HOME/Library/Logs/root-commit-guard.log"

mkrepo() { # <dir>: repo with origin, one commit on main, global-style hooksPath
  local d="$1" o="$1.origin.git"
  git init -q --bare "$o"; mkdir -p "$d"
  sandbox_git_init "$d"
  sandbox_git "$d" checkout -q -b main
  echo a > "$d/a"; sandbox_git "$d" add a; sandbox_git "$d" commit -q -m init
  sandbox_git "$d" remote add origin "$o"; sandbox_git "$d" push -q origin main
  sandbox_git "$d" fetch -q origin
  sandbox_git "$d" config core.hooksPath "$HK"
}
g() { local d="$1"; shift; ( cd "$d" && env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 "$@" ) ; }
commit() { echo "$RANDOM" > "$1/f"; g "$1" git add f >/dev/null; g "$1" git commit -q -m x "${@:2}" 2>&1; }

IN="$P/Ebda-AI-Studio/internal-projects/r1"; mkrepo "$IN"
CL="$P/Force-AI/clients/acme/r2"; mkrepo "$CL"
OUT="$P/Personal/elsewhere/r3"; mkrepo "$OUT"
# the hooksPath config must not itself trip anything while setting up; start clean logs
rm -f "$LOG"

out="$(commit "$IN")"; rc=$?
ok "main checkout on main under internal-projects: commit refused" "$rc" "1"
case "$out" in *new-task-worktree.sh*) ok "refusal names the worktree script" 1 1 ;; *) ok "refusal names the worktree script" "$out" "mentions it" ;; esac
commit "$CL" >/dev/null; ok "clients slot: commit refused" "$?" "1"
commit "$OUT" >/dev/null; ok "repo outside the slots: commit allowed" "$?" "0"

g "$IN" git checkout -q -b feat/x; commit "$IN" >/dev/null; ok "main checkout on a feature branch: allowed" "$?" "0"
g "$IN" git checkout -q main

# linked worktree on a branch AND on a main-named branch: allowed (git-dir != common-dir)
WT="$TMP/wt"; g "$IN" git worktree add -q -b feat/wt "$WT" >/dev/null 2>&1
commit "$WT" >/dev/null; ok "linked worktree: commit allowed" "$?" "0"
WT2="$TMP/wt2"; g "$IN" git worktree add -q -b main2 "$WT2" >/dev/null 2>&1; g "$WT2" git checkout -q -b master >/dev/null 2>&1
commit "$WT2" >/dev/null; ok "linked worktree on master: allowed" "$?" "0"

# merges in the root: non-ff refused, ff allowed
g "$IN" git checkout -q -b side; echo s > "$IN/s"; g "$IN" git add s; EBDA_ALLOW_ROOT_COMMIT=1 g "$IN" git commit -q -m side
g "$IN" git checkout -q main
before="$(g "$IN" git rev-parse main)"
g "$IN" git merge --no-ff -q -m m side >/dev/null 2>&1; ok "non-ff merge on root main: refused (pre-merge-commit)" "$?" "1"
ok "refused merge left main where it was" "$(g "$IN" git rev-parse main)" "$before"
g "$IN" git merge --abort >/dev/null 2>&1
g "$IN" git reset -q --hard origin/main
# advance origin (via a clone) then ff root main from origin/main
CLN="$TMP/clone"; git clone -q -b main "$IN.origin.git" "$CLN"; echo o > "$CLN/o"; sandbox_git "$CLN" add o; sandbox_git "$CLN" commit -q -m up; sandbox_git "$CLN" push -q origin main
g "$IN" git fetch -q origin
g "$IN" git merge --ff-only -q origin/main >/dev/null 2>&1; ok "ff merge of origin/main on root main: allowed" "$?" "0"
ok "ff merge actually advanced root main past the old tip" "$([ "$(g "$IN" git rev-parse main)" != "$before" ] && echo moved)" "moved"
ok "ff merge landed on origin/main" "$(g "$IN" git rev-parse main)" "$(g "$IN" git rev-parse origin/main)"
# ff of a LOCAL unpushed branch moves main ahead of origin: not refused (documented), but warned post-merge
g "$IN" git checkout -q -b side2; echo t > "$IN/t"; g "$IN" git add t; EBDA_ALLOW_ROOT_COMMIT=1 g "$IN" git commit -q -m side2; g "$IN" git checkout -q main
w="$(g "$IN" git merge --ff-only side2 2>&1)"; rc=$?
ok "ff merge of a local branch: not refused" "$rc" "0"
case "$w" in *"AHEAD of origin"*) ok "post-merge warns that root main is ahead of origin" 1 1 ;; *) ok "post-merge warns that root main is ahead of origin" "$w" "warning" ;; esac
g "$IN" git reset -q --hard origin/main

# escape hatch: allowed and logged
ok "no log before any override" "$([ -e "$LOG" ] && echo present || echo absent)" "absent"
EBDA_ALLOW_ROOT_COMMIT=1 commit "$IN" >/dev/null; ok "escape hatch: commit allowed" "$?" "0"
ok "escape hatch use is logged" "$(grep -c 'pre-commit ALLOWED via EBDA_ALLOW_ROOT_COMMIT=1' "$LOG" 2>/dev/null)" "1"

# a repo-local hook still chains when the guard passes (and is skipped when it refuses)
printf '#!/bin/sh\necho chained >> "%s/chain.out"\n' "$TMP" > "$OUT/.git/hooks/pre-commit"; chmod +x "$OUT/.git/hooks/pre-commit"
commit "$OUT" >/dev/null; ok "local hook chained for an allowed commit" "$(grep -c chained "$TMP/chain.out" 2>/dev/null)" "1"

echo "== $pass passed, $fail failed"
[ "$fail" = 0 ]
