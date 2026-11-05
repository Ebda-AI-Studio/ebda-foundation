# shellcheck shell=bash
# ops/lib/single-instance.sh - one run of a sweep/watch at a time (plan 2026-10-26 S0, incident I12).
#
# 2026-10-26: about 7 workspace-hygiene.sh runs (hourly launchd + one per `gh pr merge` hook) ran at once and hung
# du/df. A mkdir lock is atomic on macOS and bash 3.2 safe. State: ${OS_LOCK_DIR:-~/.whisky-os-state/locks}/<name>/pid
#   si_acquire <name>        0 = acquired (pid file written). 1 = a LIVE run holds it (holder pid on stderr).
#   si_release <name>        remove the lock, only if this shell owns it.
#   single_instance <name>   acquire or print "already running" and exit 0; releases on EXIT (callers that set their
#                            own EXIT trap must call si_release themselves).
#   single_instance_wait <name> <secs>   same, but waits up to <secs> for the holder first (a teardown must not be dropped).
# A lock whose pid is dead is reclaimed (rename-then-rmdir so two reclaimers cannot both win). A lock with no pid
# file yet is treated as held while it is younger than 60 s (the winner is between mkdir and writing its pid).
_si_path() { printf '%s/%s' "${OS_LOCK_DIR:-$HOME/.whisky-os-state/locks}" "$1"; }

si_acquire() {
  local d pid; d="$(_si_path "$1")"
  mkdir -p "$(dirname "$d")" 2>/dev/null || return 1
  local try
  for try in 1 2 3; do
    if mkdir "$d" 2>/dev/null; then printf '%s\n' "$$" > "$d/pid"; return 0; fi
    pid="$(cat "$d/pid" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then echo "$pid" >&2; return 1; fi
    if [ -z "$pid" ] && [ -d "$d" ] && [ -z "$(find "$d" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then echo "starting" >&2; return 1; fi
    # dead holder (or a pid-less lock older than a minute): reclaim atomically
    if mv "$d" "$d.dead.$$" 2>/dev/null; then rm -rf "$d.dead.$$"; fi
  done
  return 1
}

si_release() {
  local d; d="$(_si_path "$1")"
  [ "$(cat "$d/pid" 2>/dev/null)" = "$$" ] && rm -rf "$d"
  return 0
}

single_instance() {
  local name="$1" holder
  if ! holder="$(si_acquire "$name" 2>&1)"; then
    echo "$name: already running (pid ${holder:-?}), exiting"; exit 0
  fi
  # shellcheck disable=SC2064  # expand $name now
  trap "si_release '$name'" EXIT
}

single_instance_wait() {
  local name="$1" secs="${2:-60}" t=0 holder
  until holder="$(si_acquire "$name" 2>&1)"; do
    [ "$t" -ge "$secs" ] && { echo "$name: still held by pid ${holder:-?} after ${secs}s, giving up"; exit 0; }
    sleep 1; t=$((t + 1))
  done
  # shellcheck disable=SC2064
  trap "si_release '$name'" EXIT
}
