#!/usr/bin/env bash
# ops/worktree-cleanup.sh — covers every repo that HAS worktrees, respects each
# repo's own default branch, and removes a worktree only when it is merged, clean
# and cold.
#
# Why these cases: on 2026-09-23 the script carried a hardcoded four-repo list
# while seventeen repos had worktrees, assumed `main` everywhere (ebda-foundation
# uses `master`), and never removed a worktree at all.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../worktree-cleanup.sh"
pass=0; fail=0
ok(){ if [ "$2" = "$3" ]; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1 — got '$2' want '$3'"; fail=$((fail+1)); fi; }
has(){ if grep -q "$3" <<<"$2"; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1 — output lacked '$3'"; fail=$((fail+1)); fi; }
hasnt(){ if grep -q "$3" <<<"$2"; then echo "FAIL: $1 — output contained '$3'"; fail=$((fail+1)); else echo "PASS: $1"; pass=$((pass+1)); fi; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export PROJECTS_DIR="$TMP/projects" WORKTREES_DIR="$TMP/projects/_worktrees"
mkdir -p "$PROJECTS_DIR" "$WORKTREES_DIR"

# Isolate HOME. `os-state.sh`'s `require_projects_access` is a macOS TCC canary
# that probes a HARDCODED `$HOME/Desktop/projects/Ebda-AI-Studio/internal-projects/ebda-store/.git`,
# independently of the PROJECTS_DIR this test points the script at. On Linux CI
# that path does not exist, so the canary returned 1 and worktree-cleanup.sh
# took its `|| exit 0` branch: it did nothing, printed nothing, and exited 0.
# Every assertion here then failed for one reason — INCLUDING the empty-layout
# positive control, which reported exit 0 instead of 1 and so could not tell
# "discovered nothing" from "never ran". That is why this suite passed on macOS
# (where the real canary path exists) and failed 10/15 on CI.
#
# Giving the fixture its own HOME satisfies the canary without touching the
# shared guard 24 ops scripts depend on, and keeps anything os-state writes
# (`~/.whisky-os-state/`) inside the temp dir instead of the developer's real one.
export HOME="$TMP/home"
mkdir -p "$HOME/Desktop/projects/Ebda-AI-Studio/internal-projects/ebda-store/.git"

# mkrepo <name> <default-branch>
mkrepo() {
  local name="$1" def="$2" root="$PROJECTS_DIR/Ebda-AI-Studio/internal-projects/$1" bare="$TMP/origin-$1.git"
  git init -q --bare -b "$def" "$bare"
  git init -q -b "$def" "$root"
  git -C "$root" config user.email t@t; git -C "$root" config user.name t
  echo seed > "$root/f"; git -C "$root" add f; git -C "$root" commit -qm seed
  git -C "$root" remote add origin "$bare"; git -C "$root" push -q -u origin "$def"
  git -C "$root" remote set-head origin "$def" >/dev/null 2>&1
}
# mkworktree <repo> <branch> <merged:yes|no>
mkworktree() {
  local root="$PROJECTS_DIR/Ebda-AI-Studio/internal-projects/$1" br="$2" merged="$3" def wt
  def="$(git -C "$root" rev-parse --abbrev-ref HEAD)"
  wt="$WORKTREES_DIR/$1__$(printf '%s' "$br" | tr '/' '-')"
  git -C "$root" fetch -q origin "$def"
  # Base every branch on the CURRENT origin tip, so "merged" branches really do
  # fast-forward the default branch (an older base is rejected non-fast-forward
  # and the branch is then NOT an ancestor — which silently skipped two cases).
  git -C "$root" worktree add -q -b "$br" "$wt" "origin/$def" >/dev/null 2>&1
  echo "$br" > "$wt/w"; git -C "$wt" add w; git -C "$wt" commit -qm "$br"
  if [ "$merged" = yes ]; then
    git -C "$root" push -q origin "$br:$def"        # branch is now an ancestor of origin/<def>
    git -C "$root" fetch -q origin "$def"
  fi
  printf '%s' "$wt"
}
age() { touch -t 202601010000 "$1"; }   # make a worktree cold

# --- repos the old hardcoded list never covered, one on master ---------------
mkrepo alpha-service main
mkrepo legacy-tool  master

wt_merged_cold=$(mkworktree alpha-service feat/merged-cold yes); age "$wt_merged_cold"
wt_merged_dirty=$(mkworktree alpha-service feat/merged-dirty yes); echo dirt > "$wt_merged_dirty/untracked"; age "$wt_merged_dirty"
wt_merged_fresh=$(mkworktree alpha-service feat/merged-fresh yes)          # left fresh on purpose
wt_unmerged=$(mkworktree alpha-service feat/unmerged no); age "$wt_unmerged"
wt_master=$(mkworktree legacy-tool fix/on-master yes); age "$wt_master"
# Squash-merged PRs (2026-09-25): the branch is NOT an ancestor of main, so the
# ancestor gate kept them forever — "removed=0" on a machine full of merged work.
# A stub `gh` reports a MERGED PR whose head is the branch tip -> removable; a
# branch that gained a commit AFTER its PR merged must survive (unpushed work).
wt_squashed=$(mkworktree alpha-service feat/squashed no); age "$wt_squashed"
wt_after=$(mkworktree alpha-service feat/squashed-then-more no)
merged_head_after="$(git -C "$wt_after" rev-parse HEAD)"
echo more > "$wt_after/more"; git -C "$wt_after" add more; git -C "$wt_after" commit -qm more; age "$wt_after"
mkdir -p "$TMP/bin"; cat > "$TMP/bin/gh" <<GH
#!/bin/sh
case "\$*" in
  *"--head feat/squashed-then-more"*"--state merged"*) echo "$merged_head_after" ;;
  *"--head feat/squashed"*"--state merged"*) git -C "$wt_squashed" rev-parse HEAD ;;
esac
exit 0
GH
chmod +x "$TMP/bin/gh"; export PATH="$TMP/bin:$PATH"

out="$(bash "$SCRIPT" 2>&1)"; rc=$?
has  "removes a squash-merged worktree (merged PR head == tip)" "$out" "removed merged worktree: feat/squashed$"
ok   "squash-merged worktree dir is gone"            "$([ -d "$wt_squashed" ] && echo present || echo gone)" "gone"
hasnt "keeps a branch with commits after its PR merged" "$out" "removed merged worktree: feat/squashed-then-more"
ok   "post-merge-work worktree survives"             "$([ -d "$wt_after" ] && echo present || echo gone)" "present"

ok   "exits 0 when repos are found"                 "$rc" "0"
has  "discovers a repo that was never in any list"  "$out" "=== alpha-service"
has  "discovers a master-default repo too"          "$out" "=== legacy-tool (default: master)"
has  "removes a merged, clean, cold worktree"       "$out" "removed merged worktree: feat/merged-cold"
has  "removes it in a master-default repo as well"  "$out" "removed merged worktree: fix/on-master"
has  "keeps a merged worktree with local changes"   "$out" "kept (uncommitted changes): feat/merged-dirty"
has  "keeps a merged worktree touched just now"     "$out" "kept (touched"
hasnt "never removes an unmerged worktree"          "$out" "removed merged worktree: feat/unmerged"
ok   "merged+clean+cold worktree dir is gone"       "$([ -d "$wt_merged_cold" ] && echo present || echo gone)" "gone"
ok   "dirty worktree survives"                      "$([ -d "$wt_merged_dirty" ] && echo present || echo gone)" "present"
ok   "fresh worktree survives"                      "$([ -d "$wt_merged_fresh" ] && echo present || echo gone)" "present"
ok   "unmerged worktree survives"                   "$([ -d "$wt_unmerged" ] && echo present || echo gone)" "present"
has  "reports coverage counts"                      "$out" "scanned=2 repos"

# --- positive control: discovering nothing must FAIL, not report success -----
export PROJECTS_DIR="$TMP/empty" WORKTREES_DIR="$TMP/empty/_worktrees"; mkdir -p "$WORKTREES_DIR"
out2="$(bash "$SCRIPT" 2>&1)"; rc2=$?
ok  "empty layout exits non-zero"                   "$rc2" "1"
has "empty layout says so instead of 'done.'"       "$out2" "discovered ZERO repos"

echo "---- $pass passed, $fail failed"
[ "$fail" -eq 0 ]
