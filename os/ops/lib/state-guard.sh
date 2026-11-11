#!/usr/bin/env bash
# state-guard.sh — snapshot state, validate it after the risky step, roll back if
# the step produced something malformed.
#
# Ported (as a pattern, not code — that repo has no LICENSE file) from
# Auto-Company's auto-loop.sh:245-288, where a single markdown file is the only
# state carried between otherwise-stateless agent cycles. The part worth taking
# is not the baton, it is the DISCIPLINE around it: back up before the cycle,
# run a STRUCTURAL check after, and restore on any failure signal — a timeout
# with no progress, a non-zero exit, or output that fails the schema check.
#
# Our dream-*.sh cycles and self-heal watchers currently trust that the previous
# cycle's state file is intact and well-formed, with no check and no rollback.
#
# Source, don't execute. Pairs with lib/atomic.sh.
#
#   snapshot_state <path>
#   validate_state <path> <validator-fn>     validator gets the path, exits 0/non-0
#   restore_state  <path>
#   state_changed_since_snapshot <path>      0 = changed

snapshot_state() {
  _ss_path="${1:?snapshot_state needs a path}"
  [ -f "$_ss_path" ] || return 0          # nothing to snapshot is not an error
  cp -p "$_ss_path" "$_ss_path.bak" 2>/dev/null || return 1
  return 0
}

validate_state() {
  _vs_path="${1:?validate_state needs a path}"
  _vs_fn="${2:?validate_state needs a validator function name}"
  if [ ! -f "$_vs_path" ]; then
    echo "validate_state: $_vs_path is MISSING after the step that should have written it" >&2
    return 1
  fi
  if [ ! -s "$_vs_path" ]; then
    echo "validate_state: $_vs_path is EMPTY — treating as failure, not as 'no data'" >&2
    return 1
  fi
  if ! "$_vs_fn" "$_vs_path"; then
    echo "validate_state: $_vs_path failed $_vs_fn" >&2
    return 1
  fi
  return 0
}

restore_state() {
  _rs_path="${1:?restore_state needs a path}"
  if [ ! -f "$_rs_path.bak" ]; then
    echo "restore_state: no snapshot at $_rs_path.bak — cannot roll back" >&2
    return 1
  fi
  mv -f "$_rs_path.bak" "$_rs_path" || return 1
  return 0
}

# A cycle that timed out but still produced VALID, CHANGED state has made real
# progress and must not be rolled back. auto-loop.sh:274-288 is the precedent.
state_changed_since_snapshot() {
  _sc_path="${1:?state_changed_since_snapshot needs a path}"
  [ -f "$_sc_path" ] || return 1
  [ -f "$_sc_path.bak" ] || return 0      # no snapshot -> everything is new
  cmp -s "$_sc_path" "$_sc_path.bak" && return 1 || return 0
}
