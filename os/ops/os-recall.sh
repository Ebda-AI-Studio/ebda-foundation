#!/usr/bin/env bash
# os-recall.sh — the Whisky AI OS "brain": unified recall over everything the OS knows,
# plus a map of its senses. This is how the OS (and Zero, and any headless agent) asks
# "what do we know about X?" and gets an answer drawn from the knowledge graph + the
# Obsidian vault + scoped memory — instead of being blind between conversations.
#
#   os-recall.sh "<question>"     Recall: graphify BFS over the memory graph + the vault
#                                 graph, plus a keyword sweep of the raw markdown. Prints
#                                 ranked nodes/files with their source paths.
#   os-recall.sh senses           Print what the OS can SEE (inputs), SAY (outputs), and
#                                 DO (CLIs) — its awareness map.
#   os-recall.sh graphs           Show graph coverage (nodes + files) per knowledge base.
#
# Read-only. Safe to call from anywhere, any agent, any cron.
set -uo pipefail

MEMDIR="$HOME/.claude/projects/-Users-ahmadsharaf/memory"
MEM_GRAPH="$MEMDIR/graphify-out/graph.json"
VAULT="$HOME/Desktop/projects/calude code meomry"
VAULT_GRAPH="$VAULT/graphify-out/graph.json"

have() { command -v "$1" >/dev/null 2>&1; }

recall() {
  local q="$*"
  [ -n "$q" ] || { echo "usage: os-recall.sh \"<question>\""; exit 2; }
  echo "🧠 RECALL: $q"
  echo "────────────────────────────────────────────────────────"
  if have graphify; then
    for g in "$MEM_GRAPH:scoped-memory" "$VAULT_GRAPH:obsidian-vault"; do
      path="${g%%:*}"; label="${g##*:}"
      [ -f "$path" ] || continue
      echo "▸ graph: $label"
      graphify query "$q" --graph "$path" 2>/dev/null \
        | grep -E '^NODE |Traversal:' | head -9 | sed 's/^/   /'
      echo
    done
  else
    echo "(graphify CLI not found — falling back to keyword sweep only)"
  fi
  echo "▸ keyword hits (raw markdown):"
  # word-boundary-ish grep across memory + vault, filename + first matching line
  local terms; terms="$(printf '%s' "$q" | tr ' ' '|')"
  { grep -rilE "$terms" "$MEMDIR" 2>/dev/null | grep '\.md$';
    grep -rilE "$terms" "$VAULT/wiki" 2>/dev/null | grep '\.md$'; } \
    | sort -u | head -12 | sed "s#$HOME#~#; s/^/   /"
}

senses() {
  cat <<EOF
🧠 WHISKY AI OS — AWARENESS MAP (what the brain can perceive + act on)

SEE (inputs the OS reads):
  • Gmail            IMAP alert bridge (gmail-alert-poller in FWB API) → alerts from
                     Sentry/UptimeRobot/PostHog/Railway/Neon land in Telegram.
                     Creds: ~/.whisky-services.env (GMAIL_IMAP_*).
  • Health/monitors  ~/.whisky-os-state/*-status.json — every subsystem (services, checkout,
                     wbs, cf-workers, deploy-drift, dr-drill, neon-recover, cost, backup, …).
  • Knowledge graph  scoped memory graph + Obsidian vault graph (graphify) — recall via THIS script.
  • Event bus        ~/.whisky-os-state/events.ndjson + zero-inbox.ndjson (the live SEE stream).

SAY (how the OS reaches Ahmad):
  • Telegram         notify.sh → Whisky Whoop bot (one channel for the whole OS).
                     Creds: ~/.whisky-whoop-telegram.env. Used by every monitor + self-heal + DR.

DO (CLIs the OS can act with):
  • railway / wrangler / neonctl — deploy, rollback, DB branch/restore (self-heal.sh, neon-recover.sh).
  • gh / git — CI status, PRs, repo ops (os-watch.sh, read-only).
  • graphify — query/extract the knowledge graph.
  • Gemini (GEMINI_API_KEY) — free bulk NLP / graph extraction.

KNOW (persistent memory across conversations):
  • Scoped memory  $MEMDIR
  • Obsidian vault $VAULT/wiki (GitHub-mirrored: Ebda-AI-Studio/claude-memory-vault)
  • Both are graphified; ask the brain: os-recall.sh "<question>"

SELF-HEAL (autonomous remediation, tiered by reversibility):
  • T1 restart/redeploy · T2 CF wrangler-rollback (live) · T3 Neon prepare+approve (human-gated cutover).
  • Recovery proven weekly by dr-drill.sh. See reference-self-healing-os in memory.
EOF
}

graphs() {
  for g in "$MEM_GRAPH:scoped-memory:$MEMDIR" "$VAULT_GRAPH:obsidian-vault:$VAULT/wiki"; do
    path="${g%%:*}"; rest="${g#*:}"; label="${rest%%:*}"; dir="${rest##*:}"
    if [ -f "$path" ]; then
      nodes=$(jq '.nodes|length' "$path" 2>/dev/null)
      srcs=$(jq -r '[.nodes[].source_file//.nodes[].properties.source_file//empty]|unique|length' "$path" 2>/dev/null)
      files=$(find "$dir" -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
      echo "$label: $nodes nodes, $srcs files graphed / $files md files on disk  ($path)"
    else
      echo "$label: NO GRAPH at $path"
    fi
  done
}

cmd="${1:-}"
case "$cmd" in
  senses) senses ;;
  graphs) graphs ;;
  "" ) echo "usage: os-recall.sh {\"<question>\"|senses|graphs}"; exit 2 ;;
  *) recall "$@" ;;
esac
