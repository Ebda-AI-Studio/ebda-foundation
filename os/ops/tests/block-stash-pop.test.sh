#!/usr/bin/env bash
# block-stash-pop: the stash stack is shared by every worktree of a repo; pop / bare stash / save / clear / push without -m are denied.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; OPS="$HERE/.."
pass=0; fail=0
ok(){ if [ "$2" = "$3" ]; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1 - got '$2' want '$3'"; fail=$((fail+1)); fi; }
HOOK="$OPS/hooks/block-stash-pop.sh"
run() { python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$1" | bash "$HOOK" >/dev/null 2>&1; echo $?; }
ok "git stash pop: DENY"                         "$(run 'git stash pop')" "2"
ok "bare git stash: DENY"                        "$(run 'git stash')" "2"
ok "stash push without -m: DENY"                 "$(run 'git stash push -u')" "2"
ok "git -C dir stash pop: DENY"                  "$(run 'git -C /tmp/x stash pop')" "2"
ok "chained ls && git stash pop: DENY"           "$(run 'ls && git stash pop')" "2"
ok "stash save / clear: DENY"                    "$(run 'git stash save x')$(run 'git stash clear')" "22"
ok "stash push -u -m tag: allow"                 "$(run 'git stash push -u -m wip-tag')" "0"
ok "stash list: allow"                           "$(run 'git stash list')" "0"
ok "stash apply <sha>: allow"                    "$(run 'git stash apply 1a2b3c4')" "0"
ok "commit message containing 'git stash pop': allow" "$(run 'git commit -m "never git stash pop"')" "0"
ok "non-Bash tool: allow"                        "$(echo '{"tool_name":"Write","tool_input":{"command":"git stash pop"}}' | bash "$HOOK" >/dev/null 2>&1; echo $?)" "0"
ok "garbage stdin: fail open"                    "$(echo 'not json' | bash "$HOOK" >/dev/null 2>&1; echo $?)" "0"
echo "---"; echo "block-stash-pop: $pass passed, $fail failed"; [ "$fail" = 0 ]
