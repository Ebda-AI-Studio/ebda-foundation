#!/usr/bin/env bash
# One-shot: move IDLE worktrees from the internal root to the SSD root and leave a symlink at the old path.
#
#   bash migrate-worktrees-to-ssd.sh            # dry run: lists what WOULD move and what is busy
#   bash migrate-worktrees-to-ssd.sh --apply    # actually move
#   bash migrate-worktrees-to-ssd.sh --apply --deps   # also re-clone node_modules on the SSD via wt-deps.sh
#
# Rules (measured on the disk, not assumed):
#  - source = <internal root> (lib/wt-roots.sh wt_internal_root); destination = <SSD>/_worktrees at the same relative path.
#    No SSD mounted -> exit 2, nothing touched.
#  - a worktree is BUSY when any process has its cwd inside it (lsof). A busy one is REFUSED (left in place, exit 1 at the end).
#  - clean or dirty both move: git state (HEAD, branch, index, uncommitted + untracked files) is copied with rsync -a. Git cannot
#    `worktree move` across volumes (rename = EXDEV), so: copy, `git worktree repair` from the copy, verify HEAD + status count
#    are identical, THEN replace the old dir with a symlink. Any verify failure removes the copy and keeps the original.
#  - node_modules is NOT copied (a cross-volume copy cannot clone; it is rebuildable). --deps runs wt-deps.sh on the new copy.
#  - already a symlink, or already on the SSD -> skipped. Re-running is safe (idempotent).
# shellcheck source=lib/os-config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/os-config.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-config.sh" 2>/dev/null || true
command -v os_config_load >/dev/null 2>&1 && os_config_load
. "$(dirname "${BASH_SOURCE[0]}")/lib/wt-roots.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/wt-roots.sh" 2>/dev/null || { echo "missing lib/wt-roots.sh" >&2; exit 2; }
. "$(dirname "${BASH_SOURCE[0]}")/lib/wt-safety.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/wt-safety.sh" 2>/dev/null || { echo "missing lib/wt-safety.sh" >&2; exit 2; }
set -uo pipefail
APPLY=0; DEPS=0
for a in "$@"; do case "$a" in --apply) APPLY=1 ;; --deps) DEPS=1 ;; -h|--help) sed -n 2,18p "$0"; exit 0 ;; *) echo "unknown arg $a" >&2; exit 2 ;; esac; done

SSD="$(wt_ssd_root)"
[ -n "$SSD" ] || { echo "SSD ${OS_SSD_ROOT:-/Volumes/Ebda} is not mounted/writable - nothing to do" >&2; exit 2; }
SRC="$(wt_internal_root)"; DST="$SSD/_worktrees"
[ -d "$SRC" ] || { echo "no internal worktree root at $SRC - nothing to do"; exit 0; }
mkdir -p "$DST" || exit 2
live_cwds="${MIGRATE_LIVE_CWDS-$(lsof -a -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')}"

moved=0; busy=0; skipped=0; failed=0
while IFS= read -r wt; do
  [ -n "$wt" ] || continue
  rel="${wt#"$SRC"/}"
  if [ -L "$wt" ]; then skipped=$((skipped+1)); continue; fi
  [ -e "$wt/.git" ] || { echo "skip (not a worktree): $rel"; skipped=$((skipped+1)); continue; }
  p="$(cd "$wt" && pwd -P)"
  if printf '%s\n' "$live_cwds" | awk -v p="$p" '$0==p || index($0, p"/")==1 {f=1} END{exit !f}'; then
    echo "BUSY (a process is inside) - refused: $rel"; busy=$((busy+1)); continue
  fi
  dest="$DST/$rel"
  if [ -e "$dest" ]; then echo "skip (destination exists): $rel"; skipped=$((skipped+1)); continue; fi
  if [ "$APPLY" = 0 ]; then echo "would move: $rel -> $dest"; moved=$((moved+1)); continue; fi
  head_before="$(git -C "$wt" rev-parse HEAD 2>/dev/null)"; st_before="$(git -C "$wt" status --porcelain --untracked-files=all 2>/dev/null | wc -l | tr -d ' ')"
  mkdir -p "$(dirname "$dest")"
  if ! rsync -a --exclude node_modules "$wt/" "$dest/"; then echo "FAILED copy: $rel (original kept)"; rm -rf "$dest"; failed=$((failed+1)); continue; fi
  git -C "$dest" worktree repair >/dev/null 2>&1
  head_after="$(git -C "$dest" rev-parse HEAD 2>/dev/null)"; st_after="$(git -C "$dest" status --porcelain --untracked-files=all 2>/dev/null | wc -l | tr -d ' ')"
  # node_modules is gitignored, so it never shows in status; any other difference means the copy is not the same tree
  if [ -z "$head_before" ] || [ "$head_before" != "$head_after" ] || [ "$st_before" != "$st_after" ]; then
    echo "FAILED verify: $rel (HEAD $head_before/$head_after, status $st_before/$st_after) - copy removed, original kept"
    rm -rf "$dest"; git -C "$wt" worktree repair >/dev/null 2>&1; failed=$((failed+1)); continue
  fi
  rm -rf "$wt" && ln -s "$dest" "$wt" && git -C "$dest" worktree repair >/dev/null 2>&1
  echo "moved: $rel -> $dest"; moved=$((moved+1))
  if [ "$DEPS" = 1 ] && [ -f "$dest/package.json" ]; then bash "$(dirname "${BASH_SOURCE[0]}")/wt-deps.sh" "$dest" || echo "WARN: wt-deps failed for $dest" >&2; fi
done < <(wt_candidates "$SRC")

echo "---"; echo "moved=$moved busy=$busy skipped=$skipped failed=$failed ($([ "$APPLY" = 1 ] && echo applied || echo dry-run))"
[ "$busy" = 0 ] && [ "$failed" = 0 ]
