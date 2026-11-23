#!/usr/bin/env bash
# changelog-assemble.sh (CHANGELOG-FRAGMENTS-1): fragments are one line each, Unreleased stays empty, --release folds them in and deletes them.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1; OPS="$(pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
_pass=0; _fail=0
pass() { echo "PASS: $1"; _pass=$((_pass+1)); }
fail() { echo "FAIL: $1"; _fail=$((_fail+1)); }
run() { CHANGELOG_ROOT="$T" bash "$OPS/changelog-assemble.sh" "$@" >"$T/out" 2>"$T/err"; }
reset() { rm -rf "$T/changelog.d"; mkdir -p "$T/changelog.d"; printf '# Changelog\n\n## Unreleased\n\n## v0.1.0\n- old\n' > "$T/CHANGELOG.md"; }

reset; printf -- '- A-1 (x): one\n' > "$T/changelog.d/a-1.md"; printf -- '- B-1 (y): two\n' > "$T/changelog.d/b-1.md"; echo '# readme' > "$T/changelog.d/README.md"
run --check && pass "valid fragments + empty Unreleased pass" || fail "valid check ($(cat "$T/err"))"
run; [ "$(cat "$T/out")" = "$(printf -- '- A-1 (x): one\n- B-1 (y): two')" ] && pass "preview prints the bullets in file-name order" || fail "preview ($(cat "$T/out"))"

reset; printf -- '- A-1: one\n- A-2: two\n' > "$T/changelog.d/a.md"
run --check; [ $? = 1 ] && grep -q "exactly ONE line" "$T/err" && pass "a two-line fragment fails" || fail "two-line fragment"
reset; printf 'no bullet marker\n' > "$T/changelog.d/a.md"
run --check; [ $? = 1 ] && pass "a fragment not starting with '- ' fails" || fail "no marker"
reset; printf -- '- A: x\n' > "$T/changelog.d/Bad Name.md"
run --check; [ $? = 1 ] && grep -q "file name" "$T/err" && pass "a bad file name fails" || fail "bad name"
reset; : > "$T/changelog.d/empty.md"
run --check; [ $? = 1 ] && pass "an empty fragment fails" || fail "empty fragment"

reset; printf '# Changelog\n\n## Unreleased\n- hand written\n\n## v0.1.0\n- old\n' > "$T/CHANGELOG.md"
printf -- '- A-1: one\n' > "$T/changelog.d/a-1.md"
run --check; [ $? = 1 ] && grep -q "must stay empty" "$T/err" && pass "a hand-written Unreleased bullet fails the check" || fail "hand bullet"
run --release v0.2.0; [ $? = 1 ] && grep -q "hand-written" "$T/err" && pass "release refuses to drop a hand-written bullet" || fail "release drop"

reset; printf '# Changelog\n\nno unreleased heading\n' > "$T/CHANGELOG.md"
run --check; [ $? = 1 ] && grep -q "no '## Unreleased'" "$T/err" && pass "missing Unreleased heading fails closed" || fail "no heading"

reset; printf -- '- A-1 (x): one\n' > "$T/changelog.d/a-1.md"
run --release v0.2.0 && grep -q '^## v0.2.0$' "$T/CHANGELOG.md" && grep -q -- '- A-1 (x): one' "$T/CHANGELOG.md" && [ ! -e "$T/changelog.d/a-1.md" ] && pass "release folds the fragment under the version and deletes it" || fail "release ($(cat "$T/err"))"
[ "$(awk '/^## /{print}' "$T/CHANGELOG.md" | tr '\n' ' ')" = "## Unreleased ## v0.2.0 ## v0.1.0 " ] && pass "Unreleased stays above the new version and empty" || fail "section order"
reset; printf -- '- A-1: one\n' > "$T/changelog.d/a-1.md"; run --release v0.2.0; run --release v0.2.0
[ $? = 1 ] && pass "a second release with nothing left fails" || fail "second release"
run --release 0.2; [ $? -ne 0 ] && pass "a malformed version is refused" || fail "bad version"
run --bogus; [ $? = 64 ] && pass "unknown flag exits 64" || fail "unknown flag"

echo "changelog-assemble: $_pass passed, $_fail failed"; [ "$_fail" = 0 ]
