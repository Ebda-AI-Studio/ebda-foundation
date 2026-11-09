#!/usr/bin/env bash
# Test detector-run.py against the seeded detectors. Offline, deterministic.
# Run: bash ops/lib/__tests__/detector-run.test.sh
set -euo pipefail

ENGINE="$(dirname "$0")/../detector-run.py"
DETECTORS="$(dirname "$0")/../../detectors"
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

mkdir -p "$ROOT/migrations" "$ROOT/app/api/orders" "$ROOT/src"

# (1) RLS enabled, NO write policy -> finding
cat > "$ROOT/migrations/001_rls.sql" <<'SQL'
ALTER TABLE orders ENABLE ROW LEVEL SECURITY;
CREATE POLICY orders_select ON orders FOR SELECT USING (tenant_id = current_tenant());
SQL
# (2) RLS enabled WITH write policy -> no finding (the guard is present)
cat > "$ROOT/migrations/002_rls_ok.sql" <<'SQL'
ALTER TABLE products ENABLE ROW LEVEL SECURITY;
CREATE POLICY products_all ON products FOR ALL USING (tenant_id = current_tenant()) WITH CHECK (true);
SQL
# (3) raw SQL template injection -> finding
cat > "$ROOT/src/db.ts" <<'TS'
export async function q(p, x) {
  return p.$queryRawUnsafe(`SELECT * FROM t WHERE name = ${x}`);
}
TS
# (4) API route reads body, NO validation -> finding
cat > "$ROOT/app/api/orders/route.ts" <<'TS'
export async function POST(req) {
  const body = await req.json();
  return create(body);
}
TS
# (5) API route WITH zod -> no finding
mkdir -p "$ROOT/app/api/safe"
cat > "$ROOT/app/api/safe/route.ts" <<'TS'
import { z } from "zod";
const S = z.object({ name: z.string() });
export async function POST(req) {
  const body = S.parse(await req.json());
  return create(body);
}
TS
# (6) storeUrl('') -> finding
cat > "$ROOT/src/links.ts" <<'TS'
export const cartHref = storeUrl('');
TS
# (7) clean file -> nothing
cat > "$ROOT/src/clean.ts" <<'TS'
export const add = (a, b) => a + b;
TS

OUT="$(python3 "$ENGINE" --repo fix --dir "$ROOT" --detectors "$DETECTORS" --cap 25)"

assert_py "valid schema + propose-only" "
import json
arr = json.loads('''${OUT}''')
req = {'repo','class','severity','file','line','title','detail','fix','autofixable'}
for f in arr:
    assert req <= set(f), f
    assert f['autofixable'] is False
"
assert_py "RLS-without-write-policy fires once (not on the FOR ALL file)" "
import json
arr = json.loads('''${OUT}''')
rls = [f for f in arr if f['class']=='security-rls']
assert len(rls) == 1, 'expected 1 rls finding, got %d: %s' % (len(rls), [f['file'] for f in rls])
assert '001_rls' in rls[0]['file']
"
assert_py "raw-SQL template injection detected" "
import json
arr = json.loads('''${OUT}''')
assert any(f['class']=='security-injection' and 'db.ts' in f['file'] for f in arr), arr
"
assert_py "missing-validation route flagged, zod route NOT flagged" "
import json
arr = json.loads('''${OUT}''')
val = [f for f in arr if f['class']=='security-validation']
files = [f['file'] for f in val]
assert any('orders/route.ts' in x for x in files), files
assert not any('safe/route.ts' in x for x in files), 'zod route false-positive: %s' % files
"
# storeurl-trailing-slash was RETIRED in #48 — it flagged every storeUrl('') call
# but the helper returns the prefix (never '//') for '', so it was 20/20 false on
# store. Retirement is implemented by the leading underscore in the filename, which
# detector-run.py:72 skips. This test asserted the OLD behaviour and had been red
# ever since; it now locks in the retirement instead, so re-enabling the detector
# by dropping the underscore fails loudly rather than silently returning the
# false positives.
assert_py "retired _storeurl detector does NOT fire (underscore = disabled)" "
import json
arr = json.loads('''${OUT}''')
assert not any('links.ts' in (f.get('file') or '') for f in arr), 'retired detector fired: %s' % arr
"
assert_py "clean.ts produces no finding" "
import json
arr = json.loads('''${OUT}''')
assert not any('clean.ts' in (f.get('file') or '') for f in arr), arr
"
# fail-open
OUT_EMPTY="$(python3 "$ENGINE" --repo x --dir "$ROOT/nope" --detectors "$DETECTORS")"
assert_py "missing dir -> [] (fail-open)" "
import json
assert json.loads('''${OUT_EMPTY}''') == []
"

echo ""
echo "detector-run: $_pass passed, $_fail failed"
[ "$_fail" -eq 0 ] || exit 1
