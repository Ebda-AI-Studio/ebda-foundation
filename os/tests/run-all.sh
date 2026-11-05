#!/usr/bin/env bash
# Every OS test suite, in one command: the string and identity-literal guards, the config parity check, the ops suites (lib/shell/node/remediation) and the Linux smoke.
# Exit non-zero when any part fails. Usage: bash os/tests/run-all.sh [--quiet]
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
rc=0
echo "== no-force-strings =="; bash "$ROOT/os/tests/no-force-strings.test.sh" || rc=1
echo "== no-literal-config =="; bash "$ROOT/os/tests/no-literal-config.test.sh" || rc=1
echo "== os-config-parity =="; bash "$ROOT/os/tests/os-config-parity.test.sh" || rc=1
echo "== ops suites ==";       bash "$ROOT/os/ops/run-tests.sh" "$@" || rc=1
echo "== linux-smoke ==";      bash "$ROOT/os/tests/linux-smoke.test.sh" || rc=1
[ "$rc" -eq 0 ] && echo "os run-all: PASS" || echo "os run-all: FAIL"
exit "$rc"
