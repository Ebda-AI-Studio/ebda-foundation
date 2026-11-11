#!/bin/sh
# claude-bundle-sync.sh (launchd ${OS_LAUNCHD_PREFIX}.claude-bundle-sync, WatchPaths on ~/.local/share/claude/versions)
#
# Keeps ~/.local/share/claude/ClaudeCode.app/Contents/MacOS/claude hardlinked to
# the current build, and points ~/.local/bin/claude at it.
#
# Running Claude from inside that bundle gives it ONE stable macOS TCC identity
# (CFBundleIdentifier com.anthropic.claude-code) instead of a new one per
# version, which is what made the Desktop / Downloads / Apple Music prompts come
# back after every update. Full rationale in ~/bin/claude.
#
# Idempotent. Safe to run from a WatchPaths LaunchAgent and from the wrapper.
set -e

CLAUDE_DIR="$HOME/.local/share/claude"
VERSIONS="$CLAUDE_DIR/versions"
BUNDLE="$CLAUDE_DIR/ClaudeCode.app"
BIN="$BUNDLE/Contents/MacOS/claude"
LINK="$HOME/.local/bin/claude"

newest=$(readlink "$LINK" 2>/dev/null || true)
case "$newest" in
  "$VERSIONS"/*) ;;
  *) # LINK already points at the bundle -> most recently installed build.
     # Pick the newest EXECUTABLE entry, so a partial download in flight can't
     # stall the sync.
     newest=""
     # shellcheck disable=SC2045 # mtime order needs ls -t; entries are version strings (no spaces)
     for n in $(ls -t "$VERSIONS" 2>/dev/null); do
       if [ -x "$VERSIONS/$n" ] && [ -f "$VERSIONS/$n" ]; then newest="$VERSIONS/$n"; break; fi
     done ;;
esac

[ -n "$newest" ] && [ -x "$newest" ] || exit 0

ino() { stat -c %i "$1" 2>/dev/null || stat -f %i "$1"; }   # GNU first (repo rule), BSD fallback
if [ ! -e "$BIN" ] || [ "$(ino "$newest")" != "$(ino "$BIN")" ]; then
  mkdir -p "$BUNDLE/Contents/MacOS"
  rm -f "$BIN"
  ln "$newest" "$BIN" 2>/dev/null || cp -f "$newest" "$BIN"
fi

if [ "$(readlink "$LINK" 2>/dev/null)" != "$BIN" ]; then
  ln -sfn "$BIN" "$LINK" 2>/dev/null || true
fi
