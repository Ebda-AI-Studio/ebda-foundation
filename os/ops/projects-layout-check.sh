#!/usr/bin/env bash
# projects-layout-check.sh — every git repo under ~/Desktop/projects must sit in a
# slot defined by lib/projects-layout.sh. Exit 1 (and name it) for any repo that
# does not. Meta dirs (_worktrees, _backups, _archive, the memory vault) and
# symlinks (the legacy compat links) are ignored. A move that is declared but not
# yet done goes in ops/lib/projects-layout.pending.tsv (<relpath>\t<reason>): it is
# reported as PENDING and does not fail — so a pending move cannot be forgotten.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/lib/projects-layout.sh"
PENDING="${PROJECTS_LAYOUT_PENDING:-$HERE/lib/projects-layout.pending.tsv}"

# --refs <dir>: every literal ~/Desktop/projects/<path> in <dir>'s scripts must
# exist. A dead one is a silent coverage hole — the scanner "passes" over nothing.
# _worktrees/_backups paths are runtime/fixture patterns and are skipped.
if [ "${1:-}" = "--refs" ]; then
  dir="${2:?--refs needs a directory}"; dead=0
  while IFS= read -r p; do
    case "$p" in _worktrees/*|_backups/*|*__) continue ;; esac
    [ -e "$PROJECTS_ROOT/$p" ] || { echo "DEAD $p"; dead=$((dead+1)); }
  done < <(grep -rhoIE --exclude-dir=tests --exclude-dir=__pycache__ --exclude-dir=_retired --exclude='*.bak*' 'Desktop/projects/(calude code meomry|[A-Za-z0-9_.-]+)(/[A-Za-z0-9_.-]+){0,3}' "$dir" 2>/dev/null \
             | sed 's#^Desktop/projects/##' | sort -u)
  echo "projects-layout refs: $dead dead path(s) in $dir"
  [ "$dead" -eq 0 ]; exit
fi
R="$PROJECTS_ROOT"; bad=0; n=0
while IFS= read -r g; do
  repo="${g%/.git}"; [ "$repo" = "$R" ] && continue; rel="${repo#"$R"/}"; n=$((n+1))
  layout_slot_ok "$rel" && continue
  if [ -f "$PENDING" ] && reason=$(awk -F'\t' -v p="$rel" '$1==p{print $2; f=1} END{exit !f}' "$PENDING"); then
    echo "PENDING $rel — $reason"; continue
  fi
  echo "MISPLACED $rel"; bad=$((bad+1))
done < <(find "$R" -maxdepth 5 \
          \( -name node_modules -o -name _worktrees -o -name _backups -o -name _archive -o -name 'calude code meomry' -o -name .claude \) -prune \
          -o -name .git -print 2>/dev/null)
echo "projects-layout: $n repos, $bad misplaced"
[ "$bad" -eq 0 ]
