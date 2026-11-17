#!/usr/bin/env bash
# run-tests.sh / run-all.sh print a `slow` line for a suite or section that takes >= RUN_TESTS_SLOW_S seconds, even in --quiet mode,
# as it finishes, so a CI timeout (the OS job ran 25:19 twice on 2026-11-17 with no output) says where the time went.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
pass=0; fail=0
ok() { pass=$((pass + 1)); echo "  ok    $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL  $1"; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/ops/tests"
cp "$ROOT/os/ops/run-tests.sh" "$T/ops/run-tests.sh"
printf '#!/usr/bin/env bash\nsleep 2\nexit 0\n' > "$T/ops/tests/zz-slow.test.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/ops/tests/zz-fast.test.sh"

# the copy finds only the ops-shell class (the others are empty => exit 2, which is irrelevant here: we read the stream)
out="$(RUN_TESTS_SLOW_S=1 bash "$T/ops/run-tests.sh" --quiet 2>&1)"
grep -q '  slow  ops-shell/zz-slow 2s' <<<"$out" && ok "a suite over the threshold prints a slow line in --quiet mode" || bad "no slow line for the slow suite: $out"
! grep -q 'slow  ops-shell/zz-fast' <<<"$out" && ok "a fast suite prints no slow line" || bad "the fast suite was reported slow"
grep -q 'slowest suites' <<<"$out" && grep -qE '^ +2s ops-shell/zz-slow' <<<"$out" && ok "the summary lists the slowest suites" || bad "no slowest-suites summary: $out"

out2="$(RUN_TESTS_SLOW_S=999 bash "$T/ops/run-tests.sh" --quiet 2>&1)"
! grep -q 'slow' <<<"$out2" && ok "above-threshold only: nothing printed when every suite is under it" || bad "slow output with a 999 s threshold"

# run-all.sh: every section is timed, and the CI job reports a cancel/timeout
n=$(grep -c 'slow "' "$ROOT/os/tests/run-all.sh")
[ "$n" -ge 14 ] && ok "run-all.sh times each of its sections ($n)" || bad "run-all.sh times only $n sections"
grep -q 'timeout-minutes: 45' "$ROOT/.github/workflows/ci.yml" && ok "the OS job backstop is 45 min" || bad "OS job timeout is not 45"
grep -q 'if: cancelled()' "$ROOT/.github/workflows/ci.yml" && grep -q 'TIMEOUT, not a test failure' "$ROOT/.github/workflows/ci.yml" && ok "the OS job says so when it was cancelled (a timeout is reported as cancelled)" || bad "no cancelled-run report step"

echo "run-tests-slow: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
