# shellcheck shell=bash
# Deterministic Class-A fixers + operational (gate-exempt) actions. All idempotent.

is_operational() { case "$1" in graph-pending|dr-dump-missing) return 0;; *) return 1;; esac; }

# fix_lockfile_drift <repo> : regenerate lockfile, verify, stage ONLY the lockfile.
fix_lockfile_drift() {
  local repo="$1"; [ -d "$repo" ] || return 1
  ( cd "$repo" || exit 1
    npm install >/dev/null 2>&1 || exit 1
    npm ci --dry-run >/dev/null 2>&1 || { echo "npm ci still not clean" >&2; exit 1; }
    git diff --quiet -- package-lock.json && exit 0   # already in sync -> no-op
    git add package-lock.json
  )
}

op_graphify() { local repo="$1"; ( cd "$repo" && graphify update . >/dev/null 2>&1 ); }
op_dr_backup() { local proj="$1"; "$HOME/.claude/scripts/backup-all-neon.sh" "$proj" >/dev/null 2>&1 || return 1; }