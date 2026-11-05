#!/usr/bin/env bash
# sandbox.sh — run an unattended agent command under an OS-enforced filesystem
# allow-list on Linux.
#
# WHY: dream-fix.sh, dream-act.sh, self-heal.sh and remediate.sh execute
# agent-authored shell on the umbra Linux guests with the full privileges of the
# account that launched them. Everything between that shell and the filesystem is
# prompt discipline. Landlock is an independent syscall family — it needs no root,
# no user namespaces and no bwrap — so it is the one rung available on those guests.
#
# Backed by vendor/landlock-run (BSD-3-Clause, from deepseek-harness; see
# vendor/landlock-run/VENDOR-PROVENANCE.md). Verified in a Linux container on
# 2026-09-04: --probe reports "landlock: fully enforced", a write inside the --rw
# path succeeds, a write outside is DENIED and the file confirmed absent.
#
# TWO THINGS THE VERIFICATION TAUGHT, both of which break naive wrappers:
#   1. `--ro /` does NOT let a command write /dev/null. Almost every real command
#      redirects somewhere, so /dev must be granted rw or things fail in ways that
#      look like the command is broken rather than confined. sandbox_run does this.
#   2. Landlock is Linux-only. On macOS there is nothing to enforce, so this REFUSES
#      to run rather than silently running unconfined — a sandbox that quietly does
#      nothing on half your fleet is worse than none. Override deliberately with
#      SANDBOX_ALLOW_UNCONFINED=1, which logs that it did so.
#
# Source, don't execute:
#   sandbox_available            0 if landlock-run exists AND the kernel enforces
#   sandbox_run <rw-dir> -- cmd  run cmd with read-only / and write access to <rw-dir>

: "${LANDLOCK_BIN:=${HOME}/.claude/scripts/bin/landlock-run}"

sandbox_available() {
  [ "$(uname -s)" = "Linux" ] || return 1
  [ -x "$LANDLOCK_BIN" ] || return 1
  "$LANDLOCK_BIN" --probe >/dev/null 2>&1
}

sandbox_run() {
  _sb_rw="${1:?sandbox_run needs a writable directory}"; shift
  [ "${1:-}" = "--" ] && shift
  [ $# -gt 0 ] || { echo "sandbox_run: no command given" >&2; return 64; }

  if sandbox_available; then
    # /dev rw is not a loophole worth agonising over — it is the difference between
    # a working confinement and one nobody can use. The point of the allow-list is
    # the repo tree and the home directory, not /dev/null.
    "$LANDLOCK_BIN" --ro / --rw "$_sb_rw" --rw /dev --rw /tmp -- "$@"
    return $?
  fi

  if [ "${SANDBOX_ALLOW_UNCONFINED:-0}" = "1" ]; then
    echo "sandbox_run: UNCONFINED (SANDBOX_ALLOW_UNCONFINED=1) — $(uname -s), landlock-run $([ -x "$LANDLOCK_BIN" ] && echo present || echo absent)" >&2
    "$@"
    return $?
  fi

  echo "sandbox_run: REFUSING to run unconfined." >&2
  echo "  host: $(uname -s); landlock-run: $([ -x "$LANDLOCK_BIN" ] && echo "$LANDLOCK_BIN" || echo 'not installed')" >&2
  echo "  Landlock is Linux-only. On macOS, or on a guest without the binary, this" >&2
  echo "  helper does NOT silently fall back to running the command unrestricted —" >&2
  echo "  that would be a sandbox that quietly does nothing on half the fleet." >&2
  echo "  Build it:  ops/build-landlock.sh   ·  Override:  SANDBOX_ALLOW_UNCONFINED=1" >&2
  return 70
}
