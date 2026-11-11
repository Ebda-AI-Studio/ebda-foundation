# shellcheck shell=bash
# autofix-coord.sh — coordination gate for auto-fix-check (skip repos a session already owns).
_AFC_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_AFC_HERE/work-registry.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/work-registry.sh" 2>/dev/null || true
autofix_workid() { # <slug> <sha> [prnum] -> PR-scoped key if a PR exists, else ci: key
  if [ -n "${3:-}" ]; then printf 'pr:%s#%s' "$1" "$3"; else printf 'ci:%s@%s' "$1" "$2"; fi
}
autofix_claim_gate() { # <slug> <sha> <owner> [prnum] -> 0 proceed (claimed), 1 skip (someone else owns it)
  wr_claim "$(autofix_workid "$1" "$2" "${4:-}")" "$3" 3600
}