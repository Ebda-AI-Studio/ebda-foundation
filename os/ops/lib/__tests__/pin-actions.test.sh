#!/usr/bin/env bash
# pin-actions.sh: rewrite mutable GitHub Action refs to commit SHAs; --check gates CI.
#
# The load-bearing assertion is "--check FAILS on a mutable ref". A pinning gate
# that cannot fail is the same fail-open shape the whole supply-chain phase exists
# to remove, so it is asserted before anything else.
# Run: bash ops/lib/__tests__/pin-actions.test.sh
set -uo pipefail
SCRIPT="$(cd "$(dirname "$0")/../.." && pwd)/pin-actions.sh"
_pass=0; _fail=0
ok() { echo "PASS: $1"; _pass=$((_pass+1)); }
no() { echo "FAIL: $1"; _fail=$((_fail+1)); }
md5of() { md5 -q "$1" 2>/dev/null || md5sum "$1" | cut -d' ' -f1; }

H="$(mktemp -d)"; mkdir -p "$H/repo/.github/workflows" "$H/bin"
cat > "$H/repo/.github/workflows/w.yml" <<'YML'
jobs:
  a:
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: '22'
      - uses: Ebda-AI-Studio/ebda-foundation/.github/workflows/reusable-ci.yml@master
      - uses: ./.github/actions/local
YML

# mock gh: resolve refs to deterministic fake SHAs, fail on anything unknown
cat > "$H/bin/gh" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *repos/actions/checkout/commits*)   echo aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ;;
  *repos/actions/setup-node/commits*) echo bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb ;;
  *repos/Ebda-AI-Studio/ebda-foundation/commits*) echo cccccccccccccccccccccccccccccccccccccccc ;;
  *) exit 1 ;;
esac
SH
chmod +x "$H/bin/gh"
export PATH="$H/bin:$PATH"

# 1. --check must FAIL while refs are mutable
bash "$SCRIPT" --check --repo "$H/repo" >/dev/null 2>&1 \
  && no "--check fails on mutable refs" || ok "--check fails on mutable refs"

# 2. --check names the offending file:line (a gate that fails without saying where is useless)
out="$(bash "$SCRIPT" --check --repo "$H/repo" 2>&1)"
grep -q '.github/workflows/w.yml:4' <<<"$out" && ok "--check names file:line" || no "--check names file:line"

# 3. --check must not modify anything
before_check="$(md5of "$H/repo/.github/workflows/w.yml")"
bash "$SCRIPT" --check --repo "$H/repo" >/dev/null 2>&1
[ "$before_check" = "$(md5of "$H/repo/.github/workflows/w.yml")" ] \
  && ok "--check is read-only" || no "--check is read-only"

# 4. rewrite
bash "$SCRIPT" --repo "$H/repo" >/dev/null 2>&1 || no "rewrite exits 0"
grep -q 'uses: actions/checkout@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa # v4' "$H/repo/.github/workflows/w.yml" \
  && ok "checkout pinned with version comment" || no "checkout pinned with version comment"

# 5. a reusable-workflow ref keeps its path and resolves against owner/repo
grep -q 'uses: Ebda-AI-Studio/ebda-foundation/.github/workflows/reusable-ci.yml@cccccccccccccccccccccccccccccccccccccccc # master' \
  "$H/repo/.github/workflows/w.yml" && ok "reusable workflow path preserved" || no "reusable workflow path preserved"

# 6. a local ./ ref is skipped, not treated as an error
grep -q 'uses: ./.github/actions/local' "$H/repo/.github/workflows/w.yml" \
  && ok "local ./ ref untouched" || no "local ./ ref untouched"

# 7. unrelated lines and indentation survive
grep -q "^          node-version: '22'" "$H/repo/.github/workflows/w.yml" \
  && ok "unrelated lines untouched" || no "unrelated lines untouched"

# 8. --check now passes
bash "$SCRIPT" --check --repo "$H/repo" >/dev/null 2>&1 \
  && ok "--check passes once pinned" || no "--check passes once pinned"

# 9. idempotent
before="$(md5of "$H/repo/.github/workflows/w.yml")"
bash "$SCRIPT" --repo "$H/repo" >/dev/null 2>&1
[ "$before" = "$(md5of "$H/repo/.github/workflows/w.yml")" ] && ok "idempotent" || no "idempotent"

# 10. re-pinning an already-pinned ref must not stack comments onto one line
#     (the earlier form of this assertion counted '# v4' repo-wide and tripped on
#      two DIFFERENT actions both legitimately at v4 — a test bug, not a code bug)
stacked="$(grep -c 'uses:.*#.*#' "$H/repo/.github/workflows/w.yml")"
[ "$stacked" = "0" ] && ok "no stacked version comments" || no "no stacked version comments (got $stacked)"

# 11. an unresolvable ref exits 2 — never silently skipped
mkdir -p "$H/repo2/.github/workflows"
printf '      - uses: nope/nope@v9\n' > "$H/repo2/.github/workflows/w.yml"
bash "$SCRIPT" --repo "$H/repo2" >/dev/null 2>&1; rc=$?
[ "$rc" = "2" ] && ok "unresolvable ref exits 2" || no "unresolvable ref exits 2 (got $rc)"

# 12. a repo with NO workflows is a no-op success, not a crash
mkdir -p "$H/repo3"
bash "$SCRIPT" --check --repo "$H/repo3" >/dev/null 2>&1 \
  && ok "repo without workflows exits 0" || no "repo without workflows exits 0"

# 13-15. nested workflow dirs (the template-scaffold case that the blast-radius
#        sweep surfaced: template/.github/workflows was invisible to a root-only scan)
mkdir -p "$H/repo4/.github/workflows" "$H/repo4/template/.github/workflows" "$H/repo4/fixtures/bad/.github/workflows"
printf 'jobs:\n  a:\n    steps:\n      - uses: actions/checkout@v4\n' > "$H/repo4/template/.github/workflows/t.yml"
printf 'jobs:\n  a:\n    steps:\n      - uses: actions/checkout@v4\n' > "$H/repo4/fixtures/bad/.github/workflows/f.yml"
printf 'jobs:\n  a:\n    steps:\n      - uses: actions/checkout@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa # v4\n' > "$H/repo4/.github/workflows/root.yml"

bash "$SCRIPT" --check --repo "$H/repo4" >/dev/null 2>&1 \
  && ok "root-only scan ignores nested dirs by default" || no "root-only scan ignores nested dirs by default"

bash "$SCRIPT" --check --include-nested --repo "$H/repo4" >/dev/null 2>&1 \
  && no "--include-nested finds the template's mutable ref" || ok "--include-nested finds the template's mutable ref"

# an ignore file must exclude audit fixtures, which are deliberately imperfect inputs
printf 'fixtures/*\n' > "$H/repo4/.pin-actions-ignore"
out4="$(bash "$SCRIPT" --check --include-nested --repo "$H/repo4" 2>&1)"
grep -q 'template/.github/workflows/t.yml' <<<"$out4" && ok "nested finding reports a repo-relative path" || no "nested finding reports a repo-relative path"
grep -q 'fixtures/' <<<"$out4" && no "ignore file excludes fixtures" || ok "ignore file excludes fixtures"

rm -rf "$H"
echo; echo "pin-actions: $_pass passed, $_fail failed"
[ "$_fail" -eq 0 ]
