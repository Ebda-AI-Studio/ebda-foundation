#!/usr/bin/env bash
# merge-gate.sh - the ONE way to merge a PR: merge-gate.sh <pr> <expected-head-sha> [options]   (repo-agnostic)
#
# WHY (2026-10-25). ebda-store #223, a destructive DB migration, merged 6 s after creation with ZERO checks: a watcher
# read an empty check list as green, and `gh pr merge` merges happily when nothing has reported. Whisky-11 Free-plan
# private repos have NO branch protection, so this gate is the only line. It refuses unless, on N consecutive polls:
#   - the PR head is exactly <expected-head-sha> (7+ char prefix ok): you merge what you reviewed, and the final
#     `gh pr merge` is pinned to that commit (--match-head-commit)
#   - mergeable == MERGEABLE (not UNKNOWN, not CONFLICTING)
#   - at least one check exists (zero checks = "CI has not started", never green)
#   - every check is COMPLETED with SUCCESS / SKIPPED / NEUTRAL
#   - every REQUIRED check is an explicit SUCCESS; the list is DERIVED from the repo's .github/workflows
#     (lib/merge_gate.py), so it cannot drift from the workflows. No PR workflow => no required list => REFUSE.
# A failed/cancelled check or a moved head ends the run at once (exit 1). Pending checks are waited on up to
# --max-wait-min (180); running out of time exits 2 and merges nothing.
#
# options: --repo OWNER/NAME (default: this checkout's repo)  --workflows DIR (default <toplevel>/.github/workflows)
#          --polls N (3)  --interval S (30)  --max-wait-min M (180)  --method squash|merge|rebase (squash)  --dry-run
# test seams: MERGE_GATE_VIEW_CMD (prints the PR json), MERGE_GATE_MERGE_CMD, MERGE_GATE_REQUIRED_JSON, MERGE_GATE_MAX_WAIT_S
set -uo pipefail
pr="${1:?usage: merge-gate.sh <pr> <expected-head-sha> [--repo R] [--workflows D] [--polls N] [--interval S] [--max-wait-min M] [--dry-run]}"
want="${2:?expected head sha required}"; shift 2
repo=""; wfdir=""; polls=3; interval=30; maxmin=180; dry=0; method=squash
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) repo="$2"; shift 2 ;; --workflows) wfdir="$2"; shift 2 ;; --polls) polls="$2"; shift 2 ;;
    --interval) interval="$2"; shift 2 ;; --max-wait-min) maxmin="$2"; shift 2 ;; --method) method="$2"; shift 2 ;;
    --dry-run) dry=1; shift ;;
    *) echo "merge-gate: unknown option $1" >&2; exit 64 ;;
  esac
done
[ "${#want}" -ge 7 ] || { echo "merge-gate: expected sha must be at least 7 chars" >&2; exit 64; }
here="$(cd "$(dirname "$0")" && pwd)"
py="$here/lib/merge_gate.py"; [ -f "$py" ] || py="$here/merge_gate.py"
[ -f "$py" ] || { echo "merge-gate: lib/merge_gate.py not found next to this script" >&2; exit 64; }
if [ -z "$repo" ] && [ -z "${MERGE_GATE_VIEW_CMD:-}" ]; then
  repo="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)" || { echo "merge-gate: pass --repo OWNER/NAME" >&2; exit 64; }
fi
if [ -n "${MERGE_GATE_REQUIRED_JSON:-}" ]; then required="$MERGE_GATE_REQUIRED_JSON"
else
  [ -n "$wfdir" ] || wfdir="$(git rev-parse --show-toplevel 2>/dev/null)/.github/workflows"
  [ -d "$wfdir" ] || { echo "merge-gate: no workflows dir at $wfdir (run from a checkout of the repo, or pass --workflows); refusing" >&2; exit 2; }
  required="$(python3 -I "$py" required "$wfdir")"
fi
case "$required" in "[]"|"") echo "merge-gate: the repo has no always-run PR check to require (or the list could not be derived); refusing - never merge on no checks" >&2; exit 2 ;; esac

view() {
  if [ -n "${MERGE_GATE_VIEW_CMD:-}" ]; then eval "$MERGE_GATE_VIEW_CMD"
  else gh pr view "$pr" --repo "$repo" --json headRefOid,mergeable,statusCheckRollup; fi
}
deadline=$((SECONDS + ${MERGE_GATE_MAX_WAIT_S:-$((maxmin * 60))})); streak=0; sha=""
while :; do
  json="$(view 2>/dev/null)" || json=""
  if [ -z "$json" ]; then v="wait:could not read the PR"
  else
    v="$(printf '%s' "$json" | python3 -I "$py" evaluate "$want" "$required" 2>/dev/null)" || v="wait:could not evaluate the PR json"
    sha="$(printf '%s' "$json" | python3 -I -c 'import json,sys;print(json.load(sys.stdin).get("headRefOid",""))' 2>/dev/null)"
  fi
  case "$v" in
    ok) streak=$((streak + 1)); echo "merge-gate: PR $pr green poll $streak/$polls"
        if [ "$streak" -ge "$polls" ]; then
          if [ "$dry" = 1 ]; then echo "merge-gate: DRY RUN, would merge $pr at $sha"; exit 0; fi
          if [ -n "${MERGE_GATE_MERGE_CMD:-}" ]; then eval "$MERGE_GATE_MERGE_CMD"; exit $?; fi
          gh pr merge "$pr" --repo "$repo" "--$method" --delete-branch --match-head-commit "$sha"; exit $?
        fi ;;
    refuse:*) echo "merge-gate: REFUSED PR $pr: ${v#refuse:}" >&2; exit 1 ;;
    *) streak=0; echo "merge-gate: waiting (${v#wait:})" ;;
  esac
  if [ "$SECONDS" -ge "$deadline" ]; then echo "merge-gate: gave up after ${maxmin} min; nothing merged (last: ${v#*:})" >&2; exit 2; fi
  sleep "$interval"
done
