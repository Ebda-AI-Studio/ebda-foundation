#!/usr/bin/env bash
# --------------------------------------------------------------------
# claude-hook declaration — read by ops/dead-gate-detect.sh, which fails the
# OS self-check if a declared hook is not actually registered in
# ~/.claude/settings.json. A shipped-but-unwired hook never fires and reads
# as coverage; ops/self-eval-gate.sh sat that way until 2026-09-04.
# claude-hook: Stop
# --------------------------------------------------------------------
# self-eval-gate.sh — Stop hook. If this session edited multiple files, emit a
# SHORT reminder of the standing-rule gates (blast-radius, class, docs, tests)
# so a "done" claim doesn't skip them. Silent for read-only/tiny sessions — no
# noise. Never blocks (exit 0). Pairs with the agent-self-evaluation skill.
set -uo pipefail
JQ=$(command -v jq 2>/dev/null || echo /usr/bin/jq)
payload=$(/bin/cat 2>/dev/null)
sid=$(printf '%s' "$payload" | "$JQ" -r '.session_id // ""' 2>/dev/null); sid="${sid:0:16}"
trace="$HOME/.claude/instincts/traces/${sid}.trace"
[ -f "$trace" ] || exit 0
edits=$(/usr/bin/grep -cE $'\t'"(Edit|Write|NotebookEdit)"$'\t' "$trace" 2>/dev/null); edits=$(printf '%s' "${edits:-0}" | /usr/bin/tr -dc '0-9'); edits=${edits:-0}
[ "$edits" -lt 2 ] 2>/dev/null && exit 0

# Gate 4 (active) — a truncated blast-radius sweep is a recurring, memory-logged
# relapse (feedback-session-misses-2026-07-05): `grep ... | head/tail` caps the
# sweep, so a "clean" claim is unproven. A CLAUDE.md rule alone didn't hold it;
# detect the actual command in this session's trace and flag it specifically.
truncated=$(/usr/bin/grep -cE 'grep[^'$'\t'']*\|[[:space:]]*(head|tail)' "$trace" 2>/dev/null); truncated=$(printf '%s' "${truncated:-0}" | /usr/bin/tr -dc '0-9'); truncated=${truncated:-0}
if [ "$truncated" -gt 0 ] 2>/dev/null; then
  /bin/cat >&2 <<'EOF'
[self-eval gate — BLAST-RADIUS TRUNCATION DETECTED] This session ran `grep … | head/tail`.
  A truncated sweep does NOT prove "blast-radius clean". Re-run every identifier sweep
  WITHOUT head/tail (or with an explicit count) before any "done"/"clean" claim, and
  state the true result. This is a memory-logged recurring miss — do not repeat it.
EOF
fi
/bin/cat >&2 <<'EOF'
[self-eval gate] This session edited multiple files. Before "done":
  • blast-radius: grepped EVERY ref to changed identifiers? (state the result — don't `grep|head` it)
  • whole defect class fixed (siblings)? • every new data has UI?
  • docs updated same change? • tests actually ran (reported truthfully)?
  Run the `agent-self-evaluation` skill for the full 5-axis check.
EOF
exit 0
