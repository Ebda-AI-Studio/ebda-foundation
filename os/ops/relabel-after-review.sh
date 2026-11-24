#!/usr/bin/env bash
# Ebda AI OS - relabel-after-review.sh: re-apply `ai-review-passed` to a PR once the AI review of its CURRENT head has PASSED.
#
#   relabel-after-review.sh --repo OWNER/NAME [--workflow "AI review"] [--label ai-review-passed]
#                           [--interval 60] [--max-polls 480] PR_NUMBER
#
# A push strips the label (ci/ai-review); the review re-runs on the new head. This waits (network-tolerant: a failed gh call is
# retried, never treated as an answer) until every review run on the head has finished, then relabels ONLY on the CONCLUSION:
#   >= 1 run concluded `success`, and NO run on that head concluded failure / cancelled / timed_out / action_required /
#   startup_failure. status==completed alone is not review: a FAILED review is completed too (2026-11-12: a status-only helper
#   would have re-applied the label after a failed review). Fail closed; the head must not move while waiting.
# Exit: 0 relabelled, 1 not relabelled (review not clean / not finished in time / head moved), 2 usage.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/args.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/args.sh" || exit 2
args_help "${BASH_SOURCE[0]}" "$@"
REPO=""; WF="AI review"; LABEL="ai-review-passed"; INTERVAL=60; MAXPOLLS=480; PR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:?}"; shift ;; --workflow) WF="${2:?}"; shift ;; --label) LABEL="${2:?}"; shift ;;
    --interval) INTERVAL="${2:?}"; shift ;; --max-polls) MAXPOLLS="${2:?}"; shift ;;
    -*) args_unknown "${BASH_SOURCE[0]}" "$1" ;;
    *) [ -z "$PR" ] || { echo "relabel-after-review: one PR number only (got '$PR' and '$1')" >&2; exit 2; }; PR="$1" ;;
  esac
  shift
done
case "$REPO" in */*) ;; *) echo "relabel-after-review: --repo OWNER/NAME is required" >&2; exit 2 ;; esac
case "$PR" in ''|*[!0-9]*) echo "relabel-after-review: a whole PR number is required (got '$PR')" >&2; exit 2 ;; esac
for v in "$INTERVAL" "$MAXPOLLS"; do case "$v" in ''|*[!0-9]*) echo "relabel-after-review: --interval/--max-polls must be whole numbers" >&2; exit 2 ;; esac; done
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"
log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*"; }

head_sha() { gh pr view "$PR" -R "$REPO" --json headRefOid --jq .headRefOid 2>/dev/null; }

H=""; i=0
until [ -n "$H" ]; do
  H="$(head_sha)" || H=""
  [ -n "$H" ] && break
  i=$((i + 1)); [ "$i" -le "$MAXPOLLS" ] || { log "NOT relabelled (cannot read PR #$PR head)"; exit 1; }
  sleep "$INTERVAL"
done

# verdict for the head: prints "pending" | "clean" | "dirty: <conclusions>"; unreadable GitHub prints nothing and returns 1
verdict() {
  gh run list -R "$REPO" --workflow "$WF" --limit 100 --json status,conclusion,headSha 2>/dev/null | python3 -I -c '
import json, sys
sha = sys.argv[1]
runs = [r for r in json.load(sys.stdin) if r.get("headSha") == sha]
if not runs or any((r.get("status") or "").lower() != "completed" for r in runs):
    print("pending"); sys.exit(0)
c = [(r.get("conclusion") or "").lower() for r in runs]
bad = {"failure", "cancelled", "timed_out", "action_required", "startup_failure"}
print("clean" if "success" in c and not any(x in bad or x == "" for x in c) else "dirty: " + ",".join(c))
' "$H"
}

i=0; v=""
while :; do
  if v="$(verdict)" && [ -n "$v" ]; then
    log "AI review on ${H:0:9}: $v"
    [ "$v" = pending ] || break
  fi
  i=$((i + 1)); [ "$i" -le "$MAXPOLLS" ] || { log "NOT relabelled (review not finished in time)"; exit 1; }
  sleep "$INTERVAL"
done
[ "$v" = clean ] || { log "NOT relabelled (no clean successful review: $v)"; exit 1; }
H2="$(head_sha)" || H2=""
[ "$H2" = "$H" ] || { log "NOT relabelled (head moved ${H:0:9} -> ${H2:0:9})"; exit 1; }
gh pr edit "$PR" -R "$REPO" --remove-label "$LABEL" >/dev/null 2>&1
sleep "${RELABEL_GAP:-3}"   # let GitHub register the removal so the add re-fires the labeled event
gh pr edit "$PR" -R "$REPO" --add-label "$LABEL" || { log "NOT relabelled (gh pr edit failed)"; exit 1; }
log "RELABELLED #$PR @ ${H:0:9}"
