#!/usr/bin/env bash
# Whisky AI OS — run every test suite in the repo, across all 5 classes.
#
# WHY THIS EXISTS: the suites were written and then nothing ever ran them. The
# foundation's own CI was removed in #104 (Actions billing blocked since
# ~2026-07-20), os-selftest checks the OS's *runtime* health rather than this
# repo's tests, and no launchd job invoked them. By 2026-08-18 two suites had
# been red for weeks with nobody notified:
#   • postmortem      8/14 failing — the fake HOME the suite uses for state
#                     isolation could never satisfy the TCC canary
#   • detector-run    1/7 failing  — asserted a detector deliberately retired in #48
# Neither was a product defect. Both were invisible purely because no runner
# existed. A test nobody runs is worth less than no test: it reads as coverage.
#
# 2026-09-04 — THE SAME DEFECT, ONE LEVEL UP. This runner globbed exactly one
# path, `lib/__tests__/*.test.sh`, so it ran 25 of the repo's 37 suites and
# reported "all passing". The other 12 were run by nothing — not here, not in
# CI (the `Ops tests` job invokes only this script):
#     ops/tests/*.test.sh              2 suites
#     ops/tests/*.test.mjs             3 suites
#     ops/dashboard/__tests__/*.mjs    1 suite   <- had been RED, 34 != 15
#     ops/accountant/tests/test_*.py   6 suites, 309 tests
# The dashboard suite asserted a hardcoded subsystem count that grew from 15 to
# 34 while nobody re-ran it. A runner that finds only what it was first written
# to find is a never-run gate wearing a green badge.
#
# So discovery is now a TABLE of classes, and — the load-bearing part — a class
# that discovers ZERO suites is a FAILURE, not a quiet skip. Renaming a
# directory or moving a suite can no longer silently retire a whole tier.
#
# Usage:
#   ops/run-tests.sh            # run every class, print a summary
#   ops/run-tests.sh --quiet    # only print failures + the summary
# Exit: non-zero if any suite fails OR any class discovers nothing.
set -uo pipefail
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"   # absolute: the workers re-run this script after the cd below
cd "$(dirname "$0")" || exit 1

QUIET=0
# A suite slower than this prints a `slow` line even in --quiet mode, as it finishes (the CI job once ran 25 min with no output to say where).
SLOW_S="${RUN_TESTS_SLOW_S:-20}"
# OS-SUITES-PARALLEL-1: independent suites run RUN_TESTS_JOBS at a time (default 2); the suites named in tests-serial.list (they share a host lock, a
# process table or a port) run ONE at a time AFTER the parallel set, so they never overlap anything. A missing tests-serial.list runs EVERYTHING serially.
JOBS="${RUN_TESTS_JOBS:-2}"
slow_names=()
[ "${1:-}" = "--quiet" ] && QUIET=1

# run_one <runner> <path>: 0 = pass. Output on stdout.
run_one() {
  case "$1" in
    bash) bash "$2" 2>&1 ;;
    node) node "$2" 2>&1 ;;
    # Run as a package module from the class root so intra-package imports
    # resolve as they do for the app: `python3 -m unittest tests.<name>`.
    pyunit) ( cd "$(dirname "$(dirname "$2")")" \
                && python3 -m unittest "tests.$(basename "$2" .py)" 2>&1 ) ;;
    *) echo "unknown runner: $1"; return 2 ;;
  esac
}

# worker mode (called through xargs, or directly for the serial set): run ONE suite, write <prefix>.out / .rc / .secs, print its `slow` line at once.
if [ "${1:-}" = "--worker" ]; then
  runner="$2"; path="$3"; prefix="$4"; wname="$5"
  w0=$SECONDS
  run_one "$runner" "$path" > "$prefix.out" 2>&1; echo "$?" > "$prefix.rc"
  wdt=$(( SECONDS - w0 )); echo "$wdt" > "$prefix.secs"
  [ "$wdt" -lt "$SLOW_S" ] || printf '  slow  %s %ss\n' "$wname" "$wdt"
  exit 0
fi

# CLASSES — "label|glob|runner". A repo's test stack is not one shape: this one
# is bash suites, node ESM suites and a python unittest package. bash 3.2 has no
# associative arrays, so this is a plain newline-separated list.
#
# A suite in a NEW location means a new line here. Discovery is DECLARED, not
# inferred, so a class can never be half-discovered — and an empty class is loud.
CLASSES='
ops-lib|lib/__tests__/*.test.sh|bash
ops-shell|tests/*.test.sh|bash
ops-node|tests/*.test.mjs|node
remediation|../tests/remediation/*_test.sh|bash
'

suites=0
failed=0
skipped=0
empty_classes=()
failed_names=()

WORK="$(mktemp -d "${TMPDIR:-/tmp}/run-tests.XXXXXX")"; trap 'rm -rf "$WORK"' EXIT
plan_names=(); plan_runners=(); plan_paths=(); plan_serial=()

# PLAN: discover every suite in declared order (SKIP lines and EMPTY classes are decided here, exactly as before).
for line in $CLASSES; do
  [ -n "$line" ] || continue
  label="${line%%|*}"; rest="${line#*|}"
  glob="${rest%%|*}"; runner="${rest##*|}"

  found=0
  for t in $glob; do
    [ -f "$t" ] || continue
    found=$(( found + 1 ))
    suites=$(( suites + 1 ))
    name="$label/$(basename "$t" | sed -e 's/\.test\.sh$//' -e 's/\.test\.mjs$//' -e 's/^test_//' -e 's/\.py$//')"
    # Declared-pending suites (need Task 3 content): loud SKIP, counted, never silent.
    if grep -qE "^${name}([[:space:]]|\$)" tests-pending.list 2>/dev/null; then
      skipped=$(( skipped + 1 )); printf '  SKIP  %s (pending Task 3 content, see tests-pending.list)\n' "$name"; continue
    fi
    ser=0
    # serial unless the list exists and does NOT name the suite (fail-safe: no list = everything serial)
    if [ ! -f tests-serial.list ] || grep -qE "^${name}([[:space:]]|\$)" tests-serial.list 2>/dev/null; then ser=1; fi
    plan_names+=("$name"); plan_runners+=("$runner"); plan_paths+=("$t"); plan_serial+=("$ser")
  done

  # A class that matched nothing is a FAILURE — the original bug was a runner
  # reporting green over suites it never looked for.
  if [ "$found" -eq 0 ]; then
    empty_classes+=("$label ($glob)")
    printf '  EMPTY %s — glob matched no suite\n' "$label"
  fi
done

# RUN: the parallel set first (JOBS at a time), then the serial set one by one.
n=${#plan_names[@]}
if [ "$n" -gt 0 ]; then
  par_args=()
  i=0
  while [ "$i" -lt "$n" ]; do
    [ "${plan_serial[$i]}" = 1 ] || par_args+=("${plan_runners[$i]}" "${plan_paths[$i]}" "$WORK/$i" "${plan_names[$i]}")
    i=$(( i + 1 ))
  done
  if [ "${#par_args[@]}" -gt 0 ]; then
    printf '%s\0' ${par_args[@]+"${par_args[@]}"} | RUN_TESTS_SLOW_S="$SLOW_S" xargs -0 -n4 -P "$JOBS" bash "$SELF" --worker
  fi
  i=0
  while [ "$i" -lt "$n" ]; do
    [ "${plan_serial[$i]}" = 1 ] && RUN_TESTS_SLOW_S="$SLOW_S" bash "$SELF" --worker "${plan_runners[$i]}" "${plan_paths[$i]}" "$WORK/$i" "${plan_names[$i]}"
    i=$(( i + 1 ))
  done
fi

# REPORT in the declared order (deterministic, whatever finished first). A suite with no .rc (its worker died) is a FAILURE.
i=0
while [ "$i" -lt "$n" ]; do
  name="${plan_names[$i]}"
  rc="$(cat "$WORK/$i.rc" 2>/dev/null || echo 99)"
  dt="$(cat "$WORK/$i.secs" 2>/dev/null || echo 0)"
  if [ "$rc" = 0 ]; then
    [ "$QUIET" = "1" ] || printf '  ok    %s\n' "$name"
  else
    failed=$(( failed + 1 ))
    failed_names+=("$name")
    printf '  FAIL  %s\n' "$name"
    sed 's/^/          /' "$WORK/$i.out" 2>/dev/null \
      | grep -E 'FAIL|AssertionError|Traceback|passed|Error' | head -12
  fi
  if [ "$dt" -ge "$SLOW_S" ]; then
    slow_names+=("${dt}s $name")
  fi
  i=$(( i + 1 ))
done

echo
if [ "${#slow_names[@]}" -gt 0 ]; then
  echo "ops tests: slowest suites (>= ${SLOW_S}s):"
  printf '%s\n' ${slow_names[@]+"${slow_names[@]}"} | sort -rn | head -5 | sed 's/^/             /'
fi
# Finding NOTHING is a failure, not a pass. The installed runtime copy at
# ~/.claude/scripts/ has no lib/__tests__/ (install.sh copies lib/*.sh, *.py,
# *.json and *.mjs — not the test dir), so running it there printed
# "0 suite(s), all passing" and exited 0. A runner that reports green because it
# could not find anything to run is the same fail-open defect this script exists
# to catch. Run it from the repo: ops/run-tests.sh
if [ "$suites" -eq 0 ]; then
  echo "ops tests: NO SUITES FOUND under $(pwd) — nothing was verified."
  echo "           This is a FAILURE, not a pass. Run this from the foundation repo,"
  echo "           not from the installed runtime copy in ~/.claude/scripts/."
  exit 2
fi

if [ "${#empty_classes[@]}" -gt 0 ]; then
  echo "ops tests: ${suites} suite(s) ran, but ${#empty_classes[@]} CLASS(ES) DISCOVERED NOTHING:"
  # Guarded expansion: a bare "${arr[@]}" on an empty array ABORTS under set -u
  # on bash 3.2 (macOS). Unreachable here — the count check above gates it — but
  # ops/lib/__tests__/empty-array-guard.test.sh forbids the shape outright, and
  # it is right to: this is how deploy-drift died silently for 32h.
  for c in ${empty_classes[@]+"${empty_classes[@]}"}; do echo "             - $c"; done
  echo "           A class matching no suite is a retired tier nobody noticed."
  echo "           Fix the glob or delete the class line — never ignore this."
  exit 2
fi

if [ "$failed" -eq 0 ]; then
  echo "ops tests: ${suites} suite(s) across 4 classes, all passing (${skipped} declared-pending SKIPPED)"
else
  echo "ops tests: ${suites} suite(s), ${failed} FAILING — ${failed_names[*]}"
fi
[ "$failed" -eq 0 ]
