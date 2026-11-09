#!/usr/bin/env bash
# Whisky AI OS — wedged-guest watch (see lib/guest-wedge.sh for the 2026-10-25 incident and the verdict rules).
#
#   1. PROBE   time `umbra exec <vm> true` (bounded). > 120 s, or a timeout, counts as slow.
#   2. JOBS    in-flight CI jobs on the fleet repos (gh, bounded): started time + newest step time.
#   3. DECIDE  two slow probes in a row, or a job past its ceiling      -> Telegram alert + `umbra doctor`
#              a slow guest AND no job progressing for 30+ min          -> stop/start the guest (cooldown 2 h)
#
# Read-mostly. The ONLY mutation is `umbra stop && umbra start`, and only on the narrow RESTART verdict. It never
# touches a guest that `umbra rebuild` is provisioning, or one parked on purpose (same guards as ci-runner-guard).
#
# Test seams (ops/tests/guest-wedge-watch.test.sh): WEDGE_PROBE_CMD (prints seconds), WEDGE_JOBS_CMD (prints the
# jobs file lines), WEDGE_NOW, WEDGE_STATE, UMBRA_BIN, WEDGE_NOTIFY.
# shellcheck source=lib/os-config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/os-config.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-config.sh" 2>/dev/null || true
command -v os_config_load >/dev/null 2>&1 && os_config_load
set -uo pipefail
# S0 (2026-10-26): --help runs nothing; one run at a time (lib/single-instance.sh)
. "$(dirname "${BASH_SOURCE[0]}")/lib/args.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/args.sh" || exit 2
. "$(dirname "${BASH_SOURCE[0]}")/lib/single-instance.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/single-instance.sh" || exit 2
args_help "${BASH_SOURCE[0]}" "$@"
single_instance guest-wedge-watch
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib/guest-wedge.sh"
. "$HERE/lib/os-state.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-state.sh" 2>/dev/null || true
. "$HERE/lib/umbra-provisioning.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/umbra-provisioning.sh" 2>/dev/null || true
. "$HERE/lib/runner-fleet.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/runner-fleet.sh" 2>/dev/null || true
command -v umbra_provisioning >/dev/null 2>&1 || umbra_provisioning() { return 1; }
command -v fleet_parked >/dev/null 2>&1 || fleet_parked() { return 1; }
command -v umbra_start_flags >/dev/null 2>&1 || umbra_start_flags() { return 0; }   # umbra U1 flag, when the installed umbra has it

VM="${WEDGE_VM:-$OS_VM}"
REPOS="${WEDGE_REPOS:-$OS_ORG/ebda-store $OS_REPO_SLUG}"
STATE="${WEDGE_STATE:-$HOME/.whisky-os-state/guest-wedge}"
UMBRA="${UMBRA_BIN:-umbra}"
NOTIFY="${WEDGE_NOTIFY:-$HERE/notify.sh}"
PROBE_TIMEOUT="${WEDGE_PROBE_TIMEOUT:-200}"
mkdir -p "$STATE"
NOW="${WEDGE_NOW:-$(date +%s)}"

# bounded runner (portable: no coreutils timeout on macOS). 124 on timeout.
_bounded() {
  local secs="$1"; shift
  "$@" & local p=$! t=0
  while kill -0 "$p" 2>/dev/null; do
    [ "$t" -ge $((secs * 5)) ] && { kill -TERM "$p" 2>/dev/null; sleep 1; kill -KILL "$p" 2>/dev/null; wait "$p" 2>/dev/null; return 124; }
    sleep 0.2; t=$((t + 1))
  done
  wait "$p"
}
say() { printf '%s guest-wedge-watch: %s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" "$*"; }
page() { "$NOTIFY" "$1" "$2" >/dev/null 2>&1 && say "alert sent: $1" || say "ALERT SEND FAILED: $1"; }

# a guest that is being rebuilt or parked on purpose is nobody's incident
if r="$(umbra_provisioning "$VM" "$NOW")"; then say "skip: $VM is provisioning ($r)"; exit 0; fi
if fleet_parked "$VM" 2>/dev/null; then say "skip: $VM is parked"; exit 0; fi

# ---- 1. probe ---------------------------------------------------------------------------------------------
if [ -n "${WEDGE_PROBE_CMD:-}" ]; then secs="$(eval "$WEDGE_PROBE_CMD")"
else
  t0=$(date +%s); _bounded "$PROBE_TIMEOUT" "$UMBRA" exec "$VM" true >/dev/null 2>&1; rc=$?
  secs=$(( $(date +%s) - t0 )); [ "$rc" -eq 124 ] && secs=9999
  # a fast FAILURE is a dead guest (ci-runner-guard's job), not a slow one
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then say "probe failed fast (rc=$rc): dead, not wedged; ci-runner-guard owns this"; secs=0; fi
fi
gw_record_probe "$STATE" "$VM" "$secs"

# ---- 2. in-flight jobs ------------------------------------------------------------------------------------
JOBS="$STATE/$VM.jobs"; : > "$JOBS"
if [ -n "${WEDGE_JOBS_CMD:-}" ]; then eval "$WEDGE_JOBS_CMD" > "$JOBS"
else
  for repo in $REPOS; do
    _bounded 40 gh api "repos/$repo/actions/runs?status=in_progress&per_page=20" --jq '.workflow_runs[].id' 2>/dev/null | while read -r run; do
      _bounded 40 gh api "repos/$repo/actions/runs/$run/jobs?per_page=50" --jq '
        .jobs[] | select(.status=="in_progress" and ((.runner_name // "") | startswith("'"$VM"'")))
        | [ "'"$repo"'#\(.id)", (.started_at|fromdateiso8601),
            ([.steps[]? | (.completed_at // .started_at // empty) | fromdateiso8601] | max // 0) ] | join("|")' 2>/dev/null
    done >> "$JOBS"
  done
fi

# ---- 3. decide + act --------------------------------------------------------------------------------------
verdicts="$(gw_decide "$STATE" "$VM" "$NOW" "$JOBS")"
say "probe=${secs}s jobs=$(grep -c . "$JOBS" 2>/dev/null || echo 0) verdicts: $(echo "$verdicts" | tr '\n' ';')"
slow_n="$(echo "$verdicts" | sed -n 's/^SLOW //p')"; slow_n="${slow_n:-0}"

if [ "$slow_n" -ge 2 ] && gw_should_alert_slow "$STATE" "$VM" "$NOW"; then
  doc="$(_bounded 150 "$UMBRA" doctor --json 2>&1 | head -c 1200 || true)"
  page "🐌 $VM guest is wedged (slow exec x$slow_n)" "umbra exec took ${secs}s (limit ${GW_SLOW_S}s) $slow_n times in a row. A zombie git / I/O stall looks exactly like this (2026-10-25). umbra doctor: ${doc:-no output}. Auto-restart only if no job progresses for ${GW_NOPROGRESS_MIN}m."
  gw_mark_alerted "$STATE" "$VM" "$NOW"
fi
echo "$verdicts" | sed -n 's/^OVERRUN //p' | while read -r key mins; do
  [ -n "$key" ] || continue
  page "⏱ CI job past its ceiling on $VM" "$key has run $mins (ceiling ${GW_JOB_MAX_MIN}m = timeout-minutes plus margin). Running umbra doctor next."
  gw_mark_overrun "$STATE" "$VM" "$key"
  _bounded 150 "$UMBRA" doctor --json >"$STATE/$VM.doctor-overrun.json" 2>&1 || true
done
# U4 evidence: host facts + the guest's top RSS, saved BEFORE anything is restarted (umbra stop adds its own forensics bundle).
capture_evidence() {
  local f="$STATE/$VM.evidence-$NOW.txt"
  {
    echo "== $(date -u +%FT%TZ) probe=${secs}s"
    echo "== host swap: $(sysctl -n vm.swapusage 2>/dev/null)"; echo "== host load: $(uptime 2>/dev/null)"
    echo "== host top RSS"; ps -Ao rss,comm 2>/dev/null | sort -rn | head -8
    echo "== guest"; _bounded 40 "$UMBRA" exec "$VM" sh -c 'free -m | head -3; head -2 /proc/pressure/io; ps -eo rss,args --sort=-rss | head -6 | cut -c1-120; ls /run/umbra-ci-slots 2>/dev/null' 2>&1 | head -30
  } > "$f" 2>&1
  printf '%s' "$f"
}
# After the restart: the guest must answer, and docker must actually RUN a container (a guest with runners online and docker dead
# looked healthy before). postgres:16-alpine is the image CI's service containers use; pg_isready --version proves the runtime.
verify_after_restart() {
  local i=0
  while [ "$i" -lt 30 ]; do _bounded 20 "$UMBRA" exec "$VM" true >/dev/null 2>&1 && break; i=$((i + 1)); sleep 10; done
  [ "$i" -lt 30 ] || { echo "guest did not answer within 5 min"; return 1; }
  _bounded 120 "$UMBRA" exec "$VM" docker run --rm postgres:16-alpine pg_isready --version >/dev/null 2>&1 || { echo "guest is up but docker could not run postgres:16-alpine"; return 1; }
  echo "guest answers and docker runs postgres:16-alpine"
}
if echo "$verdicts" | grep -qx STANDDOWN; then
  say "STANDDOWN: restart budget (${GW_MAX_RESTARTS_24H:-2}/24h) spent"
  if [ $(( NOW - $(_gw_get "$STATE/$VM.state" last_standdown) )) -gt "${GW_ALERT_REPEAT_S:-3600}" ]; then
    page "🛑 $VM keeps wedging: auto-restart budget spent (${GW_MAX_RESTARTS_24H:-2} in 24 h)" "Slow guest and no job progress, but I have already restarted it ${GW_MAX_RESTARTS_24H:-2} times in the last 24 h, so I am standing down. Needs a human: umbra doctor $VM, ~/.umbra/forensics, then decide (never an automatic rebuild)."
    _gw_set "$STATE/$VM.state" last_standdown "$NOW"
  fi
fi
if echo "$verdicts" | grep -qx RESTART; then
  say "RESTART: ${slow_n} slow probes and no job progress for >${GW_NOPROGRESS_MIN}m"
  if r="$(umbra_provisioning "$VM" "$NOW")"; then say "restart skipped: provisioning ($r)"; else
    ev="$(capture_evidence)"
    page "♻️ restarting $VM (wedged, no job progress ${GW_NOPROGRESS_MIN}m+)" "Evidence: $ev. umbra stop (ACPI re-press, forensics, marks the disk dirty if hard-killed) then umbra start with the fsck guard. Jobs in flight on this guest will be re-queued by GitHub or fail."
    gw_mark_restarted "$STATE" "$VM" "$NOW"
    _bounded 300 "$UMBRA" stop "$VM" >/dev/null 2>&1 || true
    # shellcheck disable=SC2046  # intentional: empty flag list must vanish, not become an empty argument
    if _bounded 900 "$UMBRA" start $(umbra_start_flags "$UMBRA") "$VM" >/dev/null 2>&1; then
      if vmsg="$(verify_after_restart)"; then page "✅ $VM restarted and healthy" "$vmsg. Runners come back one at a time (boot stagger). No bulk deletes for 30 min after boot."
      else page "🚨 $VM restarted but is NOT healthy" "$vmsg. Needs a human: umbra doctor $VM."; fi
    else
      page "🚨 $VM did not start after the wedge restart" "umbra start failed or refused (a dirty disk that failed fsck?). Needs a human: umbra doctor $VM; never rebuild automatically."
    fi
  fi
fi
# ---- 4. host pressure (the wedge's upstream cause: 34-45 GB free, swap 3 of 4 GB used, 105 vitest processes) ----
# Alert-only; repeats at most every GW_HOST_ALERT_S (6 h) per kind so a sustained condition does not spam.
host_free_gb() { if [ -n "${WEDGE_HOST_FREE_CMD:-}" ]; then eval "$WEDGE_HOST_FREE_CMD"; else df -k "$HOME/.umbra" 2>/dev/null | awk 'NR==2{printf "%d", $4/1048576}'; fi; }
swap_pct() { # percent of swap in use; 0 when unknown
  local used total
  if [ -n "${WEDGE_SWAP_CMD:-}" ]; then read -r used total < <(eval "$WEDGE_SWAP_CMD")
  else read -r used total < <(sysctl -n vm.swapusage 2>/dev/null | sed -E 's/.*total = ([0-9.]+)M +used = ([0-9.]+)M.*/\2 \1/'); fi
  awk -v u="${used:-0}" -v t="${total:-0}" 'BEGIN{ if (t+0 > 0) printf "%d", 100*u/t; else print 0 }'
}
host_alert() { # kind title body
  local f="$STATE/$VM.host-$1" last=0
  [ -f "$f" ] && last="$(cat "$f" 2>/dev/null || echo 0)"
  [ $(( NOW - last )) -gt "${GW_HOST_ALERT_S:-21600}" ] || return 0
  page "$2" "$3"; echo "$NOW" > "$f"
}
free_gb="$(host_free_gb)"; free_gb="${free_gb:-999}"
if [ "$free_gb" -lt "${GW_HOST_FREE_MIN_GB:-30}" ]; then
  host_alert free "💽 Mac free disk ${free_gb} GB (limit ${GW_HOST_FREE_MIN_GB:-30})" "The Umbra guest image is sparse on this volume; a full host corrupts the guest (2026-10-16) and a near-full one slows its I/O. Free space (worktrees, caches, umbra prune)."
fi
sp="$(swap_pct)"
if [ "${sp:-0}" -ge "${GW_SWAP_MAX_PCT:-85}" ]; then
  host_alert swap "🧠 Mac swap ${sp}% used" "Host memory pressure starves the CI guest's I/O (the 2026-10-25 wedge ran with swap 3 of 4 GB). Check concurrent vitest/pre-push runs (ps -axo rss,comm | sort -rn | head)."
fi

# ---- 5. guest I/O wait + swap + root-disk pressure (2026-10-26 17:08Z: swap 99.5%, 43% iowait, 160 MB free -> 4 D1 statements took 91.8 s
# instead of 47 ms; sar showed 360 MB/s of READS at 8 ms await = a swap storm, not a slow disk) ----
# Alert-only, at most once per GW_GUEST_ALERT_S (1 h). Reads PSI (/proc/pressure/io, "full avg60") and swap use inside the guest.
guest_pressure() { # prints: <io-full-avg60-int> <swap-pct-int> <root-disk-pct-int>
  if [ -n "${WEDGE_GUEST_PRESSURE_CMD:-}" ]; then eval "$WEDGE_GUEST_PRESSURE_CMD"; return; fi
  _bounded 40 "$UMBRA" exec "$VM" sh -c 'io=$(sed -n "s/^full .*avg60=\([0-9]*\).*/\1/p" /proc/pressure/io); st=$(awk "/^SwapTotal:/{t=\$2}/^SwapFree:/{f=\$2}END{if(t>0)printf \"%d\",(t-f)*100/t; else print 0}" /proc/meminfo); dk=$(df --output=pcent / | tail -1 | tr -dc 0-9); echo "${io:-0} ${st:-0} ${dk:-0}"' 2>/dev/null | tail -1
}
guest_alert() { # kind title body
  local f="$STATE/$VM.guest-$1" last=0
  [ -f "$f" ] && last="$(cat "$f" 2>/dev/null || echo 0)"
  [ $(( NOW - last )) -gt "${GW_GUEST_ALERT_S:-3600}" ] || return 0
  page "$2" "$3"; echo "$NOW" > "$f"
}
read -r gio gswap gdisk < <(guest_pressure) || true
gio="${gio:-0}"; gswap="${gswap:-0}"; gdisk="${gdisk:-0}"
if [ "$gio" -ge "${GW_GUEST_IO_FULL_PCT:-25}" ]; then
  guest_alert io "💾 $VM guest I/O stall: ${gio}% of the last minute spent waiting on I/O (limit ${GW_GUEST_IO_FULL_PCT:-25})" "PSI io full avg60=${gio}, swap ${gswap}% used. A swap storm (too many heavy jobs for 5 GiB) looks exactly like a slow disk; umbra's memory-aware admission should be holding new heavy jobs. Check umbra shell $VM -- sar -u -r -S."
fi
if [ "$gdisk" -ge "${GW_GUEST_DISK_PCT:-85}" ]; then
  guest_alert disk "💽 $VM guest root disk ${gdisk}% full (limit ${GW_GUEST_DISK_PCT:-85})" "At 90%+ the guest filesystem is one bad write from emergency_ro (2026-10-26). Leaked anonymous docker volumes were 35 volumes / 2.7 GB in hours: umbra's job-completed hook prunes them when the guest is idle; if it stays high run 'umbra prune $VM' while CI is idle."
fi
if [ "$gswap" -ge "${GW_GUEST_SWAP_PCT:-90}" ]; then
  guest_alert swap "🧠 $VM guest swap ${gswap}% used" "The guest is out of memory headroom (PSI io full avg60=${gio}). Heavy jobs wait for memory; if this persists reduce concurrency or raise guest RAM (host swap permitting)."
fi

command -v write_status >/dev/null 2>&1 && write_status "guest-wedge-watch" "$([ "$slow_n" -ge 2 ] && echo warn || echo ok)" "probe ${secs}s, slow x${slow_n}" "{\"vm\":\"$VM\"}"
exit 0
