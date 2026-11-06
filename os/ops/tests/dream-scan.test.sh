#!/usr/bin/env bash
# dream-scan / dream-research: a fake Ebda product (repo + live page) yields findings with product + evidence + stable keys;
# no targets -> exit 3 (loud, not "all clean"); findings reach the brain ingest or the spool, never a chat; research ranks the
# week's history into `improvement` findings. No network: audit and CI results come from fixtures.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1; OPS="$(pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
_pass=0; _fail=0
pass() { echo "PASS: $1"; _pass=$((_pass+1)); }
fail() { echo "FAIL: $1"; _fail=$((_fail+1)); }
P="$T/shop"; mkdir -p "$P/src" "$T/home" "$T/state" "$T/proj/Ebda-AI-Studio/internal-projects/ebda-store/.git"
git -C "$P" init -q; git -C "$P" config user.email t@t; git -C "$P" config user.name t
echo '{}' > "$P/package-lock.json"; GIT_COMMITTER_DATE="2026-01-01T00:00:00" GIT_AUTHOR_DATE="2026-01-01T00:00:00" git -C "$P" add package-lock.json; GIT_COMMITTER_DATE="2026-01-01T00:00:00" GIT_AUTHOR_DATE="2026-01-01T00:00:00" git -C "$P" commit -qm lock
echo '{"name":"shop"}' > "$P/package.json"; git -C "$P" add package.json; git -C "$P" commit -qm pkg
echo 'export const cart = 1' > "$P/src/cart.ts"
printf '<html><head></head><body><img src="a.png"><p>hi</p></body></html>' > "$T/page.html"
cat > "$T/audit.json" <<'J'
{"vulnerabilities":{"lodash":{"name":"lodash","severity":"high","range":"<4.17.21","fixAvailable":true,"via":[{"title":"Prototype Pollution","url":"https://github.com/advisories/GHSA-x"}]},
                    "minimist":{"name":"minimist","severity":"low","via":[]}}}
J
echo '[{"name":"CI","conclusion":"failure","url":"https://example.test/run/1","headBranch":"main"},{"name":"CI","conclusion":"success","url":"u","headBranch":"main"}]' > "$T/ci.json"
printf '{"dream_products":["shop|%s|file://%s"]}' "$P" "$T/page.html" > "$T/local.json"
: > "$T/services.env"
E=(env HOME="$T/home" EBDA_OS_LOCAL_ENV="$T/none.env" EBDA_OS_LOCAL_JSON="$T/local.json" OS_STATE_DIR="$T/state" OS_SERVICES_ENV="$T/services.env" OS_PROJECTS_DIR="$T/proj" \
   DREAM_SCAN_AUDIT_JSON="$T/audit.json" DREAM_SCAN_CI_JSON="$T/ci.json" DREAM_SCAN_NO_NET=1)

"${E[@]}" bash "$OPS/dream-scan.sh" >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && pass "scan exits 0" || fail "scan rc=$rc"
F="$T/state/dream-findings.json"
chk() { python3 -I -c "
import json,sys
fs=json.load(open(sys.argv[1]))['findings']
keys={f['key'] for f in fs}
$1" "$F"; }
chk "sys.exit(0 if len(fs)>=6 and all(f['product']=='shop' and f['evidence'] and f['key'].startswith('shop:') for f in fs) else 1)" && pass "every finding has product, evidence and a product-scoped key" || { fail "finding shape"; cat "$F"; }
chk "sys.exit(0 if 'shop:audit:lodash:high' in keys and 'shop:audit:minimist:low' not in keys else 1)" && pass "npm audit: high found, low ignored" || fail "audit finding"
chk "sys.exit(0 if 'shop:lockfile-drift' in keys else 1)" && pass "lockfile drift found" || fail "lockfile drift"
chk "sys.exit(0 if 'shop:untested:src/cart.ts' in keys else 1)" && pass "untested path found with file:line evidence" || fail "untested"
chk "sys.exit(0 if 'shop:ci:CI' in keys else 1)" && pass "failing CI (latest run of the workflow) found" || fail "ci"
chk "sys.exit(0 if {'shop:seo:title','shop:a11y:lang','shop:a11y:img-alt','shop:seo:h1'} <= keys else 1)" && pass "live probe: title, lang, alt, h1" || fail "live probes"
cp "$F" "$T/first.json"; "${E[@]}" bash "$OPS/dream-scan.sh" >/dev/null 2>&1
python3 -I -c "
import json,sys; a={f['key'] for f in json.load(open(sys.argv[1]))['findings']}; b={f['key'] for f in json.load(open(sys.argv[2]))['findings']}
sys.exit(0 if a==b else 1)" "$T/first.json" "$F" && pass "keys are stable across runs" || fail "keys unstable"

# research: history of two scans -> improvement findings (stable keys), appended
"${E[@]}" bash "$OPS/dream-research.sh" >/dev/null 2>&1
chk "imp=[f for f in fs if f['class']=='improvement']
sys.exit(0 if imp and all(f['key'].startswith('shop:improvement:') and f['product']=='shop' for f in imp) and len(imp)<=3 else 1)" && pass "research ranks scan history into improvement findings (top 3 per product)" || { fail "research"; cat "$F" | head -30; }

# hand-off: through dream.sh, findings reach the spool (no brain configured), nothing is messaged
mkdir -p "$T/fake"; printf '#!/usr/bin/env bash\necho called >> "%s/notify.called"\n' "$T" > "$T/fake/notify.sh"
cp "$OPS/dream-scan.sh" "$OPS/dream-research.sh" "$T/fake/" 2>/dev/null
"${E[@]}" DREAM_PHASES_DIR="$OPS" bash "$OPS/dream.sh" --daily >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && pass "dream.sh with a working scan exits 0" || fail "dream rc=$rc"
python3 -I -c "
import json,sys
rows=[json.loads(l) for l in open(sys.argv[1])]
sys.exit(0 if len(rows)>=6 and any(r['source']=='dream' and r['detail'].get('product')=='shop' and r['detail'].get('evidence') for r in rows) and any(r['kind']=='improvement' for r in rows) else 1)" "$T/state/brain-spool.ndjson" && pass "scan + improvement findings spooled for the brain with product + evidence" || fail "spool content"
[ ! -e "$T/notify.called" ] && pass "no chat message" || fail "notify called"

# no targets: exit 3, loud
printf '{}' > "$T/local.json"
out="$("${E[@]}" bash "$OPS/dream-scan.sh" 2>&1)"; rc=$?
{ [ "$rc" = 3 ] && echo "$out" | grep -q "NO TARGETS"; } && pass "no dream_products -> exit 3 and a loud message" || fail "no-target rc=$rc"
"${E[@]}" DREAM_PHASES_DIR="$OPS" bash "$OPS/dream.sh" --daily >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && pass "dream.sh fails when the scan has no targets" || fail "dream with no targets rc=$rc"

# scan script missing entirely (failed:absent): exit 1, ledger says failed:absent, a dream-scan-failed finding is spooled
mkdir -p "$T/emptyphases"; rm -f "$T/state/brain-spool.ndjson" "$T/state/dream-ledger.json"
"${E[@]}" DREAM_PHASES_DIR="$T/emptyphases" bash "$OPS/dream.sh" --daily >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && pass "dream.sh exits 1 when dream-scan.sh is missing" || fail "missing scan rc=$rc"
python3 -I -c "
import json,sys; e=json.load(open(sys.argv[1]))['entries'][-1]
sys.exit(0 if e['phases_status']['scan']=='failed:absent' else 1)" "$T/state/dream-ledger.json" && pass "ledger records scan failed:absent" || fail "ledger status"
python3 -I -c "
import json,sys
rows=[json.loads(l) for l in open(sys.argv[1])]
sys.exit(0 if any(r['kind']=='dream-scan-failed' and r['source']=='dream' for r in rows) else 1)" "$T/state/brain-spool.ndjson" && pass "a dream-scan-failed finding was spooled for the brain" || fail "no dream-scan-failed finding"

echo "── $_pass passed, $_fail failed ──"
[ "$_fail" -eq 0 ]
