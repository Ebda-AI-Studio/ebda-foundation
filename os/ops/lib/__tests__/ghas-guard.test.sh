#!/usr/bin/env bash
# Test ghas-guard.sh — fully OFFLINE. A fake `gh` on PATH answers each API call
# from scenario variables, so every branch (clean, billing, drift, API failure)
# is exercised without touching GitHub or sending a Telegram message.
# Run: bash ops/lib/__tests__/ghas-guard.test.sh
set -uo pipefail

SRC="$(cd "$(dirname "$0")" && cd ../.. && pwd)/ghas-guard.sh"
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$ROOT/ops/lib" "$ROOT/bin"
cp "$SRC" "$ROOT/ops/ghas-guard.sh"
printf '#!/bin/bash\necho "NOTIFIED: $1" >> "%s/notified"\n' "$ROOT" > "$ROOT/ops/notify.sh"
echo 'write_status(){ :; }' > "$ROOT/ops/lib/os-state.sh"
chmod +x "$ROOT/ops/ghas-guard.sh" "$ROOT/ops/notify.sh"

# Fake gh: reads FAKE_* env vars. `--jq` is applied with the real jq to canned JSON.
cat > "$ROOT/bin/gh" <<'EOF'
#!/bin/bash
[ "${FAKE_FAIL:-0}" = 1 ] && { echo '{"message":"Bad credentials"}'; exit 1; }
url="" ; jqf=""
while [ $# -gt 0 ]; do
  case "$1" in api) ;; --paginate) ;; --jq) jqf="$2"; shift ;; -*) ;; *) url="$1" ;; esac
  shift
done
D_ATTACHED='[{"status":"enforced","repository":{"name":"a"}},{"status":"enforced","repository":{"name":"b"}}]'
D_CONFIGS='[{"id":7,"name":"no-paid-security","enforcement":"enforced","advanced_security":"disabled","secret_scanning":"disabled","code_scanning_default_setup":"disabled"}]'
D_REPOS='[{"name":"a","security_and_analysis":{"secret_scanning":{"status":"disabled"}}},{"name":"b","security_and_analysis":{"secret_scanning":{"status":"disabled"}}}]'
[ -n "${FAKE_ATTACHED:-}" ] || FAKE_ATTACHED=$D_ATTACHED
[ -n "${FAKE_CONFIGS:-}" ] || FAKE_CONFIGS=$D_CONFIGS
[ -n "${FAKE_REPOS:-}" ] || FAKE_REPOS=$D_REPOS
case "$url" in
  *advanced-security*) body="{\"total_advanced_security_committers\":${FAKE_COMMITTERS:-0},\"repositories\":${FAKE_BILLED_REPOS:-[]}}" ;;
  */settings/billing/usage) body="{\"usageItems\":${FAKE_USAGE:-[]}}" ;;
  */code-security/configurations/defaults) body="[{\"default_for_new_repos\":\"${FAKE_DEFAULT:-private_and_internal}\",\"configuration\":{\"name\":\"no-paid-security\"}}]" ;;
  */code-security/configurations/*/repositories*) body="$FAKE_ATTACHED" ;;
  */code-security/configurations) body="$FAKE_CONFIGS" ;;
  */repos\?type=private*) body="$FAKE_REPOS" ;;
  *) echo "fake gh: unhandled $url" >&2; exit 1 ;;
esac
if [ -n "$jqf" ]; then printf '%s' "$body" | jq -r "$jqf"; else printf '%s\n' "$body"; fi
EOF
chmod +x "$ROOT/bin/gh"

_pass=0; _fail=0
run() { rm -f "$ROOT/notified"; out=$(env PATH="$ROOT/bin:$PATH" GHAS_GUARD_ORGS=org1 "$@" "$ROOT/ops/ghas-guard.sh" 2>&1); rc=$?; }
check() { # label, expected rc, expected substring, expect notify (1/0)
  local label="$1" erc="$2" sub="$3" en="$4" n=0
  [ -f "$ROOT/notified" ] && n=1
  if [ "$rc" = "$erc" ] && grep -qF -- "$sub" <<<"$out" && [ "$n" = "$en" ]; then echo "PASS: $label"; _pass=$((_pass+1))
  else echo "FAIL: $label (rc=$rc notified=$n)"; echo "$out" | sed 's/^/    /'; _fail=$((_fail+1)); fi
}

run;                                            check "all clear exits 0, no alert"            0 "[ghas-guard] OK" 0
run FAKE_COMMITTERS=1 FAKE_BILLED_REPOS='[{"name":"landing","advanced_security_committers":1}]'
                                                check "billed committer alerts"                1 "BILLING 1 committer(s) on: landing" 1
run FAKE_USAGE='[{"product":"ghas","date":"2099-01-01T00:00:00Z","netAmount":4.5}]'
                                                check "GHAS usage this month alerts"           1 "GHAS usage this month" 1
run FAKE_CONFIGS='[]';                          check "missing config alerts"                  1 "is MISSING" 1
run FAKE_CONFIGS='[{"id":7,"name":"no-paid-security","enforcement":"unenforced","advanced_security":"disabled","secret_scanning":"disabled","code_scanning_default_setup":"disabled"}]'
                                                check "unenforced config alerts"               1 "enforcement is 'unenforced'" 1
run FAKE_ATTACHED='[{"status":"enforced","repository":{"name":"a"}}]'
                                                check "private repo missing the config alerts" 1 "WITHOUT 'no-paid-security': b" 1
run FAKE_DEFAULT=none;                          check "not default for new repos alerts"       1 "not the default for new private repos" 1
run FAKE_REPOS='[{"name":"a","security_and_analysis":{"secret_scanning":{"status":"enabled"}}}]' FAKE_ATTACHED='[{"status":"enforced","repository":{"name":"a"}}]'
                                                check "enabled paid feature alerts"            1 "ENABLED on private repo(s): a" 1
run FAKE_FAIL=1;                                check "API failure is UNVERIFIED, not a pass"  1 "UNVERIFIED" 1

echo "ghas-guard: $_pass passed, $_fail failed"
[ "$_fail" -eq 0 ]
