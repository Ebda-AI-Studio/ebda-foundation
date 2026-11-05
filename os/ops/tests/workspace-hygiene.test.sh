#!/usr/bin/env bash
# ops/workspace-hygiene.sh — the _worktrees sweep must never delete a business/client CONTAINER dir.
#
# Why: since the 2026-09-25 business-folder layout, new-task-worktree.sh nests worktrees
# (_worktrees/Whisky-11/clients/work-wise/work-wise-app__feat-x). The sweep only looked one level down,
# saw _worktrees/Whisky-11 (no .git of its own), called it an orphan and rm -rf'd it — twice
# (2026-09-27, 2026-09-28), with live worktrees holding unpushed commits inside.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
pass=0; fail=0
ok(){ if [ "$2" = "$3" ]; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1 — got '$2' want '$3'"; fail=$((fail+1)); fi; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# isolated HOME: the script hardcodes $HOME/Desktop/projects/_worktrees, and os-state's TCC canary
# probes this path (see worktree-cleanup.test.sh for the full story)
export HOME="$TMP/home"
mkdir -p "$HOME/Desktop/projects/Ebda-AI-Studio/internal-projects/ebda-store/.git"
P="$HOME/Desktop/projects"; WT="$P/_worktrees"

# run a COPY of the script with its lib only: no worktree-cleanup.sh, no notify.sh → no side effects
mkdir -p "$TMP/ops"; cp "$HERE/../workspace-hygiene.sh" "$TMP/ops/"; cp -R "$HERE/../lib" "$TMP/ops/lib"

# a real repo with a nested, LIVE worktree carrying an unpushed commit (the case that was destroyed)
git init -q -b main "$P/Whisky-11/clients/acme/app"
git -C "$P/Whisky-11/clients/acme/app" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
mkdir -p "$WT/Whisky-11/clients/acme"
git -C "$P/Whisky-11/clients/acme/app" worktree add -q -b feat/live "$WT/Whisky-11/clients/acme/app__feat-live"
git -C "$WT/Whisky-11/clients/acme/app__feat-live" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "unpushed work"

# genuine orphans: worktree-named dirs with no .git link, one flat and one nested
mkdir -p "$WT/old__gone/junk" "$WT/Personal/projects/x__gone/junk"
# a container that happens to be empty of worktrees
mkdir -p "$WT/Ebda-AI-Studio/internal-projects"

DRY_RUN=0 bash "$TMP/ops/workspace-hygiene.sh" > "$TMP/out.txt" 2>&1
code=$?

ok "script exits 0" "$code" "0"
ok "nested live worktree survives" "$([ -e "$WT/Whisky-11/clients/acme/app__feat-live/.git" ] && echo yes || echo no)" "yes"
ok "its unpushed commit survives" "$(git -C "$WT/Whisky-11/clients/acme/app__feat-live" log -1 --format=%s 2>/dev/null)" "unpushed work"
ok "business container kept" "$([ -d "$WT/Whisky-11" ] && echo yes || echo no)" "yes"
ok "empty container kept" "$([ -d "$WT/Ebda-AI-Studio/internal-projects" ] && echo yes || echo no)" "yes"
ok "flat orphan removed" "$([ -e "$WT/old__gone" ] && echo still || echo gone)" "gone"
ok "nested orphan removed" "$([ -e "$WT/Personal/projects/x__gone" ] && echo still || echo gone)" "gone"
ok "digest names the nested orphan by its path" "$(grep -c 'Personal/projects/x__gone' "$TMP/out.txt")" "1"

# ============ --repo / --skip (fast repo-scoped mode, 2026-10-22) ============
# Why: hooks/post-merge-auto-cleanup.sh fires `--repo <slug> --skip <session worktree>` right after
# `gh pr merge`. It must touch ONLY that repo's merged+clean worktrees, never the session's own tree,
# never an orphan (unattributable), and must not need the network (GIT_ALLOW_PROTOCOL=none makes the
# single fetch fail fast; the ancestor check then uses the pre-seeded origin/main).
export GIT_ALLOW_PROTOCOL=none
export HYGIENE_LIVE_CWDS=""   # deterministic: no real process cwds (lsof) leak into the test
mkrepo() {  # $1=dir $2=owner/repo
  git init -q -b main "$1"
  git -C "$1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  git -C "$1" remote add origin "https://github.com/$2.git"
  git -C "$1" update-ref refs/remotes/origin/main "$(git -C "$1" rev-parse HEAD)"
}
mkdir -p "$P/Whisky-11/internal-projects" "$WT/Whisky-11/internal-projects"
mkrepo "$P/Whisky-11/internal-projects/alpha" acme/alpha
mkrepo "$P/Whisky-11/internal-projects/beta" acme/beta
A="$P/Whisky-11/internal-projects/alpha"; B="$P/Whisky-11/internal-projects/beta"
git -C "$A" worktree add -q -b feat/a1 "$WT/Whisky-11/internal-projects/alpha__feat-a1"
git -C "$A" worktree add -q -b feat/a2 "$WT/Whisky-11/internal-projects/alpha__feat-a2"
git -C "$A" worktree add -q -b feat/a3 "$WT/Whisky-11/internal-projects/alpha__feat-a3"
git -C "$B" worktree add -q -b feat/b1 "$WT/Whisky-11/internal-projects/beta__feat-b1"
# "merged" now means: every commit is in origin/main AND the branch has commits of its own (a 0-ahead branch with none is NEW).
# Give a1/a2/a3/b1 one commit each and advance origin/main to it, as a fast-forward merge would.
land() {  # $1=repo $2=worktree
  echo "$2" > "$2/landed.txt"; git -C "$2" add landed.txt
  git -C "$2" -c user.email=t@t -c user.name=t commit -q -m "work in $(basename "$2")"
  # origin/main <- a merge of its old tip and this branch, so EVERY landed branch stays an ancestor of origin/main
  local old head; old="$(git -C "$1" rev-parse refs/remotes/origin/main)"; head="$(git -C "$2" rev-parse HEAD)"
  git -C "$1" update-ref refs/remotes/origin/main "$(GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t git -C "$1" commit-tree "$head^{tree}" -p "$old" -p "$head" -m merge)"
}
land "$A" "$WT/Whisky-11/internal-projects/alpha__feat-a1"
land "$A" "$WT/Whisky-11/internal-projects/alpha__feat-a2"
land "$A" "$WT/Whisky-11/internal-projects/alpha__feat-a3"
land "$B" "$WT/Whisky-11/internal-projects/beta__feat-b1"
echo wip > "$WT/Whisky-11/internal-projects/alpha__feat-a3/wip.txt"   # dirty: must survive
mkdir -p "$WT/Personal/projects/y__gone/junk"                         # orphan: repo mode must not touch
A1="$WT/Whisky-11/internal-projects/alpha__feat-a1"; A2="$WT/Whisky-11/internal-projects/alpha__feat-a2"
A3="$WT/Whisky-11/internal-projects/alpha__feat-a3"; B1="$WT/Whisky-11/internal-projects/beta__feat-b1"
alive() { [ -e "$1/.git" ] && echo yes || echo no; }

# --skip may point INSIDE the worktree (a session cwd is often a subdir)
mkdir -p "$A2/sub"
DRY_RUN=0 bash "$TMP/ops/workspace-hygiene.sh" --repo Acme/ALPHA --skip "$A2/sub" > "$TMP/repo.txt" 2>&1
ok "--repo: exits 0" "$?" "0"
ok "--repo: merged+clean worktree of that repo removed" "$(alive "$A1")" "no"
ok "--repo: skipped (active session) worktree survives" "$(alive "$A2")" "yes"
ok "--repo: skipped one reported as kept" "$(grep -c 'kept (active session)' "$TMP/repo.txt")" "1"
ok "--repo: dirty worktree of that repo survives" "$(alive "$A3")" "yes"
ok "--repo: other repo's merged worktree untouched" "$(alive "$B1")" "yes"
ok "--repo: orphan dir untouched" "$([ -e "$WT/Personal/projects/y__gone" ] && echo yes || echo no)" "yes"

# a merged+clean tree some live process is standing in (another session, a shell) is never removed
B1P="$(cd "$B1" && pwd -P)"; mkdir -p "$B1/deep"
HYGIENE_LIVE_CWDS="$B1P/deep" DRY_RUN=0 bash "$TMP/ops/workspace-hygiene.sh" > "$TMP/inuse.txt" 2>&1
ok "in use: tree with a live process cwd survives the full sweep" "$(alive "$B1")" "yes"
ok "in use: reported as in use" "$(grep -c 'in use\]' "$TMP/inuse.txt")" "1"
HYGIENE_LIVE_CWDS="${B1P}-other" DRY_RUN=0 bash "$TMP/ops/workspace-hygiene.sh" --repo acme/beta > /dev/null 2>&1
ok "in use: a sibling path with the same prefix does not protect it" "$(alive "$B1")" "no"
git -C "$B" worktree add -q -b feat/b1 "$B1" 2>/dev/null || git -C "$B" worktree add -q "$B1" feat/b1

# default mode afterwards: unchanged behaviour — removes every merged+clean tree and the orphan
DRY_RUN=0 bash "$TMP/ops/workspace-hygiene.sh" > "$TMP/def.txt" 2>&1
ok "default: previously-skipped worktree now removed" "$(alive "$A2")" "no"
ok "default: other repo's merged worktree removed" "$(alive "$B1")" "no"
ok "default: dirty worktree still survives" "$(alive "$A3")" "yes"
ok "default: orphan removed" "$([ -e "$WT/Personal/projects/y__gone" ] && echo yes || echo no)" "no"
ok "default: no kept line without --skip" "$(grep -c 'kept (active session)' "$TMP/def.txt")" "0"


# ============ 2026-10-25: a NEW worktree is never "merged" (ebda-whatsapp lost an uncommitted plan) ============
# gh stub via the HYGIENE_GH seam: prints the head oids listed in $TMP/merged-prs for "--head <branch>"
cat > "$TMP/gh-stub" <<GH
#!/bin/sh
br=""; while [ \$# -gt 0 ]; do [ "\$1" = "--head" ] && br="\$2"; shift; done
[ -f "$TMP/merged-prs" ] && awk -v b="\$br" '\$1==b {print \$2}' "$TMP/merged-prs"
exit 0
GH
chmod +x "$TMP/gh-stub"; : > "$TMP/merged-prs"; export HYGIENE_GH="$TMP/gh-stub"
mkrepo "$P/Whisky-11/internal-projects/gamma" acme/gamma
G="$P/Whisky-11/internal-projects/gamma"; GW="$WT/Whisky-11/internal-projects"
git -C "$G" worktree add -q -b feat/new-dirty  "$GW/gamma__feat-new-dirty"
git -C "$G" worktree add -q -b feat/new-clean  "$GW/gamma__feat-new-clean"
git -C "$G" worktree add -q -b feat/squashed   "$GW/gamma__feat-squashed"
git -C "$G" worktree add -q -b feat/ignored    "$GW/gamma__feat-ignored"
git -C "$G" worktree add -q -b feat/merged-untracked "$GW/gamma__feat-merged-untracked"
echo "plan draft" > "$GW/gamma__feat-new-dirty/plan.md"                     # the lost file: untracked, brand-new tree
land_pr() {  # a squash-merged PR: commit NOT in origin/main, but the PR head == the branch tip
  echo x > "$2/x.txt"; git -C "$2" add x.txt; git -C "$2" -c user.email=t@t -c user.name=t commit -q -m "pr work"
  printf '%s %s\n' "$1" "$(git -C "$2" rev-parse HEAD)" >> "$TMP/merged-prs"
}
land_pr feat/squashed "$GW/gamma__feat-squashed"
land_pr feat/ignored  "$GW/gamma__feat-ignored"
land_pr feat/merged-untracked "$GW/gamma__feat-merged-untracked"
mkdir -p "$GW/gamma__feat-merged-untracked/docs/plans"; echo draft2 > "$GW/gamma__feat-merged-untracked/docs/plans/draft.md"   # untracked file inside a NEW directory
printf 'secrets.local.json\n' > "$GW/gamma__feat-ignored/.git-info-exclude-test" && git -C "$GW/gamma__feat-ignored" rev-parse --git-path info/exclude >/dev/null
echo 'notes-draft.md' >> "$(git -C "$GW/gamma__feat-ignored" rev-parse --git-path info/exclude)"
rm -f "$GW/gamma__feat-ignored/.git-info-exclude-test"
echo "draft" > "$GW/gamma__feat-ignored/notes-draft.md"                     # ignored but NOT junk
mkdir -p "$GW/gamma__feat-ignored/node_modules"; echo j > "$GW/gamma__feat-ignored/node_modules/j"  # ignored junk would be fine alone
echo 'node_modules' >> "$(git -C "$GW/gamma__feat-ignored" rev-parse --git-path info/exclude)"
alive() { [ -e "$1/.git" ] && echo yes || echo no; }

DRY_RUN=0 bash "$TMP/ops/workspace-hygiene.sh" --repo acme/gamma > "$TMP/gamma.txt" 2>&1
ok "NEW: a fresh 0-ahead worktree holding an untracked file is KEPT (and the file survives)" "$(alive "$GW/gamma__feat-new-dirty"):$(cat "$GW/gamma__feat-new-dirty/plan.md" 2>/dev/null)" "yes:plan draft"
ok "NEW: a fresh 0-ahead worktree with no PR and a clean tree is KEPT (0 ahead is new, not merged)" "$(alive "$GW/gamma__feat-new-clean")" "yes"
ok "merged PR + an untracked file inside a new directory -> KEPT (every untracked file counts, not just the dir)" "$(alive "$GW/gamma__feat-merged-untracked"):$(cat "$GW/gamma__feat-merged-untracked/docs/plans/draft.md" 2>/dev/null)" "yes:draft2"
ok "squash-merged PR at this exact tip + clean -> removed" "$(alive "$GW/gamma__feat-squashed")" "no"
ok "merged PR + an ignored NON-junk file (notes-draft.md) -> KEPT, the file survives" "$(alive "$GW/gamma__feat-ignored"):$(cat "$GW/gamma__feat-ignored/notes-draft.md" 2>/dev/null)" "yes:draft"

# a file written AFTER the dirty check but before removal must survive: removal is not forced
git -C "$G" worktree add -q -b feat/race "$GW/gamma__feat-race"; echo y > "$GW/gamma__feat-race/y.txt"
git -C "$GW/gamma__feat-race" add y.txt; git -C "$GW/gamma__feat-race" -c user.email=t@t -c user.name=t commit -q -m race
printf 'feat/race %s\n' "$(git -C "$GW/gamma__feat-race" rev-parse HEAD)" >> "$TMP/merged-prs"
cp -R "$TMP/ops" "$TMP/ops-race"
# the sweep's removal step runs `git worktree remove` (no --force): simulate the late write by an untracked file the
# check already passed over -> git must refuse
echo late > "$GW/gamma__feat-race/late-draft.md"
git -C "$G" worktree remove "$GW/gamma__feat-race" >/dev/null 2>&1
ok "race: plain 'git worktree remove' refuses a tree that gained an untracked file (no --force anywhere in the reapers)" "$(alive "$GW/gamma__feat-race")" "yes"
ok "no reaper passes --force to git worktree remove" "$(grep -n 'worktree remove .*--force\|worktree remove --force' "$HERE/../workspace-hygiene.sh" "$HERE/../post-merge-cleanup.sh" "$HERE/../worktree-cleanup.sh" | grep -vc '^[^:]*:[0-9]*:\s*#')" "0"

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
