#!/usr/bin/env bash
# RUNNER-ANY-1 (short jobs): jobs that run in well under a minute use `vars.EBDA_ANY_RUNS_ON || vars.EBDA_RUNS_ON` so they can take ANY free runner and never wait behind a
# heavy queue; the long OS layer job keeps `vars.EBDA_RUNS_ON` only. A list, not a glob: a new job must be placed on purpose.
set -uo pipefail
cd "$(dirname "$0")/../../.." || exit 1
_pass=0; _fail=0
pass() { echo "PASS: $1"; _pass=$((_pass+1)); }
fail() { echo "FAIL: $1"; _fail=$((_fail+1)); }
ANY="vars.EBDA_ANY_RUNS_ON || vars.EBDA_RUNS_ON"
runs_on() { # <file> <job> -> the job's runs-on line
  awk -v job="$2" '$0 ~ "^  "job":[[:space:]]*$" {on=1; next} on && /^  [a-z0-9-]+:[[:space:]]*$/ {on=0} on && /runs-on:/ {print; exit}' "$1"
}
for spec in ci.yml:test ci.yml:audit ci.yml:pr-sanity ci.yml:brain ci.yml:hands gitleaks.yml:scan; do
  f=".github/workflows/${spec%%:*}"; j="${spec##*:}"; l="$(runs_on "$f" "$j")"
  case "$l" in *"$ANY"*) pass "${spec}: a short job (measured under 30 s) can take any runner";; *) fail "${spec}: expected the any-runner expression, got: ${l:-<no runs-on found>}";; esac
done
l="$(runs_on .github/workflows/ci.yml os)"
case "$l" in *EBDA_ANY_RUNS_ON*) fail "ci.yml:os (about 12 min) must stay on the light/heavy pool, not the any pool: $l";; *vars.EBDA_RUNS_ON*) pass "ci.yml:os (the long job) stays on vars.EBDA_RUNS_ON";; *) fail "ci.yml:os runs-on not found: ${l:-<none>}";; esac
echo "ci-short-jobs-label: $_pass passed, $_fail failed"; [ "$_fail" = 0 ]
