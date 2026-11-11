#!/usr/bin/env bash
# --------------------------------------------------------------------
# claude-hook declaration — read by ops/dead-gate-detect.sh, which fails the
# OS self-check if a declared hook is not actually registered in
# ~/.claude/settings.json. A shipped-but-unwired hook never fires and reads
# as coverage; ops/self-eval-gate.sh sat that way until 2026-09-04.
# claude-hook: SessionStart
# claude-hook: PreCompact
# --------------------------------------------------------------------
# Whisky AI OS — session handoff + context hygiene.
#
# Every working session keeps a handoff.md with 5 sections (Goal · Current state
# · Done · In progress · Left to do), so a /clear or a fresh session is always
# LOSSLESS.
#
# The file is PER SESSION: <repo>/.handoff/<session-id>.md, or
# ~/.claude/handoff/<session-id>.md outside a repo. It used to be one shared
# path per project, and on 2026-08-26 two parallel sessions — both started
# outside a repo, so both resolving to ~/.claude/handoff.md — destroyed each
# other's state: the second session's write wiped the first's entire handoff,
# silently. This script never writes handoff CONTENT (the model does, with
# Write/Edit), so the only fix that actually holds is for two sessions never to
# resolve to the same path. See lib/handoff-paths.sh.
#
# Resume is by CHOICE: a new session gets a short menu (date + Goal line) of
# other sessions' filled handoffs and asks which, if any, to read. It used to
# inject the newest one whole; sessions in one dir do different work, so that
# was usually the wrong handoff and cost up to 18k tokens (2026-10-08). Wired into:
#   - SessionStart hook → `handoff.sh session-start` : ensure the file, list
#                          other sessions' handoffs as a menu (never their content).
#   - PreCompact hook    → `handoff.sh precompact`    : flush reminder before the
#                          context is auto-compacted (the context-wall backstop).
#   - statusline.sh      → shows ⚑HANDOFF at ≥60% context used (=40% remaining),
#                          the live 40% nudge to flush + /clear.
#
# `/clear` is Ahmad's action — no hook can self-clear a session. This tool's only
# job is to keep handoff.md current + surfaced so the clear loses nothing.
# Canonical rule: standard/session-handoff.md.
#
# Usage:
#   handoff.sh ensure          create the template at the handoff path if absent
#                              (never clobbers an existing file)
#   handoff.sh show            print the handoff.md (empty if none)
#   handoff.sh path            print the handoff.md path
#   handoff.sh session-start   SessionStart hook: ensure, then (only if other filled
#                              handoffs exist) emit hook JSON with a menu of them
#   handoff.sh precompact      PreCompact hook: emit hook JSON reminding to flush
#                              handoff.md before the summary happens
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib/handoff-paths.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/handoff-paths.sh" 2>/dev/null || true

# Repo root for the session's working dir. Hooks run with CLAUDE_PROJECT_DIR set;
# fall back to PWD. Empty when not inside a git repo (→ global fallback is used).
repo_root() {
  local dir="${CLAUDE_PROJECT_DIR:-$PWD}"
  git -C "$dir" rev-parse --show-toplevel 2>/dev/null || true
}

# THIS session's handoff file. Per-session by construction — two concurrent
# sessions can never resolve to the same path, which is the only guarantee that
# survives the model writing the file directly.
handoff_path() {
  local root dir sid
  root="$(repo_root)"
  # If the library failed to source, fall back to the OLD shared path rather
  # than to nothing: a shared handoff is degraded, no handoff is broken.
  if ! command -v handoff_dir >/dev/null 2>&1; then
    if [ -n "$root" ]; then printf '%s/handoff.md' "$root"
    else mkdir -p "$HOME/.claude" 2>/dev/null; printf '%s/.claude/handoff.md' "$HOME"; fi
    return 0
  fi
  dir="$(handoff_dir "$root")"; sid="$(handoff_session_id)"
  mkdir -p "$dir" 2>/dev/null
  printf '%s/%s.md' "$dir" "$sid"
}

template() {
  local root; root="$(repo_root)"
  local proj; proj="$([ -n "$root" ] && basename "$root" || echo "global (non-repo session)")"
  cat <<EOF
# Handoff — ${proj}

_Session working state. Keep it current; a \`/clear\` or a fresh session resumes from
here. Flush it before clearing at ~40% context remaining._

## Goal
<!-- what this thread is ultimately trying to achieve -->

## Current state
<!-- where things stand right now: branch, what's deployed, what's broken -->

## Done
<!-- completed + verified this session -->

## In progress
<!-- started, not finished — enough detail to resume mid-task -->

## Left to do
<!-- remaining steps, in order -->
EOF
}

cmd_ensure() {
  local p; p="$(handoff_path)"
  [ -z "$p" ] && return 0          # defensive → no-op
  [ -f "$p" ] && return 0          # already exists → never clobber
  template > "$p"
}

cmd_show() {
  local p; p="$(handoff_path)"
  [ -n "$p" ] && [ -f "$p" ] && cat "$p"
}

# SessionStart: create the file if missing (silently), then list other sessions'
# filled handoffs. Blank templates are never listed.
cmd_session_start() {
  local p; p="$(handoff_path)"
  [ -z "$p" ] && exit 0
  cmd_ensure

  # Offer a MENU of other sessions' handoffs — never inject one. Sessions in the
  # same dir do different work, so "newest" is not "relevant"; injecting it cost
  # up to 18k tokens in sessions that never needed it (2026-10-08, Ahmad).
  local root menu
  root="$(repo_root)"
  if command -v handoff_menu >/dev/null 2>&1; then
    handoff_prune "$(handoff_dir "$root")" 14 2>/dev/null || true
    menu="$(handoff_menu "$(handoff_dir "$root")" "$p" "$(handoff_legacy_path "$root")" 8)"
  else
    menu=""
  fi
  [ -n "$menu" ] || exit 0

  local list; list="$(printf '%s\n' "$menu" | awk -F'\t' '{printf "- %s · %s\n  %s\n", $2, $3, $1}')"
  local ctx="Handoffs from other sessions exist (newest first). Do NOT read any of them on your own. If the user's request continues one of these, or they ask to resume, ask them which one (AskUserQuestion, listing the goals) and read only that file. Otherwise ignore this list.
${list}

YOUR handoff for THIS session is ${p}. Write your state THERE, never into another session's file (overwriting one destroyed a session's state on 2026-08-26). Keep it current and flush it before any /clear."
  jq -n --arg c "$ctx" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$c}}'
}

cmd_precompact() {
  local p; p="$(handoff_path)"
  [ -z "$p" ] && exit 0            # defensive → nothing to flush
  local ctx="Context is about to be compacted. Ensure handoff.md at ${p} is current — especially 'In progress' and 'Left to do' — so nothing is lost across the summary."
  jq -n --arg c "$ctx" --arg m "⚑ handoff: flush In progress / Left to do before compaction" \
    '{systemMessage:$m, hookSpecificOutput:{hookEventName:"PreCompact",additionalContext:$c}}'
}

case "${1:-}" in
  ensure)        cmd_ensure ;;
  show)          cmd_show ;;
  path)          handoff_path; echo ;;
  session-start) cmd_session_start ;;
  precompact)    cmd_precompact ;;
  *) echo "usage: handoff.sh {ensure|show|path|session-start|precompact}" >&2; exit 2 ;;
esac
