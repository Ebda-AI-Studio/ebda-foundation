#!/usr/bin/env bash
# --------------------------------------------------------------------
# claude-hook declaration - read by ops/dead-gate-detect.sh (see block-no-verify.sh).
# claude-hook: PreToolUse
# --------------------------------------------------------------------
# block-handoff-clobber.sh - PreToolUse guard for Write/Edit/NotebookEdit on session handoff files.
#
# WHY (2026-10-25). Subagents inherit the controller's session id, so their handoff writes landed on the controller's
# `<session-id>.md` and overwrote it. handoff.sh never writes content (the model does), so only a guard at the write
# can hold. Two denials, both on a path `.../handoff/<uuid>[-<role>].md` or `.../.handoff/<uuid>[-<role>].md`:
#   1. the file belongs to ANOTHER session (uuid != the payload's session_id)  -> deny
#   2. the caller is a SUBAGENT (payload carries agent_id / agent_type) and the file is the bare `<uuid>.md`
#      -> deny; use `<uuid>-<role>.md` (e.g. ...-migration.md)
# Fails OPEN on anything it cannot parse (a guard that blocks on its own confusion gets switched off).
# UNVERIFIED: that every Claude Code version puts agent_id/agent_type on subagent tool calls - rule 2 is a no-op
# where they are absent; rule 1 needs only session_id.
# stdin: PreToolUse payload. exit 0 = allow, exit 2 = deny (stderr shown).
set -uo pipefail
payload="$(cat 2>/dev/null || true)"
printf '%s' "$payload" | python3 -I -c '
import json, re, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if d.get("tool_name") not in ("Write", "Edit", "NotebookEdit", "MultiEdit"):
    sys.exit(0)
ti = d.get("tool_input") or {}
path = ti.get("file_path") or ti.get("notebook_path") or ""
m = re.search(r"/\.?handoff/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})(-[A-Za-z0-9_.-]+)?\.md$", path)
if not m:
    sys.exit(0)
fid, role = m.group(1), m.group(2)
sid = d.get("session_id") or ""
if not sid:
    sys.exit(0)
if sid != fid:
    sys.stderr.write("block-handoff-clobber: %s belongs to session %s, not %s. Write your OWN handoff (<your-session-id>.md), "
                     "or <session>-<role>.md if you are a subagent.\n" % (path, fid, sid[:8]))
    sys.exit(2)
if (d.get("agent_id") or d.get("agent_type")) and not role:
    sys.stderr.write("block-handoff-clobber: a subagent must not write the controller handoff %s. Use %s-<role>.md "
                     "(e.g. %s-%s.md).\n" % (path, fid, fid, (d.get("agent_type") or "agent")))
    sys.exit(2)
sys.exit(0)
'
exit $?
