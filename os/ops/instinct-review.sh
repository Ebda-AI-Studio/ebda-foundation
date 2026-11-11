#!/usr/bin/env bash
# instinct-review.sh — inspect/manage the continuous-learning instinct store.
# Usage: instinct-review.sh [status|list|candidates|top|extract]
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/bin:/bin:$PATH"
BASE="$HOME/.claude/instincts"; STORE="$BASE/store.jsonl"; CAND="$BASE/candidates.md"
cmd="${1:-status}"
case "$cmd" in
  status)
    n=$( [ -f "$STORE" ] && wc -l <"$STORE" | tr -d ' ' || echo 0)
    g=$( [ -f "$STORE" ] && grep -c '"scope": "global"\|"scope":"global"' "$STORE" 2>/dev/null || echo 0)
    tr_=$(find "$BASE/traces" -maxdepth 1 -name '*.trace' 2>/dev/null | wc -l | tr -d ' ')
    echo "instincts: $n stored ($g global) · pending traces: $tr_"
    [ -f "$CAND" ] && echo "candidates awaiting review: $(grep -c '^- ' "$CAND" 2>/dev/null) (see: instinct-review.sh candidates)"
    ;;
  top|list)
    [ -f "$STORE" ] || { echo "(empty)"; exit 0; }
    python3 -c "
import json,sys
xs=[json.loads(l) for l in open('$STORE') if l.strip()]
for o in sorted(xs,key=lambda x:(-x.get('confidence',0),-x.get('count',0)))[:40]:
    print(f\"[{o.get('confidence')}] {o.get('scope','?')[:7]:7} x{o.get('count',1)}  when {o.get('trigger')} -> {o.get('action')}\")"
    ;;
  candidates) [ -f "$CAND" ] && cat "$CAND" || echo "(no candidates yet — run extract)";;
  extract) "$HOME/.claude/scripts/instinct-extract.sh";;
  *) echo "usage: instinct-review.sh [status|list|candidates|top|extract]";;
esac
