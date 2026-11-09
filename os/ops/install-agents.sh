#!/usr/bin/env bash
# Symlink the version-controlled agents/*.md into ~/.claude/agents/.
# agents/ in this repo is the source of truth; ~/.claude/agents/*.md used to be
# plain files. Never silently drop a hand-edited one:
#   - already the right symlink                      -> leave alone
#   - real file identical to the repo copy, or to the copy from the commit that
#     first added it (the vendored original)         -> replace with a symlink
#   - real file that differs (a hand edit)           -> MOVE it to
#     ~/.claude/agents/.pre-foundation-backup/, then symlink
# Usage: ops/install-agents.sh      (HOME may be overridden; used by the test)
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${AGENTS_SRC:-$REPO/agents}"
DEST="$HOME/.claude/agents"
BACKUP="$DEST/.pre-foundation-backup"
[ -d "$SRC" ] || { echo "install-agents: no $SRC (run from the foundation checkout, not the installed copy)" >&2; exit 1; }
# Trust boundary: a symlink makes the checked-out text LIVE in every session. Link only
# from the main checkout on master/main — never a linked worktree or feature branch
# (unreviewed agents would go live; links dangle after worktree cleanup).
# Tests override with OS_LINK_ANY_CHECKOUT=1.
if [ "${OS_LINK_ANY_CHECKOUT:-0}" != 1 ]; then
  gd="$(git -C "$REPO" rev-parse --absolute-git-dir 2>/dev/null || true)"
  cd_="$(cd "$REPO" && cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd || true)"
  br="$(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  if [ "$gd" != "$cd_" ] || { [ "$br" != master ] && [ "$br" != main ]; }; then
    echo "install-agents: SKIP — $REPO is not the main checkout on master/main (branch $br); run from the main checkout" >&2
    exit 0
  fi
fi
mkdir -p "$DEST"

n_link=0; n_same=0; n_backup=0
for f in "$SRC/"*.md; do
  [ -f "$f" ] || continue
  b="$(basename "$f")"; t="$DEST/$b"
  if [ -L "$t" ]; then
    if [ "$(readlink "$t")" = "$f" ]; then n_same=$((n_same+1)); continue; fi
    ln -sfn "$f" "$t"; n_link=$((n_link+1)); continue
  fi
  if [ -e "$t" ]; then
    replace=0
    if cmp -s "$f" "$t"; then replace=1
    else
      # content of the commit that first added this agent (the vendored original)
      first="$(git -C "$REPO" log --diff-filter=A --format=%H -- "agents/$b" 2>/dev/null | tail -n 1 || true)"
      if [ -n "$first" ] && git -C "$REPO" show "$first:agents/$b" 2>/dev/null | cmp -s - "$t"; then replace=1; fi
    fi
    if [ "$replace" = 0 ]; then
      mkdir -p "$BACKUP"
      dst="$BACKUP/$b"; [ -e "$dst" ] && dst="$BACKUP/$b.$(date +%Y%m%d%H%M%S)"
      mv "$t" "$dst"; n_backup=$((n_backup+1))
      echo "  backed up hand-edited $b -> $dst"
    else
      rm -f "$t"
    fi
  fi
  ln -s "$f" "$t"; n_link=$((n_link+1))
done
echo "agents: linked $n_link, already linked $n_same, backed up $n_backup (into $BACKUP)"
