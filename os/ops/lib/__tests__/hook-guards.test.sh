#!/usr/bin/env bash
# PreToolUse guards must DENY the bad case and ALLOW the good case.
#
# The allow-cases matter as much as the deny-cases: a guard with false positives
# gets disabled, and a disabled guard is worse than none. The `--no-verify inside
# a quoted commit message` case is the one that decides whether this survives.
# Run: bash ops/lib/__tests__/hook-guards.test.sh
set -uo pipefail
HOOKS="$(cd "$(dirname "$0")/../.." && pwd)/hooks"
_pass=0; _fail=0
ok() { echo "PASS: $1"; _pass=$((_pass+1)); }
no() { echo "FAIL: $1"; _fail=$((_fail+1)); }

# python builds the payload so shell quoting never distorts what we are testing
payload() { python3 -c "import json,sys;print(json.dumps({'tool_name':sys.argv[1],'tool_input':json.loads(sys.argv[2])}))" "$1" "$2"; }
cmd_payload()  { payload Bash "$(python3 -c "import json,sys;print(json.dumps({'command':sys.argv[1]}))" "$1")"; }
file_payload() { payload "$2" "$(python3 -c "import json,sys;print(json.dumps({'file_path':sys.argv[1]}))" "$1")"; }

denies() { printf '%s' "$1" | bash "$2" >/dev/null 2>&1; [ $? -ne 0 ]; }
allows() { printf '%s' "$1" | bash "$2" >/dev/null 2>&1; }

# ============================ block-no-verify ============================
G="$HOOKS/block-no-verify.sh"

denies "$(cmd_payload 'git commit --no-verify -m x')"                    "$G" && ok "deny commit --no-verify"          || no "deny commit --no-verify"
denies "$(cmd_payload 'git push --no-verify')"                           "$G" && ok "deny push --no-verify"            || no "deny push --no-verify"
denies "$(cmd_payload 'git -c core.hooksPath=/dev/null commit -m x')"    "$G" && ok "deny core.hooksPath bypass"       || no "deny core.hooksPath bypass"
denies "$(cmd_payload 'git commit -n -m x')"                             "$G" && ok "deny -n short flag on commit"     || no "deny -n short flag on commit"
denies "$(cmd_payload 'npm test && git commit --no-verify -m x')"        "$G" && ok "deny when chained after &&"       || no "deny when chained after &&"
denies "$(cmd_payload 'git commit --no-verify=true -m x')"               "$G" && ok "deny --no-verify=true form"       || no "deny --no-verify=true form"

allows "$(cmd_payload 'git commit -m "do not use --no-verify here"')"    "$G" && ok "allow --no-verify inside a quoted message" || no "allow --no-verify inside a quoted message"
allows "$(cmd_payload 'git commit -m x')"                                "$G" && ok "allow plain commit"               || no "allow plain commit"
allows "$(cmd_payload 'npm run verify')"                                 "$G" && ok "allow unrelated command"          || no "allow unrelated command"
allows "$(cmd_payload 'git log -n 5')"                                   "$G" && ok "allow -n on a read-only git cmd"  || no "allow -n on a read-only git cmd"
allows "$(cmd_payload 'grep -rn "no-verify" ops/')"                      "$G" && ok "allow grepping for the string"    || no "allow grepping for the string"
allows "$(file_payload /tmp/x Read)"                                     "$G" && ok "non-Bash tool passes through"     || no "non-Bash tool passes through"
printf 'not json' | bash "$G" >/dev/null 2>&1 && ok "malformed payload does not block" || no "malformed payload does not block"


# ============================ block-git-add-all ==========================
A="$HOOKS/block-git-add-all.sh"
for c in 'git add -A' 'git add --all' 'git add .' 'git add -A .' 'git add . -A' 'git add -f .' 'git add -vA' 'git -C /tmp/x add .' 'cd x && git add -A && git commit -m y'; do
  denies "$(cmd_payload "$c")" "$A" && ok "git-add-all denies: $c" || no "git-add-all denies: $c"
done
for c in 'git add ./path/file' 'git add src/a.ts src/b.ts' 'git add -p src/a.ts' 'git add -- ./x' 'git commit -m "never git add -A"' 'echo git add .' 'git status'; do
  allows "$(cmd_payload "$c")" "$A" && ok "git-add-all allows: $c" || no "git-add-all allows: $c"
done
allows "$(file_payload /tmp/x Read)" "$A" && ok "git-add-all: non-Bash passes" || no "git-add-all: non-Bash passes"
printf 'not json' | bash "$A" >/dev/null 2>&1 && ok "git-add-all: malformed payload does not block" || no "git-add-all: malformed payload does not block"
msg="$(printf '%s' "$(cmd_payload 'git add -A')" | bash "$A" 2>&1)"; printf '%s' "$msg" | grep -q 'never -A/\. (nested repos + untracked sensitive files)' && ok "git-add-all reason text" || no "git-add-all reason text"

# ======================= block-root-checkout-commit ======================
R="$HOOKS/block-root-checkout-commit.sh"
RT="$(mktemp -d)"
git init -q -b main "$RT/root" && git -C "$RT/root" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$RT/root" worktree add -q -b feat/x "$RT/wt" 2>/dev/null
git -C "$RT/root" worktree add -q -b feat/y "$RT/wtmain-sibling" 2>/dev/null
git init -q -b master "$RT/rootm" && git -C "$RT/rootm" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git init -q -b main "$RT/rootf" && git -C "$RT/rootf" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init && git -C "$RT/rootf" checkout -q -b feat/z
cwd_payload() { python3 -c "import json,sys;print(json.dumps({'tool_name':'Bash','cwd':sys.argv[1],'tool_input':{'command':sys.argv[2]}}))" "$1" "$2"; }
denies "$(cwd_payload "$RT/root" 'git commit -m x')"                   "$R" && ok "root-commit denies main checkout (cwd)"      || no "root-commit denies main checkout (cwd)"
denies "$(cwd_payload "$RT/rootm" 'git commit -m x')"                  "$R" && ok "root-commit denies master checkout"          || no "root-commit denies master checkout"
denies "$(cwd_payload "$RT/wt" "cd $RT/root && git commit -m x")"      "$R" && ok "root-commit denies via cd prefix"            || no "root-commit denies via cd prefix"
denies "$(cwd_payload "$RT/wt" "git -C $RT/root commit -m x")"         "$R" && ok "root-commit denies via git -C"               || no "root-commit denies via git -C"
allows "$(cwd_payload "$RT/wt" 'git commit -m x')"                     "$R" && ok "root-commit allows linked worktree"          || no "root-commit allows linked worktree"
allows "$(cwd_payload "$RT/rootf" 'git commit -m x')"                  "$R" && ok "root-commit allows non-main branch"          || no "root-commit allows non-main branch"
allows "$(cwd_payload "$RT/root" "cd $RT/wt && git commit -m x")"      "$R" && ok "root-commit allows cd into a worktree"       || no "root-commit allows cd into a worktree"
allows "$(cwd_payload "$RT/root" 'git status')"                        "$R" && ok "root-commit ignores non-commit git"          || no "root-commit ignores non-commit git"
allows "$(cwd_payload "$RT/root" 'git log -1')"                        "$R" && ok "root-commit ignores git log"                 || no "root-commit ignores git log"
allows "$(cwd_payload "$RT" 'git commit -m x')"                        "$R" && ok "root-commit allows non-repo dir"             || no "root-commit allows non-repo dir"
printf 'not json' | bash "$R" >/dev/null 2>&1 && ok "root-commit: malformed payload does not block" || no "root-commit: malformed payload does not block"
msg="$(printf '%s' "$(cwd_payload "$RT/root" 'git commit -m x')" | bash "$R" 2>&1)"; printf '%s' "$msg" | grep -q 'root checkouts stay on main read-only — use ~/.claude/scripts/new-task-worktree.sh' && ok "root-commit reason text" || no "root-commit reason text"
rm -rf "$RT"

# ========================== warn-agent-no-model ==========================
M="$HOOKS/warn-agent-no-model.sh"
agent_payload() { python3 -c "import json,sys;print(json.dumps({'tool_name':'Agent','tool_input':json.loads(sys.argv[1])}))" "$1"; }
out="$(printf '%s' "$(agent_payload '{"prompt":"x"}')" | bash "$M" 2>/dev/null)"; rc=$?
[ "$rc" -eq 0 ] && ok "agent-no-model never blocks (exit 0)" || no "agent-no-model never blocks (exit $rc)"
printf '%s' "$out" | python3 -c 'import json,sys;m=json.load(sys.stdin)["systemMessage"];assert m=="subagent without model: set model: \"sonnet\" for mechanical work"' 2>/dev/null && ok "agent-no-model warns via systemMessage" || no "agent-no-model warns via systemMessage"
out="$(printf '%s' "$(agent_payload '{"prompt":"x","model":"sonnet"}')" | bash "$M" 2>/dev/null)"
[ -z "$out" ] && ok "agent-no-model silent when model set" || no "agent-no-model silent when model set"
out="$(printf '%s' "$(cmd_payload 'ls')" | bash "$M" 2>/dev/null)"
[ -z "$out" ] && ok "agent-no-model silent for non-Agent tool" || no "agent-no-model silent for non-Agent tool"
printf 'not json' | bash "$M" >/dev/null 2>&1 && ok "agent-no-model: malformed payload ok" || no "agent-no-model: malformed payload ok"

# ============================ protect-config =============================
P="$HOOKS/protect-config.sh"
W="$(mktemp -d)"; mkdir -p "$W/src"
: > "$W/eslint.config.js"; : > "$W/.gitignore"; : > "$W/vitest.config.ts"; : > "$W/src/index.ts"

denies "$(file_payload "$W/eslint.config.js" Edit)"   "$P" && ok "deny edit of existing eslint config"   || no "deny edit of existing eslint config"
denies "$(file_payload "$W/.gitignore" Write)"        "$P" && ok "deny write to existing .gitignore"     || no "deny write to existing .gitignore"
denies "$(file_payload "$W/vitest.config.ts" Edit)"   "$P" && ok "deny edit of existing vitest config"   || no "deny edit of existing vitest config"

allows "$(file_payload "$W/biome.json" Write)"        "$P" && ok "allow CREATING a config that does not exist" || no "allow CREATING a config that does not exist"
allows "$(file_payload "$W/src/index.ts" Edit)"       "$P" && ok "allow ordinary source edit"            || no "allow ordinary source edit"
allows "$(file_payload "$W/src/eslint.config.js.md" Edit)" "$P" && ok "allow a file merely NAMED like a config" || no "allow a file merely NAMED like a config"
allows "$(cmd_payload 'echo hi')"                     "$P" && ok "non-edit tool passes through"          || no "non-edit tool passes through"

# fail CLOSED: an unreadable path must deny, not be treated as absent
UNREADABLE="$W/locked/eslint.config.js"; mkdir -p "$W/locked"; : > "$UNREADABLE"; chmod 000 "$W/locked"
denies "$(file_payload "$UNREADABLE" Edit)" "$P" && ok "unstattable path fails CLOSED" || no "unstattable path fails CLOSED"
chmod 755 "$W/locked"

rm -rf "$W"
echo; echo "hook-guards: $_pass passed, $_fail failed"
[ "$_fail" -eq 0 ]
