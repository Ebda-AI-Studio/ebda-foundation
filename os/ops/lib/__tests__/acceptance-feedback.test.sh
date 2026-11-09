#!/usr/bin/env bash
# Test acceptance-feedback.sh offline by mocking `gh`. Isolates state via $HOME.
# Run: bash ops/lib/__tests__/acceptance-feedback.test.sh
set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")/../.." && pwd)/acceptance-feedback.sh"
_pass=0; _fail=0
ok() { echo "PASS: $1"; _pass=$((_pass+1)); }
no() { echo "FAIL: $1"; _fail=$((_fail+1)); }

# ---- case 1: no ledger -> exit 0, status note ----
H1="$(mktemp -d)"
HOME="$H1" bash "$SCRIPT" >/dev/null 2>&1 && ok "no ledger -> exit 0" || no "no ledger -> exit 0"
rm -rf "$H1"

# ---- case 2: ledger with a wontfix issue (mocked gh) -> suppressed + precision ----
H2="$(mktemp -d)"
mkdir -p "$H2/.whisky-os-state" "$H2/bin"
# fake ledger: one wontfix-bound entry (real-looking URL) + one merged entry
cat > "$H2/.whisky-os-state/dream-ledger.json" <<'JSON'
{ "entries": [
  { "repo":"ebda-store","class":"perf","title":"unbounded findMany",
    "issue_url":"https://github.com/Ebda-AI-Studio/ebda-store/issues/101","tier":"B","decided_at":"2026-05-01T00:00:00" },
  { "repo":"ebda-whatsapp","class":"dep-bump","title":"lockfile out of sync",
    "issue_url":"https://github.com/Ebda-AI-Studio/ebda-whatsapp/issues/202","tier":"B","decided_at":"2026-05-01T00:00:00" }
] }
JSON
# mock gh: issue 101 -> wontfix(NOT_PLANNED), 202 -> merged(COMPLETED)
cat > "$H2/bin/gh" <<'SH'
#!/usr/bin/env bash
# args: issue view <url> --json ...
url=""
for a in "$@"; do case "$a" in https://*) url="$a";; esac; done
case "$url" in
  *issues/101) echo '{"state":"CLOSED","stateReason":"NOT_PLANNED","updatedAt":"2026-01-01T00:00:00Z","title":"unbounded findMany"}' ;;
  *issues/202) echo '{"state":"CLOSED","stateReason":"COMPLETED","updatedAt":"2026-01-01T00:00:00Z","title":"lockfile out of sync"}' ;;
  *) echo '' ;;
esac
SH
chmod +x "$H2/bin/gh"

HOME="$H2" PATH="$H2/bin:$PATH" bash "$SCRIPT" >/dev/null 2>&1 && rc=0 || rc=1
[ "$rc" = "0" ] && ok "wontfix run -> exit 0" || no "wontfix run -> exit 0"

# the wontfix finding should be auto-suppressed
if python3 -c "
import json,sys
s=json.load(open('$H2/.whisky-os-state/findings-suppressions.json'))
s=s if isinstance(s,list) else s.get('suppress',[])
assert any(x.get('class')=='perf' and 'findMany' in (x.get('title') or '') for x in s), s
assert not any(x.get('class')=='dep-bump' for x in s), 'merged one must NOT be suppressed: %s'%s
"; then ok "wontfix auto-suppressed, merged not suppressed"; else no "wontfix auto-suppressed, merged not suppressed"; fi

# precision = 1 accepted / (1 accepted + 1 wontfix) = 0.5
if python3 -c "
import json
m=json.load(open('$H2/.whisky-os-state/acceptance-metrics.json'))['latest']
assert m['merged']==1 and m['wontfix']==1, m
assert abs(m['precision']-0.5)<1e-9, m
"; then ok "precision computed = 0.5"; else no "precision computed = 0.5"; fi
rm -rf "$H2"

echo ""
echo "acceptance-feedback: $_pass passed, $_fail failed"
[ "$_fail" -eq 0 ] || exit 1
