#!/usr/bin/env bash
# pr-shepherd.sh scope (ruling INSTALL-1): the brain shepherds its own org, so the Mac job acts only on OS_PR_SHEPHERD_ORG.
# Must not fire (no gh call at all): the variable unset, or set to the brain's primary org. Must fire: another org is polled.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1; OPS="$(pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
_pass=0; _fail=0
pass() { echo "PASS: $1"; _pass=$((_pass+1)); }
fail() { echo "FAIL: $1"; _fail=$((_fail+1)); }
mkdir -p "$T/bin" "$T/home" "$T/ops/lib"
printf '#!/usr/bin/env bash\necho "$*" >> "%s/gh.calls"\nexit 0\n' "$T" > "$T/bin/gh"; chmod +x "$T/bin/gh"
# run a COPY whose pinned PATH line points at the gh stub, so a real gh can never be reached; the source is never edited
cp "$OPS"/lib/*.sh "$T/ops/lib/"
sed 's#^export PATH=.*#export PATH="'"$T"'/bin:/usr/bin:/bin"#' "$OPS/pr-shepherd.sh" > "$T/ops/pr-shepherd.sh"
grep -q "^export PATH=\"$T/bin" "$T/ops/pr-shepherd.sh" || { echo "FAIL: could not pin PATH in the copy"; exit 1; }
run() { rm -f "$T/gh.calls"; env -u OS_PR_SHEPHERD_ORG HOME="$T/home" PATH="$T/bin:/usr/bin:/bin" OS_ORGS="Brain-Org Other" OS_STATE_DIR="$T/state" \
  EBDA_OS_LOCAL_ENV="$T/none.env" DRY_RUN=1 "$@" bash "$T/ops/pr-shepherd.sh" >"$T/out" 2>&1; }
run
grep -q 'OS_PR_SHEPHERD_ORG not set' "$T/out" && [ ! -s "$T/gh.calls" ] && pass "unset: skips with a reason, no gh call" || { fail "unset did not skip"; cat "$T/out"; }
run OS_PR_SHEPHERD_ORG=Brain-Org
grep -q 'shepherded by the brain' "$T/out" && [ ! -s "$T/gh.calls" ] && pass "brain's own org: refuses a second shepherd, no gh call" || { fail "brain org not refused"; cat "$T/out"; }
run OS_PR_SHEPHERD_ORG=Other
grep -q 'orgs/Other/repos' "$T/gh.calls" 2>/dev/null && pass "OS_PR_SHEPHERD_ORG=Other: polls that org (must fire)" || { fail "other org not polled"; cat "$T/out"; cat "$T/gh.calls" 2>/dev/null; }
grep -q 'Brain-Org' "$T/gh.calls" 2>/dev/null && fail "touched the brain's org" || pass "never touches the brain's org"
echo "pr-shepherd-scope: $_pass passed, $_fail failed"
[ "$_fail" = 0 ]
