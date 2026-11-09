#!/usr/bin/env bash
# --------------------------------------------------------------------
# claude-hook declaration — read by ops/dead-gate-detect.sh, which fails the
# OS self-check if a declared hook is not actually registered in
# ~/.claude/settings.json. A shipped-but-unwired hook never fires and reads
# as coverage; ops/self-eval-gate.sh sat that way until 2026-09-04.
# claude-hook: SessionStart
# --------------------------------------------------------------------
# Auto-rename Claude Code sessions to the current project directory name.
#
# Triggered by SessionStart hook in ~/.claude/settings.json. Sends the
# `/rename <basename>` slash command to the running session so its name
# in /resume, FleetView, claude.ai/code, and the terminal title (when
# terminalTitleFromRename:true) reflects the project being worked in.
#
# Edge cases handled:
#   - $PWD = $HOME (no project)        → skip rename (would be "ahmadsharaf")
#   - $PWD under ~/Downloads / Desktop → skip rename (transient dirs)
#   - basename starts with .           → skip rename (hidden dir)
#   - basename empty / "/" / null      → skip rename
#
# Per Claude Code docs, the SessionStart hook fires AFTER session
# creation, so the rename takes effect ~1-2s after the prompt appears.
# That's the best we can do without an at-startup --name flag.

set -e

cwd="${CLAUDE_PROJECT_DIR:-$PWD}"
home_clean="${HOME%/}"

# Skip if we're literally in $HOME
if [[ "$cwd" == "$home_clean" ]]; then
  exit 0
fi

base="$(basename "$cwd")"

# Skip transient / hidden / empty
case "$base" in
  ""|/|.*|Downloads|Desktop|Documents|Movies|Music|Pictures)
    exit 0
    ;;
esac

# Emit the rename slash command. Claude Code reads stdout from hooks
# and treats lines starting with `/` as slash commands when emitted
# during SessionStart.
echo "/rename $base"
