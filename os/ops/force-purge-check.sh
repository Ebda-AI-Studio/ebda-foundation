#!/usr/bin/env bash
# force-purge-check.sh - read-only purge readiness: lists everything on this Mac still tied to the predecessor business. Deletes nothing, ever.
# Categories (each hit prints as "  <path>[:line]"; content is never printed, so secrets cannot leak):
#   symlinks         ~/.claude/** symlinks whose target is inside Force-AI/
#   launchd-plists   ~/Library/LaunchAgents plists named com.forceai.* or com.salam.erp-backup (a disabled plist is still a hit)
#   launchd-content  other LaunchAgents files that name the predecessor
#   scripts          ~/.claude/scripts files that name it
#   settings         ~/.claude/settings*.json that name it
#   instructions     ~/.claude/CLAUDE.md and ~/AGENTS.md that name it
#   repo-docs        repos under projects/{Ebda-AI-Studio,Whisky-11,Personal} that reference force-ai-foundation (docs included)
#   memory-vault     the memory vault's git remote points at the predecessor org (decision OD-1: move to voidengineer-911)
# Exit 0 only with zero hits; otherwise exit 1 with a per-category count.
# Usage: force-purge-check.sh [--home DIR] [--projects DIR]   (defaults: $HOME, $HOME/Desktop/projects)
set -uo pipefail
case "${1:-}" in -h|--help) sed -n 2,14p "${BASH_SOURCE[0]}" | sed "s/^# \{0,1\}//"; exit 0 ;; esac
H="$HOME"; P=""; ARG_P=""
while [ $# -gt 0 ]; do
  case "$1" in
    --home) H="${2:?--home needs a directory}"; shift 2 ;;
    --projects) ARG_P="${2:?--projects needs a directory}"; shift 2 ;;
    *) echo "force-purge-check: unknown arg $1" >&2; exit 2 ;;
  esac
done
[ -d "$H" ] || { echo "force-purge-check: no such home $H" >&2; exit 2; }
HOME="$H"; export HOME   # the config loader derives its defaults from HOME, so a fake --home stays fake
# shellcheck source=lib/os-config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/os-config.sh" 2>/dev/null || . "$H/.claude/scripts/lib/os-config.sh" 2>/dev/null || { echo "force-purge-check: cannot load os-config.sh" >&2; exit 2; }
os_config_load
P="${ARG_P:-$OS_PROJECTS_DIR}"
RE='force-ai-foundation|ForceAI-KW|com\.forceai'
CNT="$(mktemp)"; trap 'rm -f "$CNT"' EXIT
section() { # section <name> <description>; hits on stdin
  local name="$1" desc="$2" lines n
  lines="$(sort -u)"; n=0; [ -n "$lines" ] && n="$(printf '%s\n' "$lines" | wc -l | tr -d ' ')"
  echo "== $name ($n) - $desc"
  [ "$n" -gt 0 ] && printf '%s\n' "$lines" | sed 's/^/  /'
  echo "$name $n" >> "$CNT"
}
# print "path:line" per match, never content; the path is printed by us (not split out of grep output), so ':' in paths is safe
refs() { local f="$1" n; grep -InE "$RE" -- "$f" 2>/dev/null | cut -d: -f1 | while IFS= read -r n; do printf '%s:%s\n' "$f" "$n"; done; }
# follow a symlink chain hop by hop (readlink without -f is portable); print "link -> hop" for the first hop inside Force-AI/
chain_hit() {
  local cur="$1" t i=0 first=""
  while [ -L "$cur" ] && [ "$i" -lt 40 ]; do
    t="$(readlink "$cur")"; case "$t" in /*) ;; *) t="$(dirname "$cur")/$t" ;; esac
    case "/$t/" in */Force-AI/*) first="${first:-$t}" ;; esac
    cur="$t"; i=$((i+1))
  done
  case "/$cur/" in */Force-AI/*) first="${first:-$cur}" ;; esac
  [ -n "$first" ] && printf '%s -> %s\n' "$1" "$first"
  return 0
}

{ [ -d "$H/.claude" ] && find "$H/.claude" \( -name node_modules -o -name .git \) -prune -o -type l -print 2>/dev/null |
  while IFS= read -r l; do chain_hit "$l"; done; } | section symlinks "claude-dir symlinks (any hop of the chain) resolving into Force-AI/"

{ for p in "$H"/Library/LaunchAgents/com.forceai.*.plist "$H"/Library/LaunchAgents/com.salam.erp-backup.plist; do [ -e "$p" ] && echo "$p"; done; } | section launchd-plists "predecessor LaunchAgents (disabled plists count)"

{ [ -d "$H/Library/LaunchAgents" ] && find "$H/Library/LaunchAgents" -type f 2>/dev/null | while IFS= read -r f; do refs "$f"; done; } | section launchd-content "LaunchAgents files naming the predecessor"

{ [ -d "$H/.claude/scripts" ] && find "$H/.claude/scripts" \( -name node_modules -o -name .git \) -prune -o -type f -print 2>/dev/null | while IFS= read -r f; do refs "$f"; done; } | section scripts "claude scripts files naming the predecessor"

{ for f in "$H"/.claude/settings*.json; do [ -f "$f" ] && refs "$f"; done; } | section settings "claude settings*.json naming the predecessor"

{ for f in "$H/.claude/CLAUDE.md" "$H/AGENTS.md"; do [ -f "$f" ] && refs "$f"; done; } | section instructions "CLAUDE.md / AGENTS.md naming the predecessor"

{ for b in $OS_NONFORCE_BUSINESS_DIRS; do [ -d "$P/$b" ] &&
    grep -rIlE 'force-ai-foundation' --exclude-dir=node_modules --exclude-dir=.git --exclude-dir=.next --exclude-dir=dist --exclude-dir=graphify-out "$P/$b" 2>/dev/null; done; } | section repo-docs "files in non-predecessor repos referencing force-ai-foundation"

{ v="$P/calude code meomry"; [ -d "$v/.git" ] || [ -f "$v/.git" ] && { u="$(git -C "$v" remote get-url origin 2>/dev/null)"; case "$u" in *ForceAI-KW/*) echo "$v remote=$u" ;; esac; }; } | section memory-vault "vault remote on the predecessor org (OD-1)"

total="$(awk '{t+=$2} END{print t+0}' "$CNT")"; summary="$(awk '{printf "%s=%s ", $1, $2}' "$CNT")"
echo "force-purge-check: $total hit(s) [ $summary]"
[ "$total" -gt 0 ] && exit 1
echo "force-purge-check: clear"
exit 0
