# shellcheck shell=bash
# ops/lib/projects-layout.sh — the ONE definition of where a repo lives under
# $OS_PROJECTS_DIR. Sourced by lib/os-state.sh (resolve_repo_dir),
# new-task-worktree.sh and projects-layout-check.sh.
#
# Layout — every business is a folder with everything about it:
#   <business>/ internal-projects/<repo>   clients/<client>/<repo>   business/ (docs, never cloud-synced)
#   <business>/studio/  app/ = ONE git repo (the studio code, Ahmad 2026-11-09); business/ + shared/ = LOCAL media, never git or cloud
#   Personal/   projects/<repo>            documents/  (local, never cloud-synced)
#   _worktrees  _backups  _archive  "calude code meomry"  — meta, not slots
# <business> is any top-level folder that is not meta or Personal (Ebda-AI-Studio, Whisky-11, ...), so a
# new business needs no code change here.
# The pre-2026-09-25 paths (top level, _clients, _personal, _landing-pages) exist
# only as compat symlinks and are searched LAST.
# shellcheck source=os-config.sh
command -v os_config_load >/dev/null 2>&1 || . "$(dirname "${BASH_SOURCE[0]}")/os-config.sh" 2>/dev/null || true
[ -n "${OS_ORG:-}" ] || ! command -v os_config_load >/dev/null 2>&1 || os_config_load
PROJECTS_ROOT="${PROJECTS_ROOT:-$OS_PROJECTS_DIR}"

# resolve_repo_dir <name> — echo the checkout dir for a repo name; 1 if none.
resolve_repo_dir() {
  local r="$PROJECTS_ROOT" c name="$1"
  # Compatibility for queued work created before the product was named Ebda Store.
  [ "$name" = ebda ] && name=ebda-store
  for c in "$r"/*/internal-projects/"$name" "$r/Personal/projects/$name" "$r"/*/clients/*/"$name" \
           "$r/$name" "$r/_clients/$name" "$r/_personal/$name" "$r/_landing-pages/$name"; do
    case "$c" in "$r"/_*|"$r"/calude*) continue ;; esac
    if [ -d "$c" ]; then printf '%s\n' "$c"; return 0; fi
  done
  return 1
}

# layout_slot_ok <path relative to PROJECTS_ROOT> — 0 if it is a valid repo slot.
layout_slot_ok() {
  case "$1" in
    _*|calude*) return 1 ;;
    */internal-projects/*/*|Personal/projects/*/*) return 1 ;;
    */internal-projects/*|Personal/projects/*) return 0 ;;
    */clients/*/*/*) return 1 ;;
    */clients/*/*) return 0 ;;
    */studio/app/*) return 1 ;;
    */studio/app) return 0 ;;
    *) return 1 ;;
  esac
}

# list_repo_roots — print every repo checkout, one per line: all business-folder
# slots plus legacy _clients (pending moves). Symlinks, worktrees, backups and the
# archive are never listed. THE way to enumerate repos: a hand-written
# "$PROJECTS"/*/ glob or find -maxdepth 1 went blind when the 2026-09-25 reorg put
# repos 2-3 levels deep (tests/projects-layout.test.sh fails on a new one).
list_repo_roots() {
  local r="$PROJECTS_ROOT" d
  for d in "$r"/*/internal-projects/*/ "$r"/Personal/projects/*/ "$r"/*/clients/*/*/ "$r"/*/studio/app/ "$r"/_clients/*/; do
    case "$d" in "$r"/_worktrees/*|"$r"/_backups/*|"$r"/_archive/*|"$r"/calude*) continue ;; esac
    d="${d%/}"
    [ -L "$d" ] && continue
    if [ -d "$d/.git" ] || [ -f "$d/.git" ]; then printf '%s\n' "$d"; fi
  done
}
