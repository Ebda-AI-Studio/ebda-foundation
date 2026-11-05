#!/usr/bin/env bash
# Whisky AI OS — migrate-claude-home.sh
#
# The ops installer moves the OS runtime (scripts/plists/dashboard), but the
# CLAUDE-HOME layer lives outside the repo and never migrated: global CLAUDE.md,
# settings.json (the PostToolUse/Stop/SessionStart hooks that feed the learning
# loop), skills, agents, workflows, commands, keybindings, scoped memory, and
# the instinct store. Without it a new Mac gets the launchd fleet but a Claude
# with no rules, no skills, and no memory. (Found 2026-07-11 preparing the
# ForceAI Studio move.)
#
#   ops/migrate-claude-home.sh export            # old Mac → ~/Desktop/claude-home-<date>.tgz
#   ops/migrate-claude-home.sh import <tarball>  # new Mac (run AFTER bootstrap.sh)
#
# Excluded on purpose: transcripts/caches (huge, machine-local), credentials
# (.credentials.json — re-auth per machine), plugin caches (reinstall), and
# projects' non-memory session state.
set -uo pipefail
. "$(dirname "$0")/lib/os-state.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-state.sh" 2>/dev/null || true

# TCC canary (2026-07-12): abort when the launchd context cannot see ~/Desktop
OS_JOB_NAME=migrate-claude-home
if command -v require_projects_access_critical >/dev/null 2>&1; then require_projects_access_critical || exit 0; fi

MODE="${1:-}"

INCLUDE=(
  "CLAUDE.md"
  "settings.json"
  "keybindings.json"
  "skills"
  "agents"
  "workflows"
  "commands"
  "instincts"
)

case "$MODE" in
  export)
    OUT="$HOME/Desktop/claude-home-$(date +%Y%m%d).tgz"
    # daily launchd run keeps a STABLE always-current copy + prunes dated ones
    # >2 days old (Ahmad 2026-07-12: "the installer must always be up to date")
    STABLE="$HOME/Desktop/claude-home-latest.tgz"
    cd "$HOME/.claude" || exit 1
    existing=()
    for p in "${INCLUDE[@]}"; do [ -e "$p" ] && existing+=("$p"); done
    # scoped memory: only the memory/ dirs under projects/, never transcripts.
    # null-delimited — project dir names contain spaces ("Force Media AI Buyer").
    mem_dirs=()
    while IFS= read -r -d '' d; do mem_dirs+=("$d"); done \
      < <(find projects -maxdepth 2 -type d -name memory -print0 2>/dev/null)
    tar czf "$OUT" \
      --exclude 'skills/*/node_modules' \
      --exclude 'skills/*/.git' \
      --exclude 'instincts/traces' \
      ${existing[@]+"${existing[@]}"} ${mem_dirs[@]+"${mem_dirs[@]}"}
    cp -f "$OUT" "$STABLE" 2>/dev/null || true
    find "$HOME/Desktop" -maxdepth 1 -name 'claude-home-2*.tgz' -mtime +2 -delete 2>/dev/null
    echo "exported → $OUT (+ $STABLE refreshed)"
    echo "contents:"; tar tzf "$OUT" | awk -F/ '{print "  "$1"/"$2}' | sort -u | head -30
    echo
    echo "NOT included (by design): ~/.claude/.credentials.json (re-run claude /login),"
    echo "  plugin caches (reinstall via marketplace), transcripts, ~/.whisky-*.env"
    echo "  (scp those two env files separately, per bootstrap.sh step 4)."
    ;;
  import)
    TAR="${2:-}"
    [ -f "$TAR" ] || { echo "usage: $0 import <claude-home-*.tgz>"; exit 1; }
    mkdir -p "$HOME/.claude"
    # refuse to clobber an already-populated brain without explicit consent
    if [ -s "$HOME/.claude/CLAUDE.md" ] && [ "${FORCE:-0}" != "1" ]; then
      echo "$HOME/.claude/CLAUDE.md already exists on this machine."
      echo "Re-run with FORCE=1 to overwrite, or merge manually."
      exit 1
    fi
    tar xzf "$TAR" -C "$HOME/.claude"
    echo "imported into ~/.claude — now:"
    echo "  1. claude /login   (hooks in settings.json need a working CLI)"
    echo "  2. re-run ops/install.sh so plists point at THIS machine's paths"
    echo "  3. verify: ops/os-selftest.sh (learning-loop check should pass within a day)"
    ;;
  *)
    echo "usage: $0 export | import <tarball>"; exit 1 ;;
esac
