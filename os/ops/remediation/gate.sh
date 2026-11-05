# shellcheck shell=bash
HERE_G="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE_G/review-score.sh"

gate_decision() { # <ci> <blast 0=clean> <score>
  [ "$1" = "success" ] && [ "$2" = "0" ] && [ "${3:-0}" -ge 80 ] 2>/dev/null && { echo MERGE; return; }
  echo HUMAN
}

# ci_state <gh-checks-exit-rc> <gh-checks-output> -> "success" | "failure"  (FAIL-CLOSED)
ci_state() {
  local rc="$1" out="$2"
  { [ "$rc" -eq 0 ] && [ -n "$out" ]; } || { echo failure; return; }
  printf '%s' "$out" | grep -qiE 'fail|error|cancel|timed_out|action_required|stale|pending|queued|in_progress' && { echo failure; return; }
  echo success
}

# changes_only_lockfile <repo> <base-ref> <head-ref> -> exit 0 if ONLY package-lock.json differs, else 1
changes_only_lockfile() { git -C "$1" diff --quiet "$2...$3" -- ':!package-lock.json'; }

# blast_radius_clean <repo> <branch> -> 0 clean (lockfile-only), 1 dirty (route to human)
blast_radius_clean() {
  local repo="$1" br="$2" base
  base="$(git -C "$repo" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')"
  [ -n "$base" ] || base=main
  changes_only_lockfile "$repo" "origin/$base" "$br"
}

gate_run() { # <pr> <slug> <branch> <repo-path>
  local pr="$1" slug="$2" branch="$3" repo="$4" ci score sc dec
  gh pr checks "$pr" --repo "$slug" --watch >/dev/null 2>&1
  local _cout _crc
  _cout="$(gh pr checks "$pr" --repo "$slug" 2>/dev/null)"; _crc=$?
  ci="$(ci_state "$_crc" "$_cout")"
  blast_radius_clean "$repo" "$branch"; local blast=$?
  score="$(review_score "$pr" "$slug")"; sc="$(printf '%s' "$score" | python3 -c 'import json,sys;print(json.load(sys.stdin)["score"])' 2>/dev/null || echo 0)"
  dec="$(gate_decision "$ci" "$blast" "$sc")"
  if [ "$dec" = "MERGE" ]; then
    gh pr merge "$pr" --repo "$slug" --squash --auto >/dev/null 2>&1
    echo "MERGED pr#$pr (score $sc)"
  else
    "$HERE_G/../notify.sh" "Remediation — manual merge needed" \
      "PR #$pr ($slug) scored $sc / CI=$ci — needs YOUR admin-merge. $(printf '%s' "$score" | python3 -c 'import json,sys;print(json.load(sys.stdin)[\"reasoning\"])' 2>/dev/null)" >/dev/null 2>&1
    echo "HUMAN pr#$pr (score $sc, ci $ci)"
  fi
}