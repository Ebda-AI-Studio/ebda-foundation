#!/usr/bin/env bash
# block-pkill-pattern: pkill/killall (kill by pattern) and lockf/flock around git push are denied; kill <pid> and plain pushes stay legal.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; OPS="$HERE/.."
pass=0; fail=0
ok(){ if [ "$2" = "$3" ]; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1 - got '$2' want '$3'"; fail=$((fail+1)); fi; }
HOOK="$OPS/hooks/block-pkill-pattern.sh"
run() { python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$1" | bash "$HOOK" >/dev/null 2>&1; echo $?; }
ok "pkill -f: DENY"                      "$(run 'pkill -f vitest')" "2"
ok "bare pkill name: DENY"               "$(run 'pkill node')" "2"
ok "killall: DENY"                       "$(run 'killall node')" "2"
ok "/usr/bin/pkill path: DENY"           "$(run '/usr/bin/pkill -f x')" "2"
ok "sudo pkill: DENY"                    "$(run 'sudo pkill -f x')" "2"
ok "chained ls && pkill: DENY"           "$(run 'ls && pkill -f x')" "2"
ok "lockf around git push: DENY"         "$(run 'lockf -k /tmp/heavy-test.lock git push origin main')" "2"
ok "flock around git push: DENY"         "$(run 'flock /tmp/x.lock git -C repo push')" "2"
ok "no-space separator true;pkill: DENY"  "$(run 'true;pkill -f x')" "2"
ok "pkill on a second line: DENY"        "$(run $'echo hi\npkill -P 0')" "2"
ok "pkill inside \$( ): DENY"            "$(run 'x=$(pkill foo)')" "2"
ok "pkill inside backticks: DENY"        "$(run 'x=`killall node`')" "2"
ok "pkill in a subshell ( ): DENY"       "$(run '(pkill foo)')" "2"
ok "multi-line commit msg mentioning pkill: allow" "$(run $'git commit -m "a\npkill -f x"')" "0"
ok "grep for the word pkill: allow"      "$(run 'grep -n pkill notes.txt')" "0"
ok "kill <pid>: allow"                   "$(run 'kill 12345')" "0"
ok "plain git push: allow"               "$(run 'git push origin feat/x')" "0"
ok "lockf around a test suite: allow"    "$(run 'lockf -k /tmp/heavy-test.lock npm test')" "0"
ok "commit message mentioning pkill: allow" "$(run 'git commit -m "never pkill -f"')" "0"
ok "non-Bash tool: allow"                "$(echo '{"tool_name":"Write","tool_input":{"command":"pkill -f x"}}' | bash "$HOOK" >/dev/null 2>&1; echo $?)" "0"
ok "garbage stdin: fail open"            "$(echo 'not json' | bash "$HOOK" >/dev/null 2>&1; echo $?)" "0"
echo "---"; echo "block-pkill-pattern: $pass passed, $fail failed"; [ "$fail" = 0 ]
