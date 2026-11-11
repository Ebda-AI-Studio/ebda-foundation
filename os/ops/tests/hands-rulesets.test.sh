#!/usr/bin/env bash
# F-12: check-rulesets.sh fails when a repo of the hands config has an unprotected default branch, and passes when all of them are fenced.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; CHK="$HERE/../../cloud/brain/scripts/check-rulesets.sh"
pass=0; fail=0
ok(){ if [ "$2" = "$3" ]; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1 - got '$2' want '$3'"; fail=$((fail+1)); fi; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/gh" <<'S'
#!/usr/bin/env bash
# fake gh api: repos/o/good (fully protected), repos/o/open (no rulesets), repos/o/bypass (bypass actor), repos/o/partial (no status checks)
p="$2"; shift 2
case "$p" in
  repos/o/*/rulesets/1) kind="${p#repos/o/}"; kind="${kind%%/*}"
    rules='[{"type":"pull_request"},{"type":"required_status_checks"},{"type":"non_fast_forward"},{"type":"deletion"}]'
    [ "$kind" = partial ] && rules='[{"type":"pull_request"},{"type":"non_fast_forward"},{"type":"deletion"}]'
    bypass='[]'; [ "$kind" = bypass ] && bypass='[{"actor_id":5,"actor_type":"Integration"}]'
    echo "{\"id\":1,\"enforcement\":\"active\",\"conditions\":{\"ref_name\":{\"include\":[\"~DEFAULT_BRANCH\"]}},\"rules\":$rules,\"bypass_actors\":$bypass}" ;;
  repos/o/open/rulesets) echo '[]' ;;
  repos/o/*/rulesets) echo '[{"id":1,"enforcement":"active","target":"branch"}]' ;;
  repos/o/*) echo main ;;
  *) exit 1 ;;
esac
S
chmod +x "$TMP/gh"
run() { GH_BIN="$TMP/gh" bash "$CHK" --config "$1" >"$TMP/out" 2>&1; echo $?; }
echo '{"repos":{"o/good":{}}}' > "$TMP/a.json"; echo '{"repos":{"o/good":{},"o/open":{}}}' > "$TMP/b.json"
echo '{"repos":{"o/bypass":{}}}' > "$TMP/c.json"; echo '{"repos":{"o/partial":{}}}' > "$TMP/d.json"; echo '{"repos":{}}' > "$TMP/e.json"
ok "all repos protected: exit 0"                 "$(run "$TMP/a.json")" "0"
ok "  ...says OK"                                "$(grep -c '^OK o/good' "$TMP/out")" "1"
ok "an unprotected repo: exit 1, named"          "$(run "$TMP/b.json")" "1"
ok "  ...names o/open"                           "$(grep -c '^UNPROTECTED o/open' "$TMP/out")" "1"
ok "a bypass actor counts as unprotected"        "$(run "$TMP/c.json")" "1"
ok "missing required status checks"              "$(run "$TMP/d.json")" "1"
ok "  ...says which rule"                        "$(grep -c 'required_status_checks' "$TMP/out")" "1"
ok "no repos listed: exit 2 (never a silent pass)" "$(run "$TMP/e.json")" "2"
echo "---"; echo "hands-rulesets: $pass passed, $fail failed"; [ "$fail" = 0 ]
