#!/usr/bin/env bash
# Ebda AI OS - loop-watchdog.sh   (ruling LOOP-WATCH-1: the controller's loop-health wake-up)
#
# Wakes the controller BY EXITING when the loop is unhealthy. Run it ONLY as a harness-tracked background task
# (Bash run_in_background); NEVER nohup / & / disown: the harness wakes the session on the exit of a task it tracks, and an exit of
# a detached process wakes nobody (2026-11-11: alert-wait relaunched with nohup, 21 P1 alerts missed, 2 h stall, 0 merges).
# Re-run it after every wake. Checks every --interval seconds (default 120), per watched repo:
#   - main CI red                                  (newest completed run of workflow CI on main is failure/cancelled/timed_out)
#   - drain dead                                   (no <OS_LAUNCHD_PREFIX>.drain-* launchd job loaded AND no ops/drain*.sh process)
#   - alert listener dead                          (no alert-wait.sh process)
#   - a ROOT checkout under $OS_PROJECTS_DIR with core.bare=true (silently breaks merge-gate: 2026-10-25, 2026-11-11)
#   - no merge for --stall-min (40) min while drain-ELIGIBLE PRs wait (lib/drain_eligible.py: ai-review-passed, not hold, not draft, checks not failed, mergeable)
#
#   loop-watchdog.sh [--interval SEC] [--stall-min MIN] [--once] [--ack-file FILE]
#     --once       check once: exit 0 + report when something new is wrong, 1 when healthy or already acked
#     --ack-file   default $OS_STATE_DIR/loop-watchdog.ack
# Ack: the report prints the line that silences those reason kinds (echo "<sig>" > ack file). A known issue then does not wake again;
# the ack clears itself as soon as the loop is healthy, so the next problem of the same kind wakes you.
# Repos: $OS_LOOP_REPOS (space-separated owner/name), else every commitRepo of config/prod-watch.json + $OS_REPO_SLUG.
# Identity (orgs, launchd prefix, state dir) comes from lib/os-config.sh; nothing here names an org or repo.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/os-config.sh
. "$HERE/lib/os-config.sh" 2>/dev/null && os_config_load 2>/dev/null || true
INTERVAL=120; STALL_MIN=40; ONCE=0; ACK="${OS_STATE_DIR:-$HOME/.whisky-os-state}/loop-watchdog.ack"
while [ $# -gt 0 ]; do
  case "$1" in
    --interval) shift; INTERVAL="${1:?}" ;;
    --stall-min) shift; STALL_MIN="${1:?}" ;;
    --once) ONCE=1 ;;
    --ack-file) shift; ACK="${1:?}" ;;
    -h|--help) sed -n 2,22p "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "loop-watchdog: unknown option $1" >&2; exit 2 ;;
  esac
  shift
done
[[ "$INTERVAL" =~ ^[0-9]+$ ]] && [ "$INTERVAL" -ge 1 ] || { echo "loop-watchdog: --interval must be a positive integer" >&2; exit 2; }
[[ "$STALL_MIN" =~ ^[0-9]+$ ]] || { echo "loop-watchdog: --stall-min must be an integer" >&2; exit 2; }
PREFIX="${OS_LAUNCHD_PREFIX:?os-config not loaded}"
mkdir -p "$(dirname "$ACK")"

repos() {
  if [ -n "${OS_LOOP_REPOS:-}" ]; then printf '%s\n' $OS_LOOP_REPOS; return; fi
  { python3 -I - "$HERE/../config/prod-watch.json" <<'PY' 2>/dev/null
import json, sys
for p in json.load(open(sys.argv[1])).get("probes", []):
    if p.get("commitRepo"): print(p["commitRepo"])
PY
    echo "${OS_REPO_SLUG:-}"; } | awk 'NF && !s[$0]++'
}

drain_alive() {
  launchctl list 2>/dev/null | awk -v p="$PREFIX.drain-" 'index($3,p)==1 {f=1} END{exit !f}' && return 0
  pgrep -f 'ops/drain[^ ]*\.sh' >/dev/null 2>&1
}

# root checkouts = a directory with a .git DIRECTORY (a worktree has a .git file) at the business-folder layout depths
bare_roots() {
  local d root="${OS_PROJECTS_DIR:?os-config not loaded}"
  for d in "$root"/*/internal-projects/* "$root"/*/clients/*/* "$root"/*/projects/*; do
    [ -d "$d/.git" ] || continue
    [ "$(env -u GIT_DIR -u GIT_WORK_TREE git -C "$d" config --bool core.bare 2>/dev/null)" = true ] && echo "root checkout bare: $d (fix: git -C $d config core.bare false)"
  done
  return 0
}

check() { # prints one reason per line
  local r c last ready age
  while read -r r; do
    [ -n "$r" ] || continue
    c="$(gh run list -R "$r" --branch main --workflow CI --limit 1 --json conclusion,status,headSha --jq '.[0]|"\(.status)/\(.conclusion)/\(.headSha[0:7])"' 2>/dev/null)"
    case "$c" in completed/failure*|completed/cancelled*|completed/timed_out*) echo "main CI red: $r $c" ;; esac
    last="$(gh pr list -R "$r" --state merged --limit 1 --json mergedAt --jq '.[0].mergedAt' 2>/dev/null)"
    # drain-ELIGIBLE only (lib/drain_eligible.py, the drain's own rule): approved, not draft/hold, checks not failed, risky-path reviewed
    ready="$(gh pr list -R "$r" --limit 80 --json number,mergeable,statusCheckRollup,isDraft,labels 2>/dev/null | python3 -I "$HERE/lib/drain_eligible.py" --mode stall 2>/dev/null)"
    if [ -n "$last" ] && [ "${ready:-0}" -gt 0 ] 2>/dev/null; then
      age="$(python3 -I -c 'import sys,time,calendar; print(int(time.time()-calendar.timegm(time.strptime(sys.argv[1],"%Y-%m-%dT%H:%M:%SZ"))))' "$last" 2>/dev/null || echo 0)"
      [ "$age" -gt $((STALL_MIN * 60)) ] && echo "no merge for $((age / 60)) min: $r with $ready drain-eligible PRs"
    fi
  done < <(repos)
  bare_roots
  drain_alive || echo "drain not running (no $PREFIX.drain-* job, no drain process)"
  pgrep -f 'alert-wait\.sh' >/dev/null 2>&1 || echo "alert-wait not running"
}

while :; do
  WHY=(); while IFS= read -r l; do [ -n "$l" ] && WHY+=("$l"); done < <(check)
  # reason KINDS only (first two words), so a changed sha or minute count does not re-wake an acked issue
  SIG="$(printf '%s\n' "${WHY[@]:-}" | awk 'NF {print $1,$2}' | sort -u | tr '\n' '|')"
  if [ ${#WHY[@]} -gt 0 ] && [ "$SIG" != "$(cat "$ACK" 2>/dev/null)" ]; then
    printf 'WATCHDOG %s (ack with: echo "%s" > %s)\n' "$(date -u +%H:%MZ)" "$SIG" "$ACK"
    printf ' - %s\n' ${WHY[@]+"${WHY[@]}"}
    exit 0
  fi
  [ ${#WHY[@]} -eq 0 ] && rm -f "$ACK"
  [ "$ONCE" = 1 ] && exit 1
  sleep "$INTERVAL"
done
