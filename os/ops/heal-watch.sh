#!/usr/bin/env bash
# heal-watch.sh — the autonomous medic heartbeat (launchd, every 180s).
# Probes each registered service; on DOWN → self-heal.sh. Also writes an
# aggregate $OS_STATE_DIR/heal-status.json for the Ops Command-Center.
set -uo pipefail
# S0 (2026-10-26): --help runs nothing; one run at a time (lib/single-instance.sh)
. "$(dirname "${BASH_SOURCE[0]}")/lib/args.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/args.sh" || exit 2
. "$(dirname "${BASH_SOURCE[0]}")/lib/single-instance.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/single-instance.sh" || exit 2
args_help "${BASH_SOURCE[0]}" "$@"
single_instance heal-watch
export PATH="/opt/homebrew/bin:/usr/bin:/bin:$PATH"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/os-config.sh
. "$HERE/lib/os-config.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-config.sh" 2>/dev/null || true
command -v os_config_load >/dev/null 2>&1 && os_config_load
. "$HERE/lib/heal-registry.sh" 2>/dev/null || true
REG="$(heal_registry_path 2>/dev/null)"
. "$HERE/lib/work-registry.sh" 2>/dev/null || true   # coordination (claim svc: before healing); fail-open
# service_paused lives here. Without this source the pause check below would be a
# "command not found" that fails OPEN — the healer would redeploy a parked service
# while appearing to respect the pause.
. "$HERE/lib/os-state.sh" 2>/dev/null || true
# unreachable-vs-broken classifier + host pre-flight (2026-09-16). This matters
# MORE here than in any read-only monitor: heal-watch hands off to self-heal.sh,
# whose recovery is railway-redeploy. A local network outage that reads as "every
# service is DOWN" would REDEPLOY PRODUCTION services that were never down.
. "$HERE/lib/net-probe.sh" 2>/dev/null || true
# FAIL LOUD if the classifier is absent. Failing OPEN here would restore exactly
# the behaviour this guard exists to stop: treating HTTP 000 as DOWN and
# redeploying production off a local network blip.
command -v net_probe >/dev/null 2>&1 || { echo "heal-watch: FATAL — lib/net-probe.sh not found; refusing to form DOWN verdicts (run ops/install.sh)" >&2; exit 2; }
STATE="$OS_STATE_DIR"; LOG="$STATE/heal.log"; mkdir -p "$STATE"
HAVE_REG=1; [ -n "$REG" ] && [ -f "$REG" ] || { echo "no services configured (heal_services is empty in the local config): skipping probes"; HAVE_REG=0; }
ts(){ date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo now; }
isots(){ date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo ""; }

ids=""; [ "$HAVE_REG" = 1 ] && ids=$(python3 -c "import json;print(' '.join(s['id'] for s in json.load(open('$REG'))['services'] if s.get('enabled')))")
down=0; checked=0; blind=0; svcjson="["
for id in $ids; do
  # A parked product must not be probed OR healed. The recovery action here is
  # railway-redeploy, so a paused service does not just page — the healer puts it
  # back and restores the spend. It fired three redeploys within half an hour of
  # a product being paused on 2026-08-06.
  #
  # Keyed off the RUNTIME marker, deliberately not off the registry's `enabled`
  # flag: heal-registry.json is deployed config, so ops/install.sh overwrites it
  # and silently re-arms the healer mid-pause. Pause state has to live somewhere a
  # redeploy cannot clobber.
  service_paused "${id%%-*}" 2>/dev/null && { echo "  SKIP $id - ${id%%-*} is paused on purpose"; continue; }
  url=$(python3 -c "import json;print([s for s in json.load(open('$REG'))['services'] if s['id']=='$id'][0]['health'])")
  lbl=$(python3 -c "import json;print([s for s in json.load(open('$REG'))['services'] if s['id']=='$id'][0].get('name','$id'))")
  exp=$(python3 -c "import json;print([s for s in json.load(open('$REG'))['services'] if s['id']=='$id'][0].get('expect','200'))")
  NET_PROBE_TIMEOUT=12 net_probe "$url" -o /dev/null
  code="$NET_STATUS"
  # No HTTP response at all? That is a statement about THIS HOST, not about the
  # service. Check the pre-flight ONCE before believing any DOWN verdict; while
  # this Mac is offline, record nothing and hand off nothing (Ruling M-4).
  # self-heal.sh's own §1.5 baseline guard remains the backstop below this.
  if [ "$NET_CLASS" = unreachable ] && ! host_online; then
    if [ "$blind" = 0 ]; then blind=1; net_host_offline_report heal-watch "heal-watch"; fi
    printf '%s [heal-watch] %s unreachable BUT HOST IS OFFLINE — no DOWN verdict, no self-heal\n' "$(ts)" "$id" >>"$LOG"
    continue
  fi
  checked=$((checked+1)); ok=0
  case "$exp" in "<500") { [ "$code" != "000" ] && [ "$code" -lt 500 ] 2>/dev/null; } && ok=1;; *) [ "$code" = "$exp" ] && ok=1;; esac
  [ "$svcjson" != "[" ] && svcjson="$svcjson,"
  svcjson="$svcjson$(python3 -c "import json,sys;print(json.dumps({'id':sys.argv[4],'label':sys.argv[1],'ok':'true' if sys.argv[2]=='1' else 'false','summary':('up ('+sys.argv[3]+')') if sys.argv[2]=='1' else ('DOWN ('+sys.argv[3]+')')}))" "$lbl" "$ok" "$code" "$id")"
  if [ "$ok" = 0 ]; then
    down=$((down+1)); printf '%s [heal-watch] %s DOWN (%s → %s) → self-heal\n' "$(ts)" "$id" "$url" "$code" >>"$LOG"
    # Coordinate: claim svc:<id> so we don't double-heal something the dispatcher or a live
    # session is already on. FAIL-OPEN — if the registry is unavailable or the claim succeeds,
    # heal; only skip when another owner explicitly holds the lease.
    if command -v wr_claim >/dev/null 2>&1 && ! wr_claim "svc:$id" "heal-watch" 900; then
      printf '%s [heal-watch] %s already owned by %s — skip (coordination)\n' "$(ts)" "$id" "$(wr_owner "svc:$id" 2>/dev/null)" >>"$LOG"
    else
      ( "$HERE/self-heal.sh" "$id" "heal-watch: $url returned $code" >/dev/null 2>&1
        command -v wr_release >/dev/null 2>&1 && wr_release "svc:$id" "heal-watch" ) &
    fi
  fi
done
wait
svcjson="$svcjson]"
overall=$([ "$down" = 0 ] && echo true || echo false)
summ="$((checked-down)) up / $down down"
python3 -c "import json,sys;json.dump({'ok':sys.argv[1],'summary':sys.argv[2],'detail':{'services':json.loads(sys.argv[3])},'ts':sys.argv[4]},open('$STATE/heal-status.json','w'))" "$overall" "$summ" "$svcjson" "$(isots)" 2>>"$LOG"
printf '%s [heal-watch] checked %s, %s down\n' "$(ts)" "$checked" "$down" >>"$LOG"

# --- auto-OS-heal: re-run any monitor whose state file is STALE **for its own
#     cadence** so a silently-stopped subsystem refreshes itself. Read-only
#     monitors are safe to re-run; genuine issues (doc drift, cost) route to the
#     dreaming cycle instead.
#
#     The window is per-job, not flat. A flat 3h window was evidence of nothing
#     for a job that only ever runs weekly, so this block re-ran every calendar
#     job forever: code-health 117 times, docs-scan 126, os-selftest 119,
#     cost-guard 116. code-health is the heavy `claude -p --model sonnet` audit
#     over seven repos — a weekly job ran every ~3h11m (the window plus its own
#     runtime), burning tokens . See
#     lib/job-cadence.sh. ---
# statusfile:job pairs. NOT an associative array: `declare -A` needs bash 4+, and
# macOS ships bash 3.2 with no newer bash anywhere on the launchd PATH. Under
# `set -u` that line aborted the script every run with "cf: unbound variable", so
# this entire block — the safety net that re-runs a silently-stopped monitor — had
# never executed once. It failed after the health probes, so heal-watch still
# looked like it was working.
JOBS="docs-scan-status.json:docs-scan code-health-status.json:code-health runner-status.json:ci-runner-guard os-selftest-status.json:os-selftest"
# Without this source job_stale_after is "command not found", which under the
# `|| echo` fallback below yields the old flat floor — degraded, never silent.
. "$HERE/lib/job-cadence.sh" 2>/dev/null || true
now=$(date +%s 2>/dev/null || echo 0); FLOOR=$((3*3600)); CD="$STATE/os-heal-cooldown"; mkdir -p "$CD"
for pair in $JOBS; do
  sf="${pair%%:*}"; job="${pair##*:}"
  p="$STATE/$sf"; [ -f "$p" ] || continue
  mt=$(stat -c %Y "$p" 2>/dev/null || stat -f %m "$p" 2>/dev/null || echo "$now")
  period=$(job_period_seconds "$job" 2>/dev/null || echo "")
  stale=$(job_stale_after "$period" "$FLOOR" 2>/dev/null || echo "$FLOOR")
  [ $((now-mt)) -lt "$stale" ] && continue
  cf="$CD/$job"; lc=$([ -f "$cf" ] && cat "$cf" 2>/dev/null || echo 0)
  [ $((now-lc)) -lt "$stale" ] && continue   # per-job cooldown, same window
  echo "$now" > "$cf"
  launchctl kickstart -k "gui/$(id -u)/$OS_LAUNCHD_PREFIX.$job" 2>/dev/null
  # the age was inside single quotes before, so it printed the literal $((...))
  printf '%s [os-heal] %s stale (%ss > %ss window, cadence %ss) -> re-ran %s.%s\n' \
    "$(ts)" "$sf" "$((now-mt))" "$stale" "${period:-unknown}" "$OS_LAUNCHD_PREFIX" "$job" >>"$LOG"
done
