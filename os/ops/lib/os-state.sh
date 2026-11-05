# shellcheck shell=bash
# ops/lib/os-state.sh — uniform OS subsystem status writer.
# Source this, then call:  write_status NAME OK "summary" '{"k":"v"}'
#   NAME   : kebab id → ~/.whisky-os-state/<NAME>-status.json
#   OK     : "true" | "false" | "warn"
#   summary: one-line human string
#   detail : OPTIONAL compact JSON object string (default {})
# Atomic (temp file + mv). Never throws — a status write must never fail a run.
# shellcheck source=os-config.sh
command -v os_config_load >/dev/null 2>&1 || . "$(dirname "${BASH_SOURCE[0]}")/os-config.sh" 2>/dev/null || true
[ -n "${OS_ORG:-}" ] || ! command -v os_config_load >/dev/null 2>&1 || os_config_load
write_status() {
  local name="$1" ok="$2" summary="$3" detail="${4:-}"
  # NOTE: do NOT default with `${4:-{}}` — bash parses the `}` inside the default
  # as the expansion close, leaving a literal trailing `}` (turns {"n":3} into
  # {"n":3}}). Default explicitly instead.
  [ -n "$detail" ] || detail='{}'
  local dir="$HOME/.whisky-os-state"; mkdir -p "$dir" 2>/dev/null || return 0
  local out="$dir/${name}-status.json" tmp
  tmp="$(mktemp "${dir}/.${name}.XXXXXX")" || return 0
  local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  # python3 emits valid JSON (safe quoting/escaping of arbitrary summary/detail).
  OK="$ok" SUMMARY="$summary" DETAIL="$detail" TS="$ts" python3 - "$tmp" <<'PY' 2>/dev/null || { rm -f "$tmp"; return 0; }
import json, os, sys
try:
    detail = json.loads(os.environ.get("DETAIL") or "{}")
except Exception:
    detail = {"raw": os.environ.get("DETAIL")}
json.dump({
    "ok": os.environ["OK"],
    "summary": os.environ["SUMMARY"],
    "detail": detail,
    "checked_at": os.environ["TS"],
}, open(sys.argv[1], "w"), indent=2)
PY
  mv -f "$tmp" "$out" 2>/dev/null || rm -f "$tmp"
}

# ---------------------------------------------------------------------------
# The state bus (Live Companion OS, Phase 1).
#
# Two append-only NDJSON streams in ~/.whisky-os-state/ that Zero (and the
# dashboard) read. Both are fail-open: a bus write must NEVER fail a run.
#
#   emit_event NAME SEVERITY SUMMARY [DETAIL_JSON]
#     → one line appended to events.ndjson — the live "SEE" stream of every
#       notable OS event. SEVERITY ∈ {critical,high,medium,low,info}.
#
#   emit_inbox SUMMARY [DETAIL_JSON]
#     → one line appended to zero-inbox.ndjson — the high-priority subset the
#       OS wants SPOKEN to Ahmad now. Zero drains + speaks it (Phase 3).
#
# events.ndjson rotates daily: the first write of a new UTC day renames the
# prior file to events-<YYYY-MM-DD>.ndjson before appending.
# ---------------------------------------------------------------------------

# Append one compact JSON line to a stream file, atomically-enough for NDJSON
# (a single small write). Builds the JSON via python3 for safe escaping.
_bus_append() {
  local file="$1"; shift
  local payload_py="$1"  # python dict literal builder reads env vars
  local dir="$HOME/.whisky-os-state"; mkdir -p "$dir" 2>/dev/null || return 0
  local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local line
  line="$(TS="$ts" python3 - <<PY 2>/dev/null
import json, os
$payload_py
print(json.dumps(obj, separators=(",", ":"), ensure_ascii=False))
PY
)" || return 0
  [ -n "$line" ] || return 0
  printf '%s\n' "$line" >> "$dir/$file" 2>/dev/null || return 0
}

# Rotate events.ndjson when the UTC day changes (cheap day-marker compare).
_bus_rotate_events() {
  local dir="$HOME/.whisky-os-state"; mkdir -p "$dir" 2>/dev/null || return 0
  local today marker prev
  today="$(date -u +%F)"
  marker="$dir/.events-day"
  prev="$(cat "$marker" 2>/dev/null || true)"
  if [ -n "$prev" ] && [ "$prev" != "$today" ] && [ -s "$dir/events.ndjson" ]; then
    mv -f "$dir/events.ndjson" "$dir/events-${prev}.ndjson" 2>/dev/null || true
    # prune rotated logs older than 14 days
    find "$dir" -name 'events-*.ndjson' -type f -mtime +14 -delete 2>/dev/null || true
  fi
  printf '%s' "$today" > "$marker" 2>/dev/null || true
}

# emit_event NAME SEVERITY SUMMARY [DETAIL_JSON]
emit_event() {
  local name="$1" sev="$2" summary="$3" detail="${4:-}"
  [ -n "$detail" ] || detail='{}'
  case "$sev" in critical|high|medium|low|info) ;; *) sev='info' ;; esac
  _bus_rotate_events
  NAME="$name" SEV="$sev" SUMMARY="$summary" DETAIL="$detail" \
  _bus_append "events.ndjson" '
try:
    detail = json.loads(os.environ.get("DETAIL") or "{}")
except Exception:
    detail = {"raw": os.environ.get("DETAIL")}
obj = {
    "ts": os.environ["TS"],
    "name": os.environ["NAME"],
    "severity": os.environ["SEV"],
    "summary": os.environ["SUMMARY"],
    "detail": detail,
}'
}

# emit_inbox SUMMARY [DETAIL_JSON]   (always also lands in the event stream)
emit_inbox() {
  local summary="$1" detail="${2:-}"
  [ -n "$detail" ] || detail='{}'
  SUMMARY="$summary" DETAIL="$detail" \
  _bus_append "zero-inbox.ndjson" '
try:
    detail = json.loads(os.environ.get("DETAIL") or "{}")
except Exception:
    detail = {"raw": os.environ.get("DETAIL")}
obj = {
    "ts": os.environ["TS"],
    "summary": os.environ["SUMMARY"],
    "detail": detail,
    "spoken": False,
}'
  emit_event "zero-inbox" "high" "$summary" "$detail"
}

# resolve_repo_dir <name> — find a project checkout. The layout lives in ONE place,
# lib/projects-layout.sh (2026-09-25 business-folder layout; legacy paths searched
# last as compat). Sourced here so every script that sources os-state keeps working.
# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/projects-layout.sh"

# repo_commits_behind <dir> — how many commits the local checkout trails origin's
# default branch. Echoes an integer (0 when fresh, unknown, or not a git repo).
#
# WHY: every scanner in this OS reads a LOCAL checkout. On 2026-08-18
# dream-research reported four Next.js CVEs against mypovonai that had been fixed
# on origin three weeks earlier — the checkout was 2 commits behind, so the scan
# described a tree nobody runs. Vulnerability scanning fixed that properly by
# reading origin (ops/lib/scan-lockfile.sh); CODE scanners legitimately want the
# working tree, but they must still SAY when it is stale, or their findings age
# silently the same way.
#
# Read-only: fetch updates remote-tracking refs, never the working tree. Any
# failure (offline, no origin, detached) reports 0 rather than blocking a scan.
repo_commits_behind() {
  local _rcb_dir="${1:-}" _rcb_def _rcb_n
  [ -n "$_rcb_dir" ] || { printf '0\n'; return 0; }
  { [ -d "$_rcb_dir/.git" ] || [ -f "$_rcb_dir/.git" ]; } || { printf '0\n'; return 0; }
  git -C "$_rcb_dir" fetch origin -q 2>/dev/null
  _rcb_def="$(git -C "$_rcb_dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')"
  if [ -z "$_rcb_def" ]; then
    for _rcb_n in main master; do
      git -C "$_rcb_dir" rev-parse --verify --quiet "origin/$_rcb_n" >/dev/null 2>&1 && { _rcb_def="$_rcb_n"; break; }
    done
  fi
  [ -n "$_rcb_def" ] || { printf '0\n'; return 0; }
  _rcb_n="$(git -C "$_rcb_dir" rev-list --count "HEAD..origin/$_rcb_def" 2>/dev/null)"
  case "$_rcb_n" in (''|*[!0-9]*) _rcb_n=0 ;; esac
  printf '%s\n' "$_rcb_n"
}

# require_projects_access — TCC canary (2026-07-12). launchd-context bash can be
# DENIED ~/Desktop by macOS TCC: every repo then looks missing and scanners
# report garbage drift (docs-scan telegrammed 15 phantom items). Call this
# before any scan that reads $OS_PROJECTS_DIR; returns 1 (and logs + status)
# when the environment is blind — callers must ABORT, never report findings.
require_projects_access() {
  local canary="$OS_PROJECTS_DIR/$OS_ORG/internal-projects/ebda-store/.git"
  if [ -r "$canary" ] && [ -n "$(ls "$OS_PROJECTS_DIR" 2>/dev/null)" ]; then
    return 0
  fi
  echo "[os-state] BLIND: cannot read $OS_PROJECTS_DIR (macOS TCC denies this launchd context — grant Full Disk Access to bash, see feedback memory). Aborting scan, NOT reporting drift." >&2
  command -v write_status >/dev/null 2>&1 && write_status "${OS_JOB_NAME:-scan}" "warn" "TCC-blind: cannot read $OS_PROJECTS_DIR — scan aborted (no findings reported)" '{"tcc":true}'
  return 1
}

# Loud variant for jobs whose NON-RUN is itself an incident (backups, memory
# pipeline, brain export): blindness telegrams a P1 instead of aborting quietly.
require_projects_access_critical() {
  if require_projects_access; then return 0; fi
  local here; here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  [ -x "$here/notify.sh" ] && "$here/notify.sh" "🚨 ${OS_JOB_NAME:-job} BLIND — did NOT run" \
    "macOS TCC denies ~/Desktop to this launchd context. The job aborted safely but its work is NOT happening. Fix: System Settings → Privacy & Security → Full Disk Access → add /bin/bash." >/dev/null 2>&1
  return 1
}

# ── wall clock ────────────────────────────────────────────────────────────────
# _ut <seconds> <cmd...> — run a command under a hard wall clock, portably.
#
# Every scheduled job that shells out to the network (umbra, ssh, gh, curl) can
# block forever on a half-open socket or a wedged guest. Two such hangs were
# found on 2026-08-02: ci-runner-guard wedged 4h07m on a stale-port `umbra
# shell`, and gate-guard wedged 24 DAYS. hung-job-guard.sh is the backstop, but
# a job should bound its own calls rather than wait to be reaped.
#
# Defined here (not per-script) so every job that sources this lib gets it.
# ci-runner-guard.sh keeps its own identical copy — it predates this one and is
# defined after the source, so it simply wins; ops/tests/ci-runner-guard.test.sh
# fails if the two copies drift apart.
#
# ONE supervisor on every host, deliberately (2026-09-15). It used to prefer
# gtimeout/timeout, but launchd's PATH has neither, so production only ever ran
# the hand-rolled fallback, and it had two holes:
#   - STDIN. bash 3.2 without job control gives a backgrounded `"$@" &` /dev/null
#     as stdin, so `printf script | _ut N umbra shell m -- bash` ran an EMPTY
#     script. `<&0` is an explicit redirection, which bash honours.
#   - DESCENDANTS. Killing only the direct child leaves any grandchild that still
#     holds stdout, and `$(_ut …)` waits for EOF on that pipe forever. gtimeout
#     has the same hole for a child in a new session. So snapshot the whole tree
#     BEFORE killing (after the parent dies its children reparent and are lost).
if ! declare -F _ut >/dev/null 2>&1; then
_ut() {
  local secs="$1"; shift
  "$@" <&0 & local p=$! t=0 k
  while kill -0 "$p" 2>/dev/null; do
    if [ "$t" -ge $((secs * 5)) ]; then
      k="$(_ut_tree "$p") $p"
      # shellcheck disable=SC2086  # $k is a pid list, split on purpose
      { kill -TERM $k; sleep 2; kill -KILL $k; } 2>/dev/null
      return 124
    fi
    sleep 0.2; t=$((t+1))
  done
  wait "$p"
}
fi
if ! declare -F _ut_tree >/dev/null 2>&1; then
_ut_tree() {
  # _ut_tree <pid> — every descendant pid, deepest first.
  local c
  for c in $(pgrep -P "$1" 2>/dev/null); do _ut_tree "$c"; echo "$c"; done
}
fi

# Default wall clocks, overridable per job before sourcing.
: "${OS_UT_FAST:=30}"    # single API/HTTP call
: "${OS_UT_SLOW:=120}"   # guest shell, clone, multi-step remote work

# ── paused services ───────────────────────────────────────────────────────────
# service_paused <name...> — true if any given name has a pause marker.
#
# A service can be deliberately parked to stop cloud spend (ops/wbs-power.sh).
# Every watcher that probes it must check this, or the pause turns into a nightly
# Telegram alert about a service that is off ON PURPOSE. An alert everyone learns
# to ignore is worse than no alert, and it trains people to dismiss the real one.
#
# Deliberately a shared helper, not a per-watcher check: the marker is the single
# source of truth, and a watcher that forgets to consult it is exactly how the
# noise comes back.
service_paused() {
  local n
  for n in "$@"; do
    [ -f "$HOME/.whisky-os-state/${n}-paused" ] && return 0
  done
  return 1
}