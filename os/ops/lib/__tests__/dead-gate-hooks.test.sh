#!/usr/bin/env bash
# dead-gate-detect.sh must REPORT a hook that declares itself and is not
# registered. A detector that cannot produce the finding is the same fail-open
# shape it exists to catch, so the reporting case is asserted first.
# Run: bash ops/lib/__tests__/dead-gate-hooks.test.sh
set -uo pipefail
SCRIPT="$(cd "$(dirname "$0")/../.." && pwd)/dead-gate-detect.sh"
_pass=0; _fail=0
ok() { echo "PASS: $1"; _pass=$((_pass+1)); }
no() { echo "FAIL: $1"; _fail=$((_fail+1)); }

mk() {  # $1=home ; creates a declared hook named orphan-gate.sh
  mkdir -p "$1/.claude/scripts/hooks" "$1/.whisky-os-state"
  printf '#!/usr/bin/env bash\n# claude-hook: Stop\nexit 0\n' > "$1/.claude/scripts/orphan-gate.sh"
  chmod +x "$1/.claude/scripts/orphan-gate.sh"
}

# 1. declared, NOT registered -> reported
H="$(mktemp -d)"; mk "$H"; echo '{"hooks":{}}' > "$H/.claude/settings.json"
out="$(HOME="$H" bash "$SCRIPT" 2>&1)"
grep -q 'orphan-gate.sh declares Stop' <<<"$out" && ok "reports a declared-but-unregistered hook" || no "reports a declared-but-unregistered hook"
grep -q 'install-hooks.sh' <<<"$out" && ok "names the fix" || no "names the fix"
rm -rf "$H"

# 2. declared AND registered -> not reported
H="$(mktemp -d)"; mk "$H"
H="$H" python3 -c "
import json,os
p=os.environ['H']+'/.claude/settings.json'
json.dump({'hooks':{'Stop':[{'hooks':[{'type':'command','command':os.environ['H']+'/.claude/scripts/orphan-gate.sh'}]}]}},open(p,'w'))"
out="$(HOME="$H" bash "$SCRIPT" 2>&1)"
grep -q 'orphan-gate.sh declares' <<<"$out" && no "registered hook is not reported" || ok "registered hook is not reported"
rm -rf "$H"

# 3. registered on the WRONG event -> still reported (registration must match the declaration)
H="$(mktemp -d)"; mk "$H"
H="$H" python3 -c "
import json,os
p=os.environ['H']+'/.claude/settings.json'
json.dump({'hooks':{'PreToolUse':[{'hooks':[{'type':'command','command':os.environ['H']+'/.claude/scripts/orphan-gate.sh'}]}]}},open(p,'w'))"
out="$(HOME="$H" bash "$SCRIPT" 2>&1)"
grep -q 'orphan-gate.sh declares Stop' <<<"$out" && ok "wrong-event registration is reported" || no "wrong-event registration is reported"
rm -rf "$H"

# 4. a command carrying ARGUMENTS still counts as registered (…/wc-event.sh done)
H="$(mktemp -d)"; mk "$H"
H="$H" python3 -c "
import json,os
p=os.environ['H']+'/.claude/settings.json'
json.dump({'hooks':{'Stop':[{'hooks':[{'type':'command','command':os.environ['H']+'/.claude/scripts/orphan-gate.sh done'}]}]}},open(p,'w'))"
out="$(HOME="$H" bash "$SCRIPT" 2>&1)"
grep -q 'orphan-gate.sh declares' <<<"$out" && no "argument-carrying registration counts" || ok "argument-carrying registration counts"
rm -rf "$H"

# 5. a MISSING settings.json is a finding, not a pass — every declared hook is dead
H="$(mktemp -d)"; mk "$H"
out="$(HOME="$H" bash "$SCRIPT" 2>&1)"
grep -qi 'settings.json is ABSENT' <<<"$out" && ok "absent settings.json is reported" || no "absent settings.json is reported"
rm -rf "$H"

# 6. an UNPARSEABLE settings.json reports UNKNOWN rather than clean
H="$(mktemp -d)"; mk "$H"; echo 'not json' > "$H/.claude/settings.json"
out="$(HOME="$H" bash "$SCRIPT" 2>&1)"
grep -qi 'does not parse' <<<"$out" && ok "unparseable settings.json is reported" || no "unparseable settings.json is reported"
rm -rf "$H"

echo; echo "dead-gate-hooks: $_pass passed, $_fail failed"
[ "$_fail" -eq 0 ]
