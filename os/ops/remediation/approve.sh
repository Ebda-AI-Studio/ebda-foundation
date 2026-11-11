# shellcheck shell=bash
# approve.sh — human-approval path for oversize Class-B fixes.
# `approve_pr` only moves a parked fix from the pending store into the gate queue;
# the ACTUAL drain (CI → blast-radius → review → merge|human) is done by
# `remediate.sh --approve`, which reuses the orchestrator's single-runner drain loop
# (that loop re-queues on lock contention, so an approved fix is never lost).
HERE_AP="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE_AP/ledger.sh" 2>/dev/null || . "$HOME/.claude/scripts/remediation/ledger.sh" 2>/dev/null || true

parse_process_it() { # <text> -> PR number or empty
  printf '%s' "$1" | grep -oiE 'process[[:space:]]+it[[:space:]]+#?[0-9]+' \
    | grep -oE '[0-9]+' | head -1
}

approve_pr() { # <pr> -> move a pending fix into the gate queue (drained by remediate.sh --approve)
  local pr="$1" item
  item="$(pending_pop "$pr")"
  [ -n "$item" ] || { echo "NOPENDING pr#$pr"; return 1; }
  queue_add "$item"
  echo "APPROVED pr#$pr"
}