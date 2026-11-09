#!/usr/bin/env bash
# --------------------------------------------------------------------
# claude-hook declaration — read by ops/dead-gate-detect.sh, which fails the
# OS self-check if a declared hook is not actually registered in
# ~/.claude/settings.json. A shipped-but-unwired hook never fires and reads
# as coverage; ops/self-eval-gate.sh sat that way until 2026-09-04.
# claude-hook: PostToolUse
# --------------------------------------------------------------------
# PostToolUse hook — append a compact tool-call line to the session's instinct trace.
# FAST, no LLM, never blocks (always exit 0). instinct-extract.sh (daily) distills
# these traces into atomic "instincts" (ECC-style continuous-learning).
# Cost = zero here; the learning happens in one batched Haiku call per day.
set -uo pipefail
# jq lives at /usr/bin/jq on this Mac (NOT /opt/homebrew/bin — the old hardcoded
# path silently broke every field extraction and killed the whole learning loop)
JQ=$(command -v jq 2>/dev/null || echo /usr/bin/jq)
DATE=/bin/date
TDIR="$HOME/.claude/instincts/traces"
/bin/mkdir -p "$TDIR" 2>/dev/null

payload=$(/bin/cat 2>/dev/null)
[ -z "$payload" ] && exit 0

sid=$(printf '%s' "$payload" | "$JQ" -r '.session_id // "nosession"' 2>/dev/null); sid="${sid:0:16}"
cwd=$(printf '%s' "$payload" | "$JQ" -r '.cwd // "?"' 2>/dev/null)
tool=$(printf '%s' "$payload" | "$JQ" -r '.tool_name // "?"' 2>/dev/null)
detail=$(printf '%s' "$payload" | "$JQ" -r '(.tool_input.command // .tool_input.file_path // .tool_input.pattern // .tool_input.description // "")|tostring' 2>/dev/null)
detail="${detail:0:140}"

ts=$("$DATE" +%H:%M:%S 2>/dev/null || echo "--")
# tab-separated: time, cwd, tool, detail  (cwd lets the extractor scope instincts per project)
printf '%s\t%s\t%s\t%s\n' "$ts" "$cwd" "$tool" "$detail" >> "$TDIR/${sid}.trace" 2>/dev/null
exit 0
