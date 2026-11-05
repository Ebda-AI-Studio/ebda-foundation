#!/usr/bin/env bash
# Whisky AI OS — sessions-live.sh
#
# "Who else is working right now?" — lists Claude Code sessions active within
# the last WINDOW_MIN minutes by scanning transcript mtimes (every live session
# streams to its jsonl continuously, so mtime IS the heartbeat — no hooks, no
# registry to drift). Built 2026-07-12: sessions can't see each other, which
# caused branch collisions, a stash conflict, and duplicate work. Any session
# (or script) can now check before touching a repo:
#
#   sessions-live.sh            # human table
#   sessions-live.sh --json     # machine-readable (dashboard / other scripts)
#   WINDOW_MIN=60 sessions-live.sh
set -uo pipefail
JQ=$(command -v jq 2>/dev/null || echo /usr/bin/jq)
WINDOW_MIN="${WINDOW_MIN:-15}"
MODE="${1:-}"

rows=()
while IFS= read -r f; do
  sid=$(basename "$f" .jsonl)
  # cwd from the newest entry that carries one (tail keeps it cheap)
  cwd=$(tail -40 "$f" 2>/dev/null | "$JQ" -rs '[.[] | .cwd // empty] | last // "?"' 2>/dev/null)
  [ -z "$cwd" ] || [ "$cwd" = "null" ] && cwd="?"
  branch=""
  [ -d "$cwd" ] && branch=$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  age_s=$(( $(date +%s) - $(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0) ))
  rows+=("${sid:0:8}|${cwd}|${branch:--}|${age_s}")
done < <(find "$HOME/.claude/projects" -name '*.jsonl' -mmin "-$WINDOW_MIN" -type f 2>/dev/null)

if [ "$MODE" = "--json" ]; then
  printf '%s\n' "${rows[@]+"${rows[@]}"}" | "$JQ" -Rs 'split("\n") | map(select(length>0) | split("|") | {session: .[0], cwd: .[1], branch: .[2], idle_seconds: (.[3]|tonumber)})'
  exit 0
fi

echo "== live claude sessions (last ${WINDOW_MIN}m) =="
if [ "${#rows[@]}" -eq 0 ]; then echo "  none"; exit 0; fi
printf '  %-10s %-12s %-45s %s\n' "SESSION" "IDLE" "CWD" "BRANCH"
for r in ${rows[@]+"${rows[@]}"}; do
  IFS='|' read -r sid cwd branch age <<EOF
$r
EOF
  printf '  %-10s %-12s %-45s %s\n' "$sid" "${age}s" "${cwd/#$HOME/~}" "$branch"
done
