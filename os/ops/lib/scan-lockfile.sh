#!/usr/bin/env bash
# scan-lockfile.sh — resolve WHICH package-lock.json a vulnerability scan should read.
#
# WHY: on 2026-08-18 dream-research reported four Next.js CVEs plus sharp and
# fast-uri advisories against mypovonai. All of them had been fixed on origin three
# weeks earlier (PR #2). The scanner read `$repo/package-lock.json` straight off the
# local checkout, and that checkout was 2 commits behind origin/master — so it was
# reporting the vulnerabilities of a tree nobody was running. A stale checkout does
# not just delay findings, it manufactures false ones, and false CVE alerts are how
# a real one stops being read.
#
# What is deployed is what is on the default branch of origin, so that is what gets
# scanned. The local working copy may be behind, ahead, or dirty — none of which
# describes production.
#
#   scan-lockfile.sh <repo-dir> <out-file>
#
# Writes the lockfile content to <out-file> and prints one status line:
#   ref=origin/main behind=2 dirty=0
#   ref=worktree behind=0 dirty=0        (not a git repo, or no usable origin)
# Exit 0 on success, 1 if no lockfile could be found at all.
#
# FAIL-SOFT: any git problem (no origin, detached HEAD, fetch offline) degrades to
# the worktree file and says `ref=worktree`, rather than skipping the repo. A scan
# that silently drops a repo is worse than one that scans a slightly stale copy —
# but it must SAY which it did, so the caller can surface it.
set -uo pipefail

dir="${1:?repo-dir}"
out="${2:?out-file}"

ref="worktree"
behind=0
dirty=0

_emit_worktree() {
  if [ -f "$dir/package-lock.json" ]; then
    cat "$dir/package-lock.json" > "$out" 2>/dev/null && {
      echo "ref=worktree behind=$behind dirty=$dirty"; exit 0; }
  fi
  exit 1
}

[ -d "$dir/.git" ] || [ -f "$dir/.git" ] || _emit_worktree

# Never mutate the caller's checkout: fetch updates remote-tracking refs only.
git -C "$dir" fetch origin -q 2>/dev/null

def="$(git -C "$dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')"
if [ -z "$def" ]; then
  for cand in main master; do
    git -C "$dir" rev-parse --verify --quiet "origin/$cand" >/dev/null 2>&1 && { def="$cand"; break; }
  done
fi
[ -n "$def" ] || _emit_worktree

git -C "$dir" rev-parse --verify --quiet "origin/$def" >/dev/null 2>&1 || _emit_worktree

behind="$(git -C "$dir" rev-list --count "HEAD..origin/$def" 2>/dev/null)"
[ -n "$behind" ] || behind=0

# Uncommitted lockfile edits are not deployed either — report them, don't scan them.
git -C "$dir" diff --quiet -- package-lock.json 2>/dev/null || dirty=1

if git -C "$dir" show "origin/$def:package-lock.json" > "$out" 2>/dev/null && [ -s "$out" ]; then
  ref="origin/$def"
  echo "ref=$ref behind=$behind dirty=$dirty"
  exit 0
fi

# origin has no lockfile at that path (monorepo layout change, new repo) — fall back.
_emit_worktree
