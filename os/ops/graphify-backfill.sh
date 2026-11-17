#!/usr/bin/env bash
# graphify-backfill.sh — keep the knowledge graph at 100% coverage, autonomously.
#
# Sonnet is the extractor (Gemini's free tier 5-RPM 429s and writes empty nodes — never
# use it for memory). This script finds memory notes with NO graph nodes, dispatches
# Sonnet HEADLESS via `claude -p` (rides the Max plan, $0) to extract a bounded batch
# into a graphify polish chunk, then merges it. Leftovers roll to the next run, so
# coverage converges to 100% on its own.
#
# Always writes graph-coverage-status.json (the command-center "Knowledge graph" tile).
# The heavy claude -p extraction is COOLDOWN-guarded so it never fires on every commit.
#
#   graphify-backfill.sh            report coverage + backfill one bounded batch if due
#   graphify-backfill.sh report     coverage only (no extraction) — cheap, safe anywhere
#   GRAPHIFY_BACKFILL_LIMIT=50  GRAPHIFY_BACKFILL_COOLDOWN=21600  DRY_RUN=1
set -uo pipefail
# CLAUDE_BIN lets a test point this at a stub. Without it the model call is
# untestable offline, which is why none of the OS's 17 model-calling scripts
# had a single behavioural test. Defaults to the real CLI.
CLAUDE_BIN="${CLAUDE_BIN:-claude}"
HERE="$HOME/.claude/scripts"
MEMDIR="$HOME/.claude/projects/-Users-ahmadsharaf/memory"
G="$MEMDIR/graphify-out/graph.json"
STATE="$HOME/.whisky-os-state"
LAST="$STATE/graph-backfill-last"
LOCK="$STATE/graph-backfill.lock"
LIMIT="${GRAPHIFY_BACKFILL_LIMIT:-50}"
COOLDOWN="${GRAPHIFY_BACKFILL_COOLDOWN:-21600}"   # 6h
DRY="${DRY_RUN:-0}"
[ -f "$HERE/lib/os-state.sh" ] && source "$HERE/lib/os-state.sh" 2>/dev/null || true

# TCC canary (2026-07-12): abort when the launchd context cannot see ~/Desktop
OS_JOB_NAME=graphify-backfill
if command -v require_projects_access >/dev/null 2>&1; then require_projects_access || exit 0; fi


[ -f "$G" ] || { echo "no graph at $G"; exit 1; }

# --- coverage: memory .md files (excluding index/large chrome) that have zero nodes ---
# Nodes tagged origin=wikilink-pass are link anchors carrying a filename, not extracted
# knowledge — counting them as coverage would read 99% while the file is still unread,
# and starve this very backfill of the work it exists to do (found 2026-08-03).
covered="$(jq -r '[.nodes[]|select(.origin!="wikilink-pass")|.source_file//empty]|unique|.[]' "$G" 2>/dev/null | sed 's#.*/##' | sort -u)"
: > /tmp/graph-ungraphed.txt
total=0; ung=0
for f in "$MEMDIR"/*.md; do
  b="$(basename "$f")"
  case "$b" in MEMORY.md|MEMORY-*.md|CLAUDE.md) continue;; esac
  total=$((total+1))
  grep -qxF "$b" < <(printf '%s\n' "$covered") || { echo "$MEMDIR/$b" >> /tmp/graph-ungraphed.txt; ung=$((ung+1)); }
done
graphed=$((total-ung))
pct=$(( total>0 ? graphed*100/total : 100 ))
nodes=$(jq '.nodes|length' "$G" 2>/dev/null)

ok=true; [ "$ung" -gt 0 ] && ok=warn
summary="knowledge graph: ${graphed}/${total} memory files graphed (${pct}%), ${nodes} nodes; ${ung} pending"
command -v write_status >/dev/null && write_status graph-coverage "$ok" "$summary" \
  "{\"graphed\":$graphed,\"total\":$total,\"pct\":$pct,\"nodes\":$nodes,\"pending\":$ung}"
echo "$summary"

[ "${1:-}" = "report" ] && exit 0
[ "$ung" -eq 0 ] && { echo "100% covered — nothing to backfill"; exit 0; }

# --- cooldown + lock so the claude -p extraction never fires on every commit ---
now=$(date +%s 2>/dev/null || echo 0)
last=$(cat "$LAST" 2>/dev/null || echo 0)
if [ "$last" -gt 0 ] && [ $((now-last)) -lt "$COOLDOWN" ]; then
  echo "backfill in cooldown ($(( (COOLDOWN-(now-last))/60 ))m left) — $ung files pending, will extract next window"; exit 0
fi
mkdir -p "$STATE"
if ! ( set -o noclobber; echo "$$" > "$LOCK" ) 2>/dev/null; then echo "another backfill holds the lock — skip"; exit 0; fi
trap 'rm -f "$LOCK"' EXIT

head -n "$LIMIT" /tmp/graph-ungraphed.txt > /tmp/graph-backfill-batch.txt
batch_n=$(wc -l < /tmp/graph-backfill-batch.txt | tr -d ' ')
chunk="$MEMDIR/graphify-out/.graphify_polish_chunk_autobackfill-$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || echo now).json"
echo "backfilling $batch_n / $ung ungraphed files via claude -p (sonnet)…"
[ "$DRY" = 1 ] && { echo "[dry] would claude -p extract $batch_n files -> $(basename "$chunk")"; exit 0; }

PROMPT="You are a knowledge-graph extractor for graphify. Read every file listed in /tmp/graph-backfill-batch.txt (absolute paths, Markdown memory notes). For EACH file extract 2-4 key knowledge nodes. Write ONE json file to exactly ${chunk} with shape: {\"nodes\":[{\"id\":\"snake_case_unique\",\"label\":\"one-line title\",\"file_type\":\"document\",\"source_file\":\"ABSOLUTE path from the list\",\"node_type\":\"concept|trap|rule|pattern|decision|reference|tool|entity\",\"tags\":[\"kebab\"],\"summary\":\"1-3 factual sentences\"}],\"edges\":[{\"source\":\"id\",\"target\":\"id\",\"type\":\"EXTRACTED\",\"confidence\":1.0,\"label\":\"relation\"}],\"hyperedges\":[]}. EVERY node MUST have the correct absolute source_file or it is dropped. Write ONLY the json file; do not print it."

if "$CLAUDE_BIN" -p --model sonnet "$PROMPT" >/tmp/graph-backfill-claude.log 2>&1 && [ -f "$chunk" ] && jq -e '.nodes|length>0' "$chunk" >/dev/null 2>&1; then
  echo "extracted $(jq '.nodes|length' "$chunk") nodes; merging…"
  "$HERE/graphify-merge-chunks.sh" "$MEMDIR" 2>&1 | tail -2
  echo "$now" > "$LAST"
  command -v emit_event >/dev/null && emit_event graph-coverage low "backfilled $batch_n memory files into the graph" "{}" 2>/dev/null || true
else
  echo "claude -p extraction failed (see /tmp/graph-backfill-claude.log) — coverage unchanged"
  # Move the rejected artifact OUT of the .graphify_polish_chunk_* glob. The
  # guard above correctly refuses to merge an unparseable chunk, but leaving
  # it on disk turned a one-off failure into a warning that repeated on every
  # later pipeline run (graphify-merge-chunks.sh re-reads the same glob). Keep
  # it for diagnosis, next to the log that explains it — never delete.
  if [ -f "$chunk" ]; then
    mkdir -p "$MEMDIR/graphify-out/rejected-chunks"
    mv "$chunk" "$MEMDIR/graphify-out/rejected-chunks/$(basename "$chunk")" 2>/dev/null \
      && echo "  quarantined unusable chunk -> graphify-out/rejected-chunks/$(basename "$chunk")"
  fi
  echo "$now" > "$LAST"   # still stamp so we don't retry-storm on a persistent failure
fi
