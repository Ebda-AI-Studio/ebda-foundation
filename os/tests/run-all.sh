#!/usr/bin/env bash
# Every OS test suite, in one command: the string, standard-links and identity-literal guards, the config parity check, the ops suites (lib/shell/node/remediation) and the Linux smoke.
# Exit non-zero when any part fails. Usage: bash os/tests/run-all.sh [--quiet]
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
rc=0
SLOW_S="${RUN_TESTS_SLOW_S:-20}"
T0=$SECONDS
# `slow <section>`: a section that took >= SLOW_S seconds says so, as it finishes (a 25-minute CI timeout once left no clue where the time went).
slow() { local d=$(( SECONDS - T0 )); [ "$d" -lt "$SLOW_S" ] || echo "  slow  $1 ${d}s"; return 0; }
echo "== no-force-strings =="; T0=$SECONDS; bash "$ROOT/os/tests/no-force-strings.test.sh" || rc=1; slow "no-force-strings"
echo "== no-literal-config =="; T0=$SECONDS; bash "$ROOT/os/tests/no-literal-config.test.sh" || rc=1; slow "no-literal-config"
echo "== standard-links =="; T0=$SECONDS; node "$ROOT/os/tests/standard-links.test.mjs" || rc=1; slow "standard-links"
echo "== os-local-list =="; T0=$SECONDS; bash "$ROOT/os/tests/os-local-list.test.sh" || rc=1; slow "os-local-list"
echo "== os-config-parity =="; T0=$SECONDS; bash "$ROOT/os/tests/os-config-parity.test.sh" || rc=1; slow "os-config-parity"
echo "== install-dryrun =="; T0=$SECONDS; bash "$ROOT/os/tests/install-dryrun.test.sh" || rc=1; slow "install-dryrun"
echo "== wt-safety (lib) =="; T0=$SECONDS; for t in "$ROOT"/os/ops/lib/__tests__/wt-*.test.sh; do bash "$t" || rc=1; done; slow "wt-safety (lib)"
echo "== no-bare-fetch-default =="; T0=$SECONDS; bash "$ROOT/os/tests/no-bare-fetch-default.test.sh" || rc=1; slow "no-bare-fetch-default"
echo "== brain-deploy-dry =="; T0=$SECONDS; bash "$ROOT/os/tests/brain-deploy-dry.test.sh" || rc=1; slow "brain-deploy-dry"
echo "== cutover-gate =="; T0=$SECONDS; bash "$ROOT/os/tests/cutover-gate.test.sh" || rc=1; slow "cutover-gate"
echo "== force-purge-check =="; T0=$SECONDS; bash "$ROOT/os/tests/force-purge-check.test.sh" || rc=1; slow "force-purge-check"
echo "== drain =="; T0=$SECONDS; bash "$ROOT/os/tests/drain.test.sh" || rc=1; slow "drain"
echo "== ops suites ==";       T0=$SECONDS; bash "$ROOT/os/ops/run-tests.sh" "$@" || rc=1; slow "ops suites"
echo "== linux-smoke ==";      T0=$SECONDS; bash "$ROOT/os/tests/linux-smoke.test.sh" || rc=1; slow "linux-smoke"
[ "$rc" -eq 0 ] && echo "os run-all: PASS" || echo "os run-all: FAIL"
exit "$rc"
