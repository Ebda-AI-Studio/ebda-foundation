#!/usr/bin/env bash
#
# launchd wrapper for auto-fix-check.sh. Sets up PATH (launchd has a minimal
# default) and ensures the gh + claude CLIs are findable.
#
set -uo pipefail

# Make sure gh, jq, curl, node, claude, brew-installed tools are on PATH.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$HOME/.nvm/versions/node/v20.20.2/bin:$PATH"

# Source nvm so 'node' works for claude-code's internal needs
if [[ -s "$HOME/.nvm/nvm.sh" ]]; then
  # shellcheck disable=SC1091
  source "$HOME/.nvm/nvm.sh"
  nvm use 20 >/dev/null 2>&1 || true
fi

# Run the check
exec bash "$HOME/.claude/scripts/auto-fix-check.sh"
