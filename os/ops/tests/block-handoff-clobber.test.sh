#!/usr/bin/env bash
# block-handoff-clobber: a subagent or another session must not write someone else's handoff file.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; OPS="$HERE/.."
pass=0; fail=0
ok(){ if [ "$2" = "$3" ]; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1 - got '$2' want '$3'"; fail=$((fail+1)); fi; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
HOOK="$OPS/hooks/block-handoff-clobber.sh"
SID=2f8ff692-c4d1-4c74-ac03-98a5916697b6; OTHER=02afb18c-e7a5-4239-a2b2-a2ebb12e92a7
run() { python3 -c 'import json,sys; d={"tool_name":sys.argv[1],"session_id":sys.argv[2],"tool_input":{"file_path":sys.argv[3]}}
if sys.argv[4]: d["agent_id"]=sys.argv[4]; d["agent_type"]="general-purpose"
print(json.dumps(d))' "$1" "$2" "$3" "${4:-}" | bash "$HOOK" >/dev/null 2>&1; echo $?; }
H="/Users/x/.claude/handoff"
ok "own handoff, main agent: allow"                  "$(run Write $SID $H/$SID.md)" "0"
ok "own handoff via Edit: allow"                      "$(run Edit $SID $H/$SID.md)" "0"
ok "subagent, bare controller file: DENY"            "$(run Write $SID $H/$SID.md agent-1)" "2"
ok "subagent, <session>-<role>.md: allow"            "$(run Write $SID $H/$SID-migration.md agent-1)" "0"
ok "another session's file: DENY"                    "$(run Write $SID $H/$OTHER.md)" "2"
ok "another session's role file: DENY"               "$(run Write $SID $H/$OTHER-x.md)" "2"
ok "repo .handoff dir, own: allow"                   "$(run Write $SID /r/.handoff/$SID.md)" "0"
ok "repo .handoff dir, other: DENY"                  "$(run Write $SID /r/.handoff/$OTHER.md)" "2"
ok "non-handoff path: allow"                         "$(run Write $SID /r/src/notes.md)" "0"
ok "non-write tool: allow"                           "$(run Bash $SID $H/$OTHER.md)" "0"
ok "no session_id in payload: fail open"             "$(printf '{"tool_name":"Write","tool_input":{"file_path":"%s"}}' $H/$OTHER.md | bash "$HOOK" >/dev/null 2>&1; echo $?)" "0"
ok "garbage stdin: fail open"                        "$(echo 'not json' | bash "$HOOK" >/dev/null 2>&1; echo $?)" "0"
echo "---"; echo "block-handoff-clobber: $pass passed, $fail failed"; [ "$fail" = 0 ]
