#!/usr/bin/env bash
# Is a PR's check rollup ACTUALLY green enough to merge?
#
# 2026-08-25: pr-shepherd squash-merged client-repo#99 whose entire CI run
# was CANCELLED and had never once passed. The merged code then broke that
# repo's CI.
#
# Its gate was two negative tests and no positive one:
#
#   pending = checks with conclusion == "" AND status != COMPLETED
#   failed  = checks with conclusion == "FAILURE"
#   merge if pending == 0 and failed is empty
#
# A CANCELLED check has conclusion=CANCELLED and status=COMPLETED, so it is
# neither pending nor FAILURE — invisible to both. TIMED_OUT, STALE,
# ACTION_REQUIRED and STARTUP_FAILURE slip through identically.
#
# "Nothing is failing" is NOT "something passed". A PR with zero completed
# checks satisfies both negative tests perfectly.

# check_state <conclusion> <status>  -> pending | pass | neutral | block
#
# GitHub reports conclusion="" while a check is still running. A check that is
# COMPLETED with no conclusion is NOT treated as done — an unknown terminal
# state blocks rather than passes.
check_state() {
  local conc status
  conc=$(printf '%s' "${1-}" | tr '[:lower:]' '[:upper:]')
  status=$(printf '%s' "${2-}" | tr '[:lower:]' '[:upper:]')

  if [ -z "$conc" ]; then
    # No conclusion yet. Still running => pending. COMPLETED-but-blank is a
    # state we do not understand, so it blocks.
    case "$status" in
      COMPLETED) echo "block" ;;
      *)         echo "pending" ;;
    esac
    return 0
  fi

  case "$conc" in
    SUCCESS)          echo "pass" ;;
    # Legitimately not run (path filters, `if:` conditions). Neither green nor
    # red — must not block, must not count as evidence of a passing build.
    SKIPPED|NEUTRAL)  echo "neutral" ;;
    # Everything else blocks, INCLUDING states that are not failures:
    # CANCELLED, TIMED_OUT, STALE, ACTION_REQUIRED, STARTUP_FAILURE and any
    # future conclusion GitHub adds. Defaulting unknown to "block" is the
    # whole point — the bug was an unknown state defaulting to mergeable.
    *)                echo "block" ;;
  esac
}

# merge_verdict  — reads "<conclusion>|<status>" lines on stdin
#
# The delimiter is "|", NOT a tab: tab is IFS *whitespace*, and `read` collapses
# leading whitespace, so a pending check's EMPTY conclusion would shift the
# status into $conc and be classified as an unknown terminal state. Caught by
# the "one still running is pending" test.
#   -> pending    at least one check still running
#      blocked    at least one check in a non-passing terminal state
#      no-signal  nothing is blocking, but nothing actually PASSED either
#      green      every check terminal, none blocking, at least one SUCCESS
#
# Callers must merge ONLY on "green". "no-signal" is deliberately distinct so
# the reason can be reported: it is the exact shape of a PR whose checks were
# all cancelled, and of a PR with no checks at all.
merge_verdict() {
  local conc status st any_pending=0 any_block=0 any_pass=0 seen=0
  while IFS='|' read -r conc status; do
    [ -n "$conc$status" ] || continue
    seen=1
    st=$(check_state "$conc" "$status")
    case "$st" in
      pending) any_pending=1 ;;
      block)   any_block=1 ;;
      pass)    any_pass=1 ;;
    esac
  done
  [ "$seen" = 1 ] || { echo "no-signal"; return 0; }
  [ "$any_pending" = 1 ] && { echo "pending"; return 0; }
  [ "$any_block" = 1 ]   && { echo "blocked"; return 0; }
  [ "$any_pass" = 1 ]    && { echo "green";   return 0; }
  echo "no-signal"
}
