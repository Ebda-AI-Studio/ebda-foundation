#!/usr/bin/env bash
# Does a commit delta contain anything that can change a RUNNING service?
#
# 2026-08-25: deploy-drift alerted for 32h on "whatsapp api: DRIFT — prod running
# 92b47c14, HEAD is 7279f774, running sha is ~68h old". The entire delta was:
#
#   .github/workflows/db-backup.yml | .github/workflows/rls-proof.yml
#   .github/workflows/semgrep.yml
#
# One commit, CI-only, nothing deployable. Prod was running byte-identical
# application code. Redeploying to clear that alert would have been pure risk
# for zero benefit — and an alert whose only remedy is a pointless prod deploy
# is how a real drift alert gets ignored later.
#
# Drift means "prod is running DIFFERENT CODE", not "prod's sha != HEAD".
#
# The verdict is deliberately conservative: anything not provably inert is
# DEPLOYABLE. A missed alert is far worse than a redundant one, so every
# uncertain case — empty list, truncated list, unrecognised path — alerts.

# Paths that cannot affect a running service. Deliberately short: every entry
# has to be inert for EVERY service shape (Railway container, CF Worker,
# Vercel build), because this runs across all of them.
#   .github/   CI + issue templates — never shipped in a build artifact
#   docs/      documentation
#   *.md       READMEs, changelogs, ADRs
#   editor/VCS metadata and licence files
_dc_inert_path() {
  case "$1" in
    .github/*|docs/*|*.md|\
    .vscode/*|.idea/*|\
    .gitignore|.gitattributes|.editorconfig|.mailmap|\
    LICENSE|LICENSE.*|CODEOWNERS|.github)  return 0 ;;
  esac
  return 1
}

# deployable_verdict  — reads one path per line on stdin
#   -> "none"       every path is provably inert
#      "deployable" at least one path can change the running service
#      "unknown"    could not tell (empty input, or a truncation marker)
#
# Callers MUST treat "unknown" exactly like "deployable". It is a separate
# value only so the reason can be reported.
#
# A line equal to "__TRUNCATED__" forces "unknown": GitHub's compare API caps
# `.files` at 300 entries, and a capped list cannot prove the tail is inert.
deployable_verdict() {
  local line seen=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if [ "$line" = "__TRUNCATED__" ]; then echo "unknown"; return 0; fi
    seen=1
    _dc_inert_path "$line" || { echo "deployable"; return 0; }
  done
  # No paths at all is NOT evidence of an inert delta — it usually means the
  # API call failed. Never let a failed lookup silence a drift alert.
  [ "$seen" = 1 ] && echo "none" || echo "unknown"
}

# changed_files <slug> <base> <head>
#   Emits one changed path per line, plus __TRUNCATED__ when GitHub capped the
#   list. Emits nothing when the call fails, which deployable_verdict reads as
#   "unknown" — the fail-loud direction.
changed_files() {
  local slug="$1" base="$2" head="$3"
  [ -n "$slug" ] && [ -n "$base" ] && [ -n "$head" ] || return 0
  gh api "repos/$slug/compare/$base...$head" \
    --jq '(.files // [] | .[].filename), (if ((.files // []) | length) >= 300 then "__TRUNCATED__" else empty end)' \
    2>/dev/null || true
}
