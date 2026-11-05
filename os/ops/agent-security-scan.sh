#!/usr/bin/env bash
# Whisky AI OS — agent-runtime security scan (companion to standard/agent-security.md).
# Audits OUR live agent-runtime exposure against the lethal-trifecta / MCP-Top-10 /
# autonomous-harness gates in standard/agent-security.md. READ-ONLY — no mutations,
# no git, no network calls other than what's already on disk.
#
# Checks:
#   1. MCP servers configured in ~/.claude.json (mcpServers keys) — each flagged as
#      "treat tool output as untrusted."
#   2. ~/.claude/settings.json permissions.defaultMode — warn on blanket bypassPermissions.
#   3. ebda-whatsapp backend/src: grep for exec(/eval(/child_process near
#      message-handling code — report hits for manual review (not auto-classified
#      safe/unsafe; a human confirms argv-array vs shell-string usage).
#   4. DREAM_AUTOMERGE=true anywhere in ~/.claude/scripts or foundation ops/ — must
#      never be hardcoded true (it's a repo-var kill switch, default OFF).
#   5. Summary: N MCP servers, permission mode, N exec-near-untrusted hits, automerge
#      state → PASS/WARN.
#
# Usage:
#   ops/agent-security-scan.sh
#
# Exit codes: 0 = ran (even on WARN); this is a report tool, not a hard CI gate.
# shellcheck source=lib/os-config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/os-config.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-config.sh" 2>/dev/null || true
command -v os_config_load >/dev/null 2>&1 && os_config_load
set -uo pipefail
. "$(dirname "$0")/lib/os-state.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-state.sh" 2>/dev/null || true

# TCC canary (2026-07-12): abort when the launchd context cannot see ~/Desktop
OS_JOB_NAME=agent-security-scan
if command -v require_projects_access >/dev/null 2>&1; then require_projects_access || exit 0; fi


# ── absolute tool paths (PATH can be unreliable under launchd/cron) ─────────
GIT_BIN="/opt/homebrew/bin/git"
command -v "$GIT_BIN" >/dev/null 2>&1 || GIT_BIN="$(command -v git || echo git)"
PY_BIN="$(command -v python3 || echo python3)"

CLAUDE_JSON="$HOME/.claude.json"
SETTINGS_JSON="$HOME/.claude/settings.json"
SCRIPTS_DIR="$HOME/.claude/scripts"
HERE="$(cd "$(dirname "$0")" && pwd)"
FOUNDATION_OPS="$HERE"

# ebda-whatsapp / ebda-whatsapp backend src — try known locations,
# skip gracefully if the repo isn't checked out on this machine.
WBS_CANDIDATES=(
  "$OS_PROJECTS_DIR/$OS_ORG/internal-projects/ebda-whatsapp/backend/src"
)
WBS_SRC=""
for c in "${WBS_CANDIDATES[@]}"; do
  if [ -d "$c" ]; then WBS_SRC="$c"; break; fi
done

findings_warn=()
findings_info=()
add_warn() { findings_warn+=("WARN:  $1"); }
add_info() { findings_info+=("INFO:  $1"); }

echo "=== Agent-Runtime Security Scan ==="
echo "(companion to standard/agent-security.md — read-only, no mutations)"
echo

# ─────────────────────────────────────────────────────────────────────────────
# Check 1 — MCP servers configured
# ─────────────────────────────────────────────────────────────────────────────
echo "--- 1. MCP servers (~/.claude.json) ---"
MCP_COUNT=0
if [ -f "$CLAUDE_JSON" ]; then
  MCP_LIST=$("$PY_BIN" -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
for k in sorted(d.get('mcpServers', {}).keys()):
    print(k)
" "$CLAUDE_JSON" 2>/dev/null)
  if [ -n "$MCP_LIST" ]; then
    while IFS= read -r srv; do
      [ -z "$srv" ] && continue
      MCP_COUNT=$((MCP_COUNT + 1))
      echo "  - $srv  (review tool descriptions + output as UNTRUSTED context)"
      add_info "mcp server '$srv' configured — vetted? tool output treated untrusted?"
    done <<< "$MCP_LIST"
  else
    echo "  (no mcpServers configured, or file unreadable)"
  fi
else
  echo "  ~/.claude.json not found — skipping"
fi
echo "  -> $MCP_COUNT MCP server(s) found"
echo

# ─────────────────────────────────────────────────────────────────────────────
# Check 2 — permissions.defaultMode
# ─────────────────────────────────────────────────────────────────────────────
echo "--- 2. Permission mode (~/.claude/settings.json) ---"
PERM_MODE="(not set)"
if [ -f "$SETTINGS_JSON" ]; then
  PERM_MODE=$("$PY_BIN" -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print('(unreadable)')
    sys.exit(0)
print(d.get('permissions', {}).get('defaultMode', '(not set)'))
" "$SETTINGS_JSON" 2>/dev/null)
fi
echo "  defaultMode: $PERM_MODE"
if [ "$PERM_MODE" = "bypassPermissions" ]; then
  echo "  WARNING: blanket bypassPermissions is set globally. This is acceptable for a"
  echo "  trusted, human-driven interactive session, but MUST NOT be inherited by any"
  echo "  unattended agent or any agent whose context includes untrusted content"
  echo "  (inbound messages, fetched pages, MCP tool output, autonomous PR review)."
  add_warn "permissions.defaultMode=bypassPermissions (global) — confirm no untrusted-input agent inherits this; scope those to an explicit allowlist or a PreToolUse gate instead"
else
  add_info "permissions.defaultMode=$PERM_MODE (not blanket bypass)"
fi
echo

# ─────────────────────────────────────────────────────────────────────────────
# Check 3 — untrusted-input -> exec patterns in whatsapp bot runtime
# ─────────────────────────────────────────────────────────────────────────────
echo "--- 3. exec/eval/child_process near message handling (whatsapp bot runtime) ---"
EXEC_HITS=0
if [ -n "$WBS_SRC" ]; then
  echo "  scanning: $WBS_SRC"
  # NOTE: this grep pattern is a DETECTOR string — it searches other repos' source for
  # dangerous exec/eval/child_process usage. It does not itself call eval()/exec() on
  # anything; the pattern text is never passed to a shell or interpreter.
  HITS=$(grep -rnE 'exec\(|eval\(|child_process' "$WBS_SRC" 2>/dev/null | grep -v node_modules || true)
  if [ -n "$HITS" ]; then
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      EXEC_HITS=$((EXEC_HITS + 1))
      echo "  HIT: $line"
    done <<< "$HITS"
    add_warn "$EXEC_HITS exec/eval/child_process reference(s) in $WBS_SRC — review each: confirm argv-array invocation (no shell string), and confirm none is built from raw inbound message text"
  else
    echo "  (no matches)"
  fi
else
  echo "  ebda-whatsapp/ebda-whatsapp backend/src not found on this machine — skipping"
  add_info "whatsapp backend/src not found locally — check 3 skipped"
fi
echo "  -> $EXEC_HITS hit(s) to review"
echo

# ─────────────────────────────────────────────────────────────────────────────
# Check 4 — DREAM_AUTOMERGE hardcoded true
# ─────────────────────────────────────────────────────────────────────────────
echo "--- 4. DREAM_AUTOMERGE hardcoded true? ---"
AUTOMERGE_HITS=0
SELF="$(basename "$0")"
for dir in "$SCRIPTS_DIR" "$FOUNDATION_OPS"; do
  [ -d "$dir" ] || continue
  # Only flag REAL assignment forms (shell `DREAM_AUTOMERGE=true`, YAML
  # `DREAM_AUTOMERGE: true`) — exclude log/message lines (_info/echo/printf that
  # merely mention the string), comments, and this scan script's own source
  # (which necessarily contains the literal string in its comments/messages).
  HITS=$(grep -rn 'DREAM_AUTOMERGE' "$dir" 2>/dev/null \
    | grep -v "/$SELF:" \
    | grep -Ev '_info|_warn|echo |printf |^[^:]*:[0-9]+:[[:space:]]*#' \
    | grep -E '^[^:]*:[0-9]+:[[:space:]]*(export[[:space:]]+)?DREAM_AUTOMERGE[[:space:]]*[:=][[:space:]]*"?true"?[[:space:]]*$' \
    || true)
  if [ -n "$HITS" ]; then
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      AUTOMERGE_HITS=$((AUTOMERGE_HITS + 1))
      echo "  HIT: $line"
    done <<< "$HITS"
  fi
done
if [ "$AUTOMERGE_HITS" -eq 0 ]; then
  echo "  (no hardcoded DREAM_AUTOMERGE=true found — default-OFF posture intact)"
  add_info "DREAM_AUTOMERGE not hardcoded true anywhere scanned"
else
  add_warn "$AUTOMERGE_HITS place(s) hardcode DREAM_AUTOMERGE=true — this defeats the default-OFF kill switch; confirm intentional and repo-scoped, not global"
fi
echo "  -> $AUTOMERGE_HITS hardcoded-true hit(s)"
echo

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
echo "=== SUMMARY ==="
echo "  MCP servers:            $MCP_COUNT"
echo "  Permission mode:        $PERM_MODE"
echo "  exec-near-untrusted:    $EXEC_HITS hit(s)"
echo "  DREAM_AUTOMERGE=true:   $AUTOMERGE_HITS hardcoded hit(s)"
echo

total_warns=${#findings_warn[@]}
if [ "$total_warns" -eq 0 ]; then
  echo "RESULT: PASS — no agent-runtime security warnings."
else
  echo "RESULT: WARN — ${total_warns} item(s) need review:"
  for f in ${findings_warn[@]+"${findings_warn[@]}"}; do echo "  $f"; done
fi
echo

if [ "${VERBOSE:-0}" = "1" ] && [ "${#findings_info[@]}" -gt 0 ]; then
  echo "--- INFO ---"
  for f in ${findings_info[@]+"${findings_info[@]}"}; do echo "  $f"; done
fi

exit 0
