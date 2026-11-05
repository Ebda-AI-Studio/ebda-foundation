#!/usr/bin/env bash
# skill-stocktake.sh — skill governance + provenance audit (ECC skill-stocktake).
# Inventories every skill, validates frontmatter (name/description/provenance),
# and flags: missing description, unknown provenance (supply-chain risk),
# duplicate names, and empty/stub skills. Read-only. Run periodically.
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/bin:/bin:$PATH"
DIRS=("$HOME/.claude/skills" "$HOME/.agents/skills")
tmp=$(mktemp); : >"$tmp"
n=0; noprov=0; nodesc=0; stub=0
echo "=== Skill stocktake ==="
for base in "${DIRS[@]}"; do
  [ -d "$base" ] || continue
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    n=$((n+1))
    name=$(awk -F': *' '/^name:/{print $2; exit}' "$f" 2>/dev/null)
    desc=$(awk '/^description:/{print; exit}' "$f" 2>/dev/null)
    # provenance: origin: or metadata.origin:
    prov=$(grep -iE "^\s*origin:|origin:" "$f" 2>/dev/null | head -1 | sed -E 's/.*origin: *//I')
    lines=$(wc -l <"$f" | tr -d ' ')
    echo "${name:-$(basename "$(dirname "$f")")}" >>"$tmp"
    flags=""
    [ -z "$prov" ] && { flags="$flags NO-PROVENANCE"; noprov=$((noprov+1)); }
    # description present? (may be multi-line; check the key exists with content on this or next line)
    if ! grep -qE "^description: *\S" "$f" && ! awk '/^description:/{getline; if($0 ~ /\S/) found=1} END{exit !found}' "$f"; then
      flags="$flags NO-DESC"; nodesc=$((nodesc+1)); fi
    [ "${lines:-0}" -lt 8 ] && { flags="$flags STUB"; stub=$((stub+1)); }
    [ -n "$flags" ] && printf '  ⚠ %-34s%s\n' "${name:-?}" "$flags"
  done < <(find "$base" -maxdepth 2 -name SKILL.md 2>/dev/null; find "$base" -maxdepth 1 -name '*.md' 2>/dev/null)
done
echo
echo "=== duplicates (same skill name in 2+ places) ==="
sort "$tmp" | uniq -d | sed 's/^/  ⚠ /' || echo "  none"
rm -f "$tmp"
echo
echo "summary: $n skills · $noprov no-provenance · $nodesc no-description · $stub stubs"
echo "provenance convention: add 'metadata.origin: ECC-adapted|community|force-ai|<upstream>' so installed/3rd-party skills are traceable (supply-chain)."
