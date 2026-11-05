#!/usr/bin/env bash
# Fails when a tracked file outside docs/history/ still carries a predecessor-business string.
# Exempt: docs/history/, the plan that lists the strings by necessity, git-ignored scratch (.superpowers/), this test.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
RE='ForceAI-KW|force-ai-foundation|Force-AI/internal-projects|forceai\.|com\.forceai|ff6e01|#ff6e01|Kuwait|KWD|MyFatoorah|aladiyat|rayanah|om-hassan|da-gusto|fca-kuwait|salam-hydraulic'
if git rev-parse --git-dir >/dev/null 2>&1; then
  files=$( { git ls-files; git ls-files --others --exclude-standard; } | sort -u )
else
  files=$(find . -type f -not -path './.git/*' -not -path './node_modules/*' | sed 's|^\./||')
fi
RE2='forceai[-_.]|\bFWB\b|\bWBS\b|force-website-builder|whatsapp-bulk-sender|gcc-horse-market|horse-market|work-wise|legende|olounge|beethoven|al[-_]?assriya|wady|pecan+bee|forcemediakw|force-ai\.co'
RE_CI='force[-_ ]?ai'
hits=$(printf '%s\n' "$files" \
  | grep -vE '^(docs/history/|\.superpowers/|node_modules/|\.git/|docs/plans/2026-11-05-foundation-takeover\.md$|os/tests/no-force-strings\.test\.sh$|package-lock\.json$)' \
  | while IFS= read -r f; do [ -f "$f" ] && { grep -InE "$RE|$RE2" -- "$f" 2>/dev/null; grep -InEi "$RE_CI" -- "$f" 2>/dev/null; } | sort -u | sed "s|^|$f:|"; done)
if [ -n "$hits" ]; then
  echo "FAIL: predecessor strings found outside docs/history/:"
  printf '%s\n' "$hits"
  echo "($(printf '%s\n' "$hits" | wc -l | tr -d ' ') hits)"
  exit 1
fi
echo "PASS: no predecessor strings outside docs/history/"
