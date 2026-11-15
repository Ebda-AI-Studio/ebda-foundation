# shellcheck shell=bash
# ops/lib/wt-safety.sh — the two questions every worktree reaper must answer the SAME way before it deletes anything.
#
# WHY (2026-10-25). The post-merge sweep after a merge in $OS_ORG/ebda-whatsapp deleted a brand-new worktree whose
# branch sat exactly at origin/main with zero commits, and with it an UNCOMMITTED plan draft. Three defects met:
#   1. "merged" was `git merge-base --is-ancestor HEAD origin/main`. A branch with 0 commits ahead of main IS an
#      ancestor of main, so every freshly created worktree counted as merged. 0-ahead means NEW, not merged.
#   2. The dirty check ran once, long before the removal, and the removal used `--force`. A session that writes a
#      file in between (an agent has no process cwd for lsof to see) loses it. Without --force, git itself refuses to
#      remove a tree holding modified or untracked files, atomically at removal time.
#   3. Ignored-but-not-junk files (anything gitignored that is not a rebuildable artefact) were invisible to
#      `git status --porcelain`.
#
# wt_dirty_count <wt>                      -> number of files that would be lost: modified, untracked (EVERY untracked
#                                             file, not just the directory), and ignored files that are not junk
# wt_merge_verdict <wt> <owner/repo> <br>  -> merged | new | unmerged | unknown
#     merged   a MERGED PR for this branch whose head commit is EXACTLY this worktree's HEAD
#     new      HEAD has no commit beyond origin/<default> and no merged PR at this tip (just created: KEEP)
#     unmerged commits not in main and no merged PR at this tip (work in flight: KEEP)
#     unknown  GitHub could not be asked (offline, no gh): KEEP
# Only `merged` may ever lead to removal.

# shellcheck source=os-config.sh
command -v os_config_load >/dev/null 2>&1 || . "$(dirname "${BASH_SOURCE[0]}")/os-config.sh" 2>/dev/null || true
[ -n "${OS_ORG:-}" ] || ! command -v os_config_load >/dev/null 2>&1 || os_config_load
WT_JUNK_RE='(^|/)(node_modules|dist|build|out|coverage|\.next|\.open-next|\.turbo|\.wrangler|\.vite|\.cache|\.parcel-cache|__pycache__|\.pytest_cache|\.vercel|target|\.tmp|tmp|graphify-out|\.generated|\.husky/_)(/|$)|(^|/)\.DS_Store$|\.(log|tsbuildinfo|pyc)$|(^|/)\.env(\.[A-Za-z0-9_-]+)?$'

wt_dirty_count() {
  local wt="$1" n i
  n=$(git -C "$wt" status --porcelain --untracked-files=all 2>/dev/null | wc -l | tr -d ' ')
  i=$(git -C "$wt" status --porcelain --ignored=matching --untracked-files=all 2>/dev/null \
        | sed -n 's/^!! //p' | grep -Ev "$WT_JUNK_RE" | wc -l | tr -d ' ')
  echo $(( ${n:-0} + ${i:-0} ))
}

# branch_has_own_commits <git-dir-or-worktree> <branch>: the branch's reflog records at least one commit/merge/rebase
# of its own. A worktree created with `git worktree add -b x origin/main` has ONLY a "branch: Created from" entry, so it
# is NEW even though its HEAD is an ancestor of main. No reflog = treated as having none (keep).
branch_has_own_commits() {
  # capture first, then grep a here-string: `git | grep -q` under `set -o pipefail` reports failure when grep closes the pipe early (SIGPIPE)
  local log; log=$(git -C "$1" reflog show --format=%gs "refs/heads/$2" 2>/dev/null) || return 1
  grep -qE '^(commit|rebase|cherry-pick|merge|revert|am|pull|reset: moving to [0-9a-f]{7,})' <<<"$log"
}

# wt_squash_integrated <wt> <owner/repo> <br> [<default-ref> [<rev>]]: 0 when every change this branch made is ALREADY in main although
# `git branch --merged`/is-ancestor says no (squash or rebase merge rewrites history). Two independent proofs, each content-based so a
# branch that gained commits after its PR merged is never reported as integrated (G13, 2026-11-15: 64 merged ebda-store worktrees
# survived because the PR head moved after merge, e.g. update-branch or a follow-up commit, so the exact-tip rule never matched):
#   1. TREE: HEAD's tree equals the tree of a recent commit on <default-ref> (the squash commit reproduced the branch exactly).
#   2. PR:   a MERGED PR for the branch has a mergeCommit in the object store, and every file the branch changed (vs the merge-base)
#            is byte-identical between HEAD and that mergeCommit. Zero changed files proves nothing -> not integrated.
wt_squash_integrated() {
  local wt="$1" slug="$2" br="$3" def="${4:-origin/main}" rev="${5:-HEAD}" tree trees base files mc gh_bin
  gh_bin="${HYGIENE_GH:-gh}"
  git -C "$wt" rev-parse --verify -q "$def" >/dev/null 2>&1 || return 1
  # NEW-branch guard (2026-10-25 incident): a branch with nothing beyond main, or no commit of its own, is never integrated work
  [ "$(git -C "$wt" rev-list --count "$def..$rev" 2>/dev/null || echo 0)" != "0" ] || return 1
  branch_has_own_commits "$wt" "$br" || return 1
  tree=$(git -C "$wt" rev-parse "${rev}^{tree}" 2>/dev/null) || return 1
  trees=$(git -C "$wt" log -n "${HYGIENE_TREE_SCAN:-500}" --format=%T "$def" 2>/dev/null)   # capture first: grep -q in a pipe SIGPIPEs git under pipefail
  if grep -qx "$tree" <<<"$trees"; then return 0; fi
  [ -n "$slug" ] && [ -n "$br" ] || return 1
  { command -v "$gh_bin" >/dev/null 2>&1 || [ -x "$gh_bin" ]; } || return 1
  base=$(git -C "$wt" merge-base "$rev" "$def" 2>/dev/null) || return 1
  files=$(git -C "$wt" diff --name-only "$base" "$rev" 2>/dev/null)
  [ -n "$files" ] || return 1
  while IFS= read -r mc; do
    [ -n "$mc" ] && git -C "$wt" cat-file -e "${mc}^{commit}" 2>/dev/null || continue
    # shellcheck disable=SC2046
    if printf '%s\n' "$files" | tr '\n' '\0' | xargs -0 git -C "$wt" diff --quiet "$mc" "$rev" -- 2>/dev/null; then return 0; fi
  done < <(_ut "${OS_UT_FAST:-30}" "$gh_bin" pr list -R "$slug" --head "$br" --state merged --json mergeCommit --jq '.[].mergeCommit.oid // empty' 2>/dev/null)
  return 1
}

wt_merge_verdict() {
  local wt="$1" slug="$2" br="$3" head ahead def heads gh_bin pr_ok=0
  gh_bin="${HYGIENE_GH:-gh}"
  { [ -n "$br" ] && [ "$br" != "?" ] && [ "$br" != HEAD ]; } || { echo unknown; return; }
  head=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || { echo unknown; return; }
  ahead=""
  for def in origin/main origin/master; do
    git -C "$wt" rev-parse --verify -q "$def" >/dev/null 2>&1 && { ahead=$(git -C "$wt" rev-list --count "$def..HEAD" 2>/dev/null); break; }
  done
  # every commit of this branch is already in main AND the branch has commits of its own: integrated work
  if [ "${ahead:-1}" = "0" ] && branch_has_own_commits "$wt" "$br"; then echo merged; return; fi
  if [ -n "$slug" ] && { command -v "$gh_bin" >/dev/null 2>&1 || [ -x "$gh_bin" ]; }; then
    if heads=$(_ut "${OS_UT_FAST:-30}" "$gh_bin" pr list -R "$slug" --head "$br" --state merged --json headRefOid --jq '.[].headRefOid' 2>/dev/null); then
      pr_ok=1
      if grep -qx "$head" <<<"$heads"; then echo merged; return; fi
    fi
  fi
  # squash/rebase merge whose PR head moved after merge: content already in main (see wt_squash_integrated)
  if [ "${ahead:-1}" != "0" ] && wt_squash_integrated "$wt" "$slug" "$br" "$def"; then echo merged; return; fi
  if [ "${ahead:-1}" = "0" ]; then echo new; return; fi   # no commit of its own and no merged PR at this tip: just created
  [ "$pr_ok" = 1 ] && echo unmerged || echo unknown
}

# wt_candidates <root>: the directories under <root> that may be a worktree (<repo>__<slug>, any depth), one per line.
#
# WHY (2026-10-30). The sweep found candidates with `find -name '*__*' -prune`. That glob also matches EVERY test/mock dir
# a repo tracks (`__tests__`, `__mocks__`, `__snapshots__`, `__benchmarks__`) and every `@types/babel__core`-style package
# dir. A worktree whose own directory name has no `__` (an EnterWorktree / Agent-isolation dir such as `msg-guard-1`) is not
# itself a candidate, so find DESCENDED into it, saw `frontend/__tests__` with no `.git` of its own, called it an
# "orphan worktree" and `rm -rf`'d it. The next `git status` there showed backend/__tests__ and frontend/__tests__ as deleted
# (whatsapp, 2026-10-30; hygiene log: "orphan dirs removed: ... msg-guard-1/frontend/__tests__ ... msg-guard-1/backend/__tests__").
# A candidate must (1) be named <repo>__<slug> with an alphanumeric on BOTH sides of the `__`, and (2) have NO ancestor
# below <root> that is a git work tree or a node_modules dir (anything inside a repo is repo content, never a worktree).
wt_candidates() {
  local root="${1:?wt_candidates <root>}" d p base
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    base="${d##*/}"
    case "$base" in
      __*|*__) continue ;;                       # __tests__, __mocks__, __snapshots__, trailing/leading double underscore
    esac
    [[ "$base" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*__[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || continue
    p="${d%/*}"
    while [ "$p" != "$root" ] && [ -n "$p" ] && [ "$p" != "/" ]; do
      if [ -e "$p/.git" ] || [ "${p##*/}" = node_modules ]; then continue 2; fi
      p="${p%/*}"
    done
    printf '%s\n' "$d"
  done < <(find "$root" -mindepth 1 -maxdepth 6 -type d -name '*__*' -prune -print 2>/dev/null)
}
