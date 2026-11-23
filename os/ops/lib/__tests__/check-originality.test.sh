#!/usr/bin/env bash
# check-originality.sh must flag a re-skinned duplicate (entity swapped, prose
# identical), must NOT flag unrelated files, and must REFUSE to call an empty
# corpus clean.
# Run: bash ops/lib/__tests__/check-originality.test.sh
set -uo pipefail
SCRIPT="$(cd "$(dirname "$0")/../.." && pwd)/check-originality.sh"
_pass=0; _fail=0
ok() { echo "PASS: $1"; _pass=$((_pass+1)); }
no() { echo "FAIL: $1"; _fail=$((_fail+1)); }

H="$(mktemp -d)"
base='A cached read must declare a staleness class before it ships. Price and
inventory and permissions and entitlements are never stale and need event
invalidation on every single write path, clearing every layer that holds them.
A time to live alone is not sufficient for that whole class of data, and a
delete dirties more key namespaces than an update ever will in practice.'
printf '%s\n' "$base" > "$H/a.md"
# a re-skin: same prose, entity nouns swapped — must still score as a duplicate
printf '%s\n' "${base//inventory/stock}" | sed 's/never stale/not stale/' > "$H/b.md"
printf 'Arabic right to left typography needs a font fallback stack and logical properties, which is a completely different subject with no shared phrasing whatsoever here.\n' > "$H/c.md"

bash "$SCRIPT" --dir "$H" >/dev/null 2>&1 && no "fails on a near-duplicate pair" || ok "fails on a near-duplicate pair"
out="$(bash "$SCRIPT" --dir "$H" 2>&1)"
grep -q 'a.md' <<<"$out" && grep -q 'b.md' <<<"$out" && ok "names the duplicate pair" || no "names the duplicate pair"
grep -q 'FAIL' <<<"$out" && ok "marks the pair FAIL" || no "marks the pair FAIL"
echo "$out" | grep -E 'FAIL.*c\.md' >/dev/null && no "does not FAIL an unrelated file" || ok "does not FAIL an unrelated file"

# entity neutralisation: identical prose differing ONLY by product name must be caught
D2="$(mktemp -d)"
printf 'The tenant resolver must throw on an unresolved identifier and never default to the first row of the table because that silently serves one customer the data of another.\n' > "$D2/store.md"
printf 'The tenant resolver must throw on an unresolved identifier and never default to the first row of the table because that silently serves one customer the data of another.\n' | sed 's/tenant/tenant/' > "$D2/msg.md"
bash "$SCRIPT" --dir "$D2" >/dev/null 2>&1 && no "catches an entity-swapped re-skin" || ok "catches an entity-swapped re-skin"
rm -rf "$D2"

# below the threshold it passes
rm -f "$H/b.md"
bash "$SCRIPT" --dir "$H" >/dev/null 2>&1 && ok "passes with no duplicates" || no "passes with no duplicates"

# fewer than 2 comparable files -> exit 2, NOT a pass
D3="$(mktemp -d)"; echo "one short file" > "$D3/only.md"
bash "$SCRIPT" --dir "$D3" >/dev/null 2>&1; rc=$?
[ "$rc" = "2" ] && ok "single file exits 2 (nothing compared)" || no "single file exits 2 (got $rc)"
D4="$(mktemp -d)"
bash "$SCRIPT" --dir "$D4" >/dev/null 2>&1; rc=$?
[ "$rc" = "2" ] && ok "empty dir exits 2, not clean" || no "empty dir exits 2 (got $rc)"
rm -rf "$D3" "$D4"

# a missing dir is an argument error, not a silent pass
bash "$SCRIPT" --dir "$H/nope" >/dev/null 2>&1; rc=$?
[ "$rc" = "64" ] && ok "missing dir exits 64" || no "missing dir exits 64 (got $rc)"

rm -rf "$H"
echo; echo "check-originality: $_pass passed, $_fail failed"
[ "$_fail" -eq 0 ]
