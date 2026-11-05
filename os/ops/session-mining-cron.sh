#!/usr/bin/env bash
# Whisky AI OS — session-mining-cron.sh (monthly, launchd ${OS_LAUNCHD_PREFIX}.session-mining)
#
# Runs the session-mining skill headlessly over the last ~60 session transcripts:
# recurring requests, corrections, rituals, broken automation → candidate skills /
# script fixes / memory. Complements the DAILY instinct-extract (atomic tool-trace
# instincts); THIS is the deep monthly pass that reads what Ahmad actually asked.
# Born 2026-07-11 after the same mining request was made manually in 3+ sessions.
#
# Output: ~/.claude/instincts/session-mining-<YYYY-MM>.md + Telegram digest.
# shellcheck source=lib/os-config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/os-config.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-config.sh" 2>/dev/null || true
command -v os_config_load >/dev/null 2>&1 && os_config_load
set -uo pipefail
# claude CLI crashes under Homebrew node 25 — prefer nvm node 24 (same fix as
# instinct-extract.sh; see feedback-session-mining-learning-loop.md).
NODE24_BIN=$(ls -d "$HOME/.nvm/versions/node/v24"*/bin 2>/dev/null | tail -1)
export PATH="${NODE24_BIN:+$NODE24_BIN:}$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
# CLAUDE_BIN lets a test point this at a stub. Without it the model call is
# untestable offline, which is why none of the OS's 17 model-calling scripts
# had a single behavioural test. Defaults to the real CLI.
CLAUDE_BIN="${CLAUDE_BIN:-claude}"

OUT_DIR="$HOME/.claude/instincts"
REPORT="$OUT_DIR/session-mining-$(date +%Y-%m).md"
LOG="$HOME/Library/Logs/forceai-session-mining.log"
mkdir -p "$OUT_DIR"

echo "$(date +%Y-%m-%dT%H:%M:%S) session-mining start" >> "$LOG"

PROMPT="Use the session-mining skill on the last 60 sessions. Follow it fully:
health-check the continuous-learning loop first, extract user-side messages
mechanically, fan out analysis, and produce findings. Write the final report to
$REPORT (markdown: loop health, recurring patterns with evidence counts, waste
found in headless templates, and a ranked list of candidate skills/fixes —
excluding automation that already exists). Do NOT create skills or edit scripts
in this headless run — report only; Ahmad reviews and applies interactively."

# bound the run at 40 min; one worker, never parallel (token discipline)
if command -v gtimeout >/dev/null 2>&1; then
  gtimeout 2400 "$CLAUDE_BIN" -p "$PROMPT" >> "$LOG" 2>&1
else
  perl -e 'alarm 2400; exec @ARGV' "$CLAUDE_BIN" -p "$PROMPT" >> "$LOG" 2>&1
fi
rc=$?

if [ -s "$REPORT" ]; then
  summary=$(head -20 "$REPORT" | tr '\n' ' ' | cut -c1-300)
  [ -x "$HOME/.claude/scripts/notify.sh" ] && \
    "$HOME/.claude/scripts/notify.sh" "🧠 monthly session-mining report ready" \
      "$REPORT — $summary" >/dev/null 2>&1
  echo "$(date +%Y-%m-%dT%H:%M:%S) session-mining done rc=$rc report=$REPORT" >> "$LOG"
else
  [ -x "$HOME/.claude/scripts/notify.sh" ] && \
    "$HOME/.claude/scripts/notify.sh" "⚠️ monthly session-mining produced NO report" \
      "rc=$rc — check $LOG" >/dev/null 2>&1
  echo "$(date +%Y-%m-%dT%H:%M:%S) session-mining FAILED rc=$rc (no report)" >> "$LOG"
fi
exit 0
