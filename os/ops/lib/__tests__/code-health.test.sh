#!/usr/bin/env bash
# Test code-health.py — native detectors only (no --llm, no knip/jscpd needed),
# so the test is deterministic + offline. Run: bash ops/lib/__tests__/code-health.test.sh
set -euo pipefail

ENGINE="$(dirname "$0")/../code-health.py"
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

_pass=0; _fail=0
assert_py() {
  local label="$1" pycode="$2"
  if python3 - <<PY
${pycode}
PY
  then echo "PASS: $label"; _pass=$((_pass + 1))
  else echo "FAIL: $label"; _fail=$((_fail + 1)); fi
}

# ---- build a fixture repo with a known duplicated block + a complex function ----
mkdir -p "$ROOT/src" "$ROOT/apps/web"
cat > "$ROOT/package.json" <<'JSON'
{ "name": "fixture", "version": "1.0.0" }
JSON

# A 30+ line block, duplicated VERBATIM across two files in different layers.
gen_block() {
  cat <<'TS'
export function processOrder(order, ctx) {
  const items = order.items || [];
  let total = 0;
  for (const it of items) {
    const price = it.price || 0;
    const qty = it.qty || 1;
    const lineTotal = price * qty;
    total += lineTotal;
    if (it.discount) {
      total -= it.discount;
    }
    if (it.tax) {
      total += it.tax;
    }
    ctx.log(`line ${it.sku} = ${lineTotal}`);
  }
  if (total < 0) total = 0;
  const shipping = total > 100 ? 0 : 10;
  total += shipping;
  const result = { total, shipping, count: items.length };
  ctx.audit(result);
  return result;
}
TS
}
gen_block > "$ROOT/src/orders.ts"
gen_block > "$ROOT/apps/web/checkout.ts"

# A deeply-nested, long, heavily-branched function (overcomplexity).
python3 - "$ROOT/src/tangle.ts" <<'PY'
import sys
lines = ["export function tangle(a, b, c, d) {"]
for i in range(40):
    lines.append("  if (a > %d) {" % i)
    lines.append("    for (let j = 0; j < b; j++) {")
    lines.append("      while (c && d) { c = c && d || a; }")
    lines.append("    }")
    lines.append("  }")
lines.append("  return a;")
lines.append("}")
open(sys.argv[1], "w").write("\n".join(lines))
PY

OUT="$(python3 "$ENGINE" --repo fixture --dir "$ROOT" --cap 25)"

assert_py "engine emits a valid JSON array of schema findings" "
import json
arr = json.loads('''${OUT}''')
assert isinstance(arr, list), 'not a list'
req = {'repo','class','severity','file','line','title','detail','fix','autofixable'}
for f in arr:
    assert req <= set(f), 'missing keys: %s' % (req - set(f))
    assert f['repo'] == 'fixture'
    assert f['autofixable'] is False, 'must be propose-only'
    assert f['severity'] in ('critical','high','medium','low')
"

assert_py "detects the cross-file duplication" "
import json
arr = json.loads('''${OUT}''')
assert any(f['class'] == 'duplication' for f in arr), 'no duplication finding'
"

assert_py "detects the overcomplex function" "
import json
arr = json.loads('''${OUT}''')
assert any(f['class'] == 'overcomplexity' for f in arr), 'no overcomplexity finding'
"

# ---- fail-open: a missing dir must yield [] and exit 0, never crash ----
OUT_EMPTY="$(python3 "$ENGINE" --repo x --dir "$ROOT/does-not-exist" --cap 5)"
assert_py "missing dir → [] (fail-open)" "
import json
assert json.loads('''${OUT_EMPTY}''') == []
"

# ---- a clean repo (no dupes / no complex fns) yields no false positives ----
CLEAN="$(mktemp -d)"; echo 'export const a = 1;' > "$CLEAN/a.ts"; echo 'export const b = 2;' > "$CLEAN/b.ts"
OUT_CLEAN="$(python3 "$ENGINE" --repo clean --dir "$CLEAN" --cap 5)"; rm -rf "$CLEAN"
assert_py "clean repo → no duplication/overcomplexity findings" "
import json
arr = json.loads('''${OUT_CLEAN}''')
assert not any(f['class'] in ('duplication','overcomplexity') for f in arr), 'false positive: %s' % arr
"

echo ""
echo "code-health: $_pass passed, $_fail failed"
[ "$_fail" -eq 0 ] || exit 1
