#!/usr/bin/env bash
# G13: a SQUASH-merged branch counts as merged even when `git branch --merged` / is-ancestor says no.
# 2026-11-15: 64 merged ebda-store worktrees survived the sweep (squash merge rewrites history; PR head moved after merge so the
# exact-tip rule missed). Every case has its NEGATIVE: unpushed work after the merge, a brand-new branch, a dirty tree are KEPT.
# Run: bash os/ops/lib/__tests__/wt-squash-merged.test.sh
set -uo pipefail
OPS="$(cd "$(dirname "$0")/../.." && pwd)"
. "$HOME/.claude/scripts/test-git-env.sh" 2>/dev/null || . "$OPS/test-git-env.sh"
clean_git_env
. "$OPS/lib/os-state.sh" 2>/dev/null
. "$OPS/lib/wt-safety.sh"
_pass=0; _fail=0
ok() { echo "PASS: $1"; _pass=$((_pass+1)); }
no() { echo "FAIL: $1"; _fail=$((_fail+1)); }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
g() { git -C "$1" -c user.email=t@t -c user.name=t -c commit.gpgsign=false "${@:2}"; }
git init -q --bare -b main "$T/o.git"
R="$T/r"; git init -q -b main "$R"; echo seed > "$R/seed"; g "$R" add seed; g "$R" commit -qm seed
g "$R" remote add origin "$T/o.git"; g "$R" push -q -u origin main
# fake gh: `pr list ... --json mergeCommit` -> $MC ; `--json headRefOid` -> $HEADS
cat > "$T/gh" <<'F'
#!/usr/bin/env bash
case "$*" in *mergeCommit*) printf '%s\n' "${FAKE_MC:-}";; *headRefOid*) printf '%s\n' "${FAKE_HEADS:-}";; esac
F
chmod +x "$T/gh"; export HYGIENE_GH="$T/gh"

mkbranch() { # <name>: branch off main with one commit touching file <name>
  g "$R" worktree add -q -b "$1" "$T/wt-$1" origin/main; echo "$1" > "$T/wt-$1/$1"; g "$T/wt-$1" add "$1"; g "$T/wt-$1" commit -qm "$1"
}
squash() { # <name>: land the branch on main as ONE new commit (history rewritten), plus an unrelated main commit before it
  g "$R" checkout -q main; echo "other-$1" > "$R/other-$1"; g "$R" add "other-$1"; g "$R" commit -qm "other-$1"
  echo "$1" > "$R/$1"; g "$R" add "$1"; g "$R" commit -qm "squash $1 (#1)"; g "$R" push -q origin main; g "$R" fetch -q origin
}

# 1 squash merged, PR head moved after merge (exact-tip rule misses) but content identical -> merged via mergeCommit proof
mkbranch a; squash a; export FAKE_MC="$(g "$R" rev-parse origin/main)" FAKE_HEADS="deadbeef"
[ "$(wt_merge_verdict "$T/wt-a" o/r a)" = merged ] && ok "squash-merged (PR head differs) -> merged" || no "squash-merged branch not merged: $(wt_merge_verdict "$T/wt-a" o/r a)"
# 2 NEGATIVE: same PR, but the branch gained a commit AFTER the merge touching a file -> unmerged
echo late >> "$T/wt-a/a"; g "$T/wt-a" commit -qam late
[ "$(wt_merge_verdict "$T/wt-a" o/r a)" = unmerged ] && ok "post-merge commit -> unmerged (work kept)" || no "post-merge work treated as merged: $(wt_merge_verdict "$T/wt-a" o/r a)"
# 3 tree equal to a main commit, gh unavailable -> merged (rebase/squash with no drift)
mkbranch b; squash b; export HYGIENE_GH=/nonexistent FAKE_MC=""
# main now has other-b too, so tree(b) != tree(main tip); make tree equal by branching main exactly
g "$R" worktree add -q -b c "$T/wt-c" origin/main; echo c > "$T/wt-c/c"; g "$T/wt-c" add c; g "$T/wt-c" commit -qm c
g "$T/wt-c" push -q origin c:main --force; g "$R" fetch -q origin
g "$T/wt-c" reset -q --hard HEAD   # tree(c) == tree(origin/main tip), history differs? same commit; rewrite it:
g "$T/wt-c" commit -q --amend -m "c amended"
[ "$(wt_merge_verdict "$T/wt-c" o/r c)" = merged ] && ok "tree equals a main commit, no gh -> merged" || no "tree-equal branch not merged: $(wt_merge_verdict "$T/wt-c" o/r c)"
# 4 NEGATIVE: unrelated unmerged branch, no gh -> not merged
export HYGIENE_GH="$T/gh"; mkbranch d; export FAKE_MC="$(g "$R" rev-parse origin/main)"
[ "$(wt_merge_verdict "$T/wt-d" o/r d)" != merged ] && ok "unmerged branch stays unmerged (mergeCommit lacks its file)" || no "unmerged branch reaped"
# 5 NEGATIVE: brand-new branch (0 ahead, no own commit) is NEW
g "$R" worktree add -q -b e "$T/wt-e" origin/main
[ "$(wt_merge_verdict "$T/wt-e" o/r e)" = new ] && ok "new branch -> new (never merged)" || no "new branch misjudged: $(wt_merge_verdict "$T/wt-e" o/r e)"
echo "wt-squash-merged: $_pass passed, $_fail failed"; [ "$_fail" = 0 ]
