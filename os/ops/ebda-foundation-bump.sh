#!/usr/bin/env bash
# Mac launchd fallback for the foundation bump bot (F11, Ruling FDN-BUMP-1). The PRIMARY path is .github/workflows/foundation-bump.yml (tag push);
# this runs the SAME script (ops/bump-consumers.mjs) from the local foundation checkout at the latest tag, for when Actions is unavailable.
# OFF BY DEFAULT: does nothing unless ~/.claude/ebda-foundation-bump.enabled exists. Without --apply it is a dry run. It never merges.
# usage: ebda-foundation-bump.sh [--apply]      log: ~/Library/Logs/ebda-foundation-bump.log (launchd ${OS_LAUNCHD_PREFIX}.ebda-foundation-bump, 09:17)
# shellcheck source=lib/os-config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/os-config.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-config.sh" 2>/dev/null || true
command -v os_config_load >/dev/null 2>&1 && os_config_load
set -uo pipefail
APPLY=0; [ "${1:-}" = "--apply" ] && APPLY=1
ROOT="${EBDA_ROOT:-$OS_PROJECTS_DIR/$OS_ORG/internal-projects}"
FOUNDATION="${EBDA_FOUNDATION_DIR:-$ROOT/ebda-foundation}"
ENABLED="${EBDA_BUMP_ENABLED_FILE:-$HOME/.claude/ebda-foundation-bump.enabled}"
log() { echo "$(date '+%F %T') ebda-foundation-bump: $*"; }

[ -f "$ENABLED" ] || { log "disabled (no $ENABLED); nothing to do"; exit 0; }
[ -d "$FOUNDATION/.git" ] || { log "no foundation checkout at $FOUNDATION"; exit 0; }
git -C "$FOUNDATION" fetch -q --tags origin || { log "fetch failed"; exit 1; }
latest="$(git -C "$FOUNDATION" tag -l 'v[0-9]*.[0-9]*.[0-9]*' --sort=-v:refname | head -1)"
[ -n "$latest" ] || { log "no foundation tag yet"; exit 0; }

# The bot syncs the checkout it runs from: use a throwaway worktree at the tag so the root checkout stays on main.
wt="$(mktemp -d)"
trap 'git -C "$FOUNDATION" worktree remove --force "$wt" >/dev/null 2>&1; rm -rf "$wt"' EXIT
git -C "$FOUNDATION" worktree add -q --detach "$wt/f" "$latest" || { log "cannot check out $latest"; exit 1; }
args=(--tag "$latest"); [ "$APPLY" = 1 ] || args+=(--dry-run)
log "$latest ${args[*]}"
node "$wt/f/ops/bump-consumers.mjs" "${args[@]}"
