# shellcheck shell=bash
# lib/wt-roots.sh - the ONE resolver for where task worktrees and the wt-deps dependency cache live.
#
# WHY (2026-11-19): the internal disk was 96% full; an external APFS SSD (/Volumes/Ebda) has ~950 GB free.
# New worktrees + the cache go there. GitHub runners stay on the internal disk (macOS TCC blocks launchd
# runners from removable volumes) - nothing here touches them.
#
#   wt_ssd_root          the SSD mount point if mounted AND writable, else empty ($OS_SSD_ROOT, default /Volumes/Ebda)
#   wt_internal_root     $OS_PROJECTS_DIR/_worktrees
#   wt_worktree_root     $OS_WORKTREE_ROOT if set, else <ssd>/_worktrees, else the internal root
#   wt_cache_root        $OS_DEPS_CACHE (then legacy $WT_DEPS_CACHE) if set, else <ssd>/.cache/wt-deps, else ~/.cache/wt-deps
#   wt_all_roots         every EXISTING worktree root (internal, SSD, override), one per line, no duplicates;
#                        listers/cleaners iterate this so a tree is found on either volume and a missing root is skipped
#   wt_free_kb <path>    free KB of the volume <path> is (or WOULD be) on: df of its nearest existing ancestor
#   wt_warn_fallback     one stderr line when the SSD was used before but is gone now (no noise on a machine without one)
#
# Cache and worktrees must share a volume for APFS clones; wt-deps.sh already falls back to a plain install when
# they do not. "Mounted" = writable directory: an unmounted /Volumes/Ebda is a root-owned leftover, not writable.
# bash 3.2 safe.

wt_ssd_root() {
  local s="${OS_SSD_ROOT:-/Volumes/Ebda}"
  if [ -d "$s" ] && [ -w "$s" ]; then printf '%s' "$s"; fi
  return 0
}
wt_internal_root() {
  if [ -z "${OS_PROJECTS_DIR:-}" ]; then
    command -v os_config_load >/dev/null 2>&1 || . "$(dirname "${BASH_SOURCE[0]}")/os-config.sh" 2>/dev/null || true
    command -v os_config_load >/dev/null 2>&1 && os_config_load
  fi
  printf '%s/_worktrees' "${OS_PROJECTS_DIR:?wt-roots: OS_PROJECTS_DIR unset and os-config not loadable}"
}
_wt_seen_stamp() { printf '%s' "${OS_STATE_DIR:-$HOME/.whisky-os-state}/wt-ssd-seen"; }
wt_worktree_root() {
  local s
  if [ -n "${OS_WORKTREE_ROOT:-}" ]; then printf '%s' "$OS_WORKTREE_ROOT"; return 0; fi
  s="$(wt_ssd_root)"
  if [ -n "$s" ]; then
    mkdir -p "$(dirname "$(_wt_seen_stamp)")" 2>/dev/null && : > "$(_wt_seen_stamp)" 2>/dev/null
    printf '%s/_worktrees' "$s"
  else
    wt_internal_root
  fi
}
wt_cache_root() {
  local s
  if [ -n "${OS_DEPS_CACHE:-}" ]; then printf '%s' "$OS_DEPS_CACHE"; return 0; fi
  if [ -n "${WT_DEPS_CACHE:-}" ]; then printf '%s' "$WT_DEPS_CACHE"; return 0; fi
  s="$(wt_ssd_root)"
  if [ -n "$s" ]; then printf '%s/.cache/wt-deps' "$s"; else printf '%s' "$HOME/.cache/wt-deps"; fi
}
wt_all_roots() {
  local r s out="" seen=""
  s="$(wt_ssd_root)"
  for r in "$(wt_internal_root)" ${s:+"$s/_worktrees"} ${OS_WORKTREE_ROOT:+"$OS_WORKTREE_ROOT"}; do
    [ -d "$r" ] || continue
    case "
$seen
" in *"
$r
"*) continue ;; esac
    seen="$seen
$r"
    printf '%s\n' "$r"
  done
  return 0
}
wt_free_kb() {
  local p="${1:-$HOME}"
  while [ ! -d "$p" ] && [ "$p" != "/" ] && [ -n "$p" ]; do p="$(dirname "$p")"; done
  df -k "$p" 2>/dev/null | awk 'NR==2{print $4}'
}
wt_warn_fallback() {
  if [ -z "$(wt_ssd_root)" ] && [ -z "${OS_WORKTREE_ROOT:-}" ] && [ -f "$(_wt_seen_stamp)" ]; then
    echo "WARN: SSD ${OS_SSD_ROOT:-/Volumes/Ebda} is not mounted - using the INTERNAL disk for worktrees (mount it and re-run to use the SSD)." >&2
  fi
  return 0
}
