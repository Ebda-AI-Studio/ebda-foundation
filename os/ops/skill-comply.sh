#!/usr/bin/env bash
# skill-comply.sh — measure whether our standing rules are ACTUALLY followed.
# ECC skill-comply, adapted. For each rule in lib/comply-rules.json: build a
# throwaway fixture, run `claude -p` on a scenario where the rule SHOULD fire,
# capture the tool-call stream, and check the expected-behavior signal appeared.
# On-demand (each rule = one claude -p run); NOT scheduled. Answers the question
# our 455 memory rules never could: are they obeyed?
# Usage: skill-comply.sh [rule-id|all]
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/bin:/bin:$PATH"
# CLAUDE_BIN lets a test point this at a stub. Without it the model call is
# untestable offline, which is why none of the OS's 17 model-calling scripts
# had a single behavioural test. Defaults to the real CLI.
CLAUDE_BIN="${CLAUDE_BIN:-claude}"
MAN="$HOME/.claude/scripts/lib/comply-rules.json"
WANT="${1:-all}"
[ -f "$MAN" ] || { echo "manifest missing: $MAN"; exit 1; }

field() { python3 -c "import json,sys;print([x for x in json.load(open('$MAN'))['rules'] if x['id']=='$1'][0]['$2'])"; }

mk_fixture() { # $1=type $2=dir
  local t="$1" d="$2"; mkdir -p "$d"
  case "$t" in
    env)    printf 'export API=OLD_API_HOST\n' >"$d/a.sh"; printf 'const h="OLD_API_HOST";\n' >"$d/b.js"; printf 'HOST=OLD_API_HOST\n' >"$d/.env";;
    config) printf '{"featureX": false, "other": true}\n' >"$d/config.json";;
    node)   printf 'function add(a,b){return a+b-1;}\nmodule.exports={add};\n' >"$d/add.js";;
  esac
}

pass=0; fail=0; total=0
ids=$(python3 -c "import json;print(' '.join(r['id'] for r in json.load(open('$MAN'))['rules']))")
for id in $ids; do
  [ "$WANT" != "all" ] && [ "$WANT" != "$id" ] && continue
  total=$((total+1))
  ftype=$(field "$id" fixture); scen=$(field "$id" scenario); expect=$(field "$id" expect_regex)
  fx=$(mktemp -d "/tmp/comply-$id.XXXXXX"); mk_fixture "$ftype" "$fx"
  echo "── testing rule: $id ──"
  stream=$( (cd "$fx" && timeout 120 "$CLAUDE_BIN" -p "$scen" --output-format stream-json --verbose 2>/dev/null </dev/null) || echo "" )
  if grep -qiE "$expect" < <(printf '%s' "$stream") 2>/dev/null; then
    echo "  ✅ FOLLOWED — expected behavior fired (/$expect/)"; pass=$((pass+1))
  else
    echo "  ❌ NOT followed — /$expect/ did not appear in the tool-call trace"; fail=$((fail+1))
  fi
  rm -rf "$fx"
done
echo
[ "$total" -gt 0 ] && echo "compliance: $pass/$total rules followed ($fail not)" || echo "no matching rule ($WANT)"
