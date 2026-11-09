#!/usr/bin/env bash
# ============================================================
# encode-lesson.sh — turn a memory lesson into a candidate detector (feature #1).
#
# The compounding loop: a `feedback-*.md` scar becomes an ENCODED detector so the
# OS catches that defect class forever. This drafts a detector spec from a lesson
# via `claude -p --model sonnet` and writes it to ops/detectors/_candidates/ for
# HUMAN REVIEW (candidates are NOT active until moved to ops/detectors/).
#
# Usage:
#   ops/encode-lesson.sh <path-to-memory-file.md>
#   ops/encode-lesson.sh --text "a one-paragraph lesson"
#
# Fail-open: if `claude` is unavailable it prints guidance and exits 0.
# ============================================================
set -uo pipefail
# CLAUDE_BIN lets a test point this at a stub. Without it the model call is
# untestable offline, which is why none of the OS's 17 model-calling scripts
# had a single behavioural test. Defaults to the real CLI.
CLAUDE_BIN="${CLAUDE_BIN:-claude}"
cd "$(dirname "$0")" || exit 1

CAND_DIR="detectors/_candidates"
mkdir -p "$CAND_DIR"

LESSON=""
case "${1:-}" in
  --text) LESSON="${2:-}" ;;
  "" )    echo "usage: encode-lesson.sh <memory-file.md> | --text \"lesson\""; exit 0 ;;
  * )     [ -f "$1" ] && LESSON="$(cat "$1")" || LESSON="$1" ;;
esac
[ -n "$LESSON" ] || { echo "[encode-lesson] empty lesson; nothing to do"; exit 0; }

if ! command -v claude >/dev/null 2>&1; then
  echo "[encode-lesson] claude CLI not found — cannot draft a detector."
  echo "  Hand-author one in ops/detectors/ using an existing detector as a template."
  exit 0
fi

SCHEMA='{"name":"kebab-id","class":"security-rls|security-injection|security-validation|bug-pattern|perf|...","severity":"critical|high|medium|low","title":"...","detail":"...","fix":"...","globs":["**/*.ts"],"match_mode":"file-present-absent|file-present|line-present","include_regex":"...","absent_regex":"(only for file-present-absent)","cap":25,"source_lesson":"the-memory-filename.md"}'

PROMPT="You convert a hard-won engineering lesson into a STATIC-ANALYSIS detector for a codebase-audit OS. Output ONLY a single JSON object (no prose, no markdown fence) matching EXACTLY this shape:
${SCHEMA}

Rules:
- include_regex / absent_regex are Python re patterns (matched case-insensitively).
- Use match_mode 'file-present-absent' for 'pattern X present without guard Y' lessons; 'line-present' for 'flag every occurrence of risky pattern X'; 'file-present' for 'this file shouldn't exist / contains a banned pattern'.
- globs target the files where the defect lives (e.g. ['**/*.sql'] for RLS).
- Keep it LOW false-positive: prefer a precise include_regex.
- severity reflects blast radius (auth/money/tenant=high+).

THE LESSON:
${LESSON}"

OUT="$(printf '%s' "$PROMPT" | "$CLAUDE_BIN" -p --model sonnet 2>/dev/null || true)"
# extract the first {...} JSON object
JSON="$(printf '%s' "$OUT" | python3 -c "
import sys,json
t=sys.stdin.read()
i=t.find('{'); j=t.rfind('}')
if i<0 or j<0: sys.exit(1)
try:
    obj=json.loads(t[i:j+1])
except Exception:
    sys.exit(1)
name=obj.get('name') or 'unnamed-detector'
print(name)
print('---SPLIT---')
print(json.dumps(obj,indent=2,ensure_ascii=False))
" 2>/dev/null || true)"

if [ -z "$JSON" ]; then
  echo "[encode-lesson] sonnet did not return a valid detector JSON. Raw output:"
  printf '%s\n' "$OUT" | head -20
  exit 0
fi

NAME="$(printf '%s' "$JSON" | sed -n '1p')"
BODY="$(printf '%s' "$JSON" | sed '1,/---SPLIT---/d')"
DEST="$CAND_DIR/${NAME}.json"
printf '%s\n' "$BODY" > "$DEST"
echo "[encode-lesson] wrote candidate detector: $DEST"
echo "  REVIEW it, test against a repo, then move to ops/detectors/ to activate:"
echo "    python3 ops/lib/detector-run.py --repo test --dir <repo> --detectors $CAND_DIR"
exit 0
