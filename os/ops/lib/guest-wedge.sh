# shellcheck shell=bash
# ops/lib/guest-wedge.sh — decision logic for ops/guest-wedge-watch.sh (pure: state dir + numbers in, verdict out).
#
# WHY (2026-10-25 04:36Z, $OS_VM restarted by hand). A zombie `git` ran at 96% CPU for 68 min, jbd2 and
# kcompactd sat in D state, load 19, ~50% iowait, `umbra exec true` took ~9 min, and GitHub still showed both
# runners online and busy. Nothing detected it: ci-runner-guard only reacts to a DEAD guest (ssh down / no runner),
# and a wedged guest answers, slowly. The signature is LATENCY, not death.
#
# Verdicts (printed one per line by gw_decide):
#   SLOW <n>        the last <n> consecutive guest execs took > GW_SLOW_S (or timed out); n >= 2 means alert + doctor
#   OVERRUN <key>   an in-progress job has run past GW_JOB_MAX_MIN (its timeout-minutes plus margin): alert once
#   NOPROGRESS <m>  nothing has progressed for <m> minutes while jobs are in flight
#   RESTART         SLOW >= 2 AND NOPROGRESS > GW_NOPROGRESS_MIN AND the restart cooldown has elapsed AND < GW_MAX_RESTARTS_24H in 24 h
#   STANDDOWN       the same conditions but the 24 h restart budget is spent: page a human, do NOT restart again
# Auto-restart is deliberately the narrowest of the three: it needs BOTH symptoms (a slow guest AND no job
# progressing for 30+ min), because restarting kills whatever is running.
#
# State (key=value files, no associative arrays: macOS bash 3.2): $dir/<vm>.state
#   slow_count, last_probe_s, last_progress, last_alert, last_restart ; $dir/<vm>.overrun-alerted (one key per line)

# shellcheck source=os-config.sh
command -v os_config_load >/dev/null 2>&1 || . "$(dirname "${BASH_SOURCE[0]}")/os-config.sh" 2>/dev/null || true
[ -n "${OS_ORG:-}" ] || ! command -v os_config_load >/dev/null 2>&1 || os_config_load
GW_SLOW_S="${GW_SLOW_S:-120}"
GW_JOB_MAX_MIN="${GW_JOB_MAX_MIN:-45}"          # longest timeout-minutes in the fleet is 25-30, plus margin
GW_NOPROGRESS_MIN="${GW_NOPROGRESS_MIN:-30}"
GW_RESTART_COOLDOWN_S="${GW_RESTART_COOLDOWN_S:-7200}"
GW_ALERT_REPEAT_S="${GW_ALERT_REPEAT_S:-3600}"
GW_MAX_RESTARTS_24H="${GW_MAX_RESTARTS_24H:-2}"   # U4: after this many auto-restarts in 24 h, stand down and page a human

_gw_get() { local f="$1" k="$2" v; v="$(sed -n "s/^$k=//p" "$f" 2>/dev/null | tail -1)"; printf '%s' "${v:-0}"; }
_gw_set() { # file key value
  local f="$1" k="$2" v="$3"; mkdir -p "$(dirname "$f")"; touch "$f"
  grep -v "^$k=" "$f" > "$f.tmp" 2>/dev/null || true
  printf '%s=%s\n' "$k" "$v" >> "$f.tmp"; mv "$f.tmp" "$f"
}

# gw_record_probe <dir> <vm> <seconds> -> updates slow_count; seconds >= 9999 means "timed out"
gw_record_probe() {
  local f="$1/$2.state" secs="$3" n
  n="$(_gw_get "$f" slow_count)"
  if [ "$secs" -gt "$GW_SLOW_S" ]; then n=$((n + 1)); else n=0; fi
  _gw_set "$f" slow_count "$n"; _gw_set "$f" last_probe_s "$secs"
}

# gw_decide <dir> <vm> <now_epoch> <jobs_file>
# jobs_file: one in-flight job per line "key|started_epoch|last_step_epoch" (last_step = newest step start/finish)
gw_decide() {
  local dir="$1" vm="$2" now="$3" jobs="$4" f="$1/$2.state" slow np newest=0 key started last
  slow="$(_gw_get "$f" slow_count)"
  [ "$slow" -ge 1 ] && echo "SLOW $slow"

  if [ -s "$jobs" ]; then
    while IFS='|' read -r key started last; do
      [ -n "$key" ] || continue
      [ "${last:-0}" -gt "$newest" ] && newest="$last"
      [ "${started:-0}" -gt "$newest" ] && newest="$started"
      if [ $(( (now - started) / 60 )) -gt "$GW_JOB_MAX_MIN" ] && ! grep -qxF "$key" "$dir/$vm.overrun-alerted" 2>/dev/null; then
        echo "OVERRUN $key $(( (now - started) / 60 ))m"
      fi
    done < "$jobs"
    # progress watermark only moves forward
    [ "$newest" -gt "$(_gw_get "$f" last_progress)" ] && _gw_set "$f" last_progress "$newest"
    np=$(( (now - $(_gw_get "$f" last_progress)) / 60 ))
    [ "$np" -gt "$GW_NOPROGRESS_MIN" ] && echo "NOPROGRESS $np"
    if [ "$slow" -ge 2 ] && [ "$np" -gt "$GW_NOPROGRESS_MIN" ] \
       && [ $(( now - $(_gw_get "$f" last_restart) )) -gt "$GW_RESTART_COOLDOWN_S" ]; then
      # U4: never restart-loop a guest that keeps wedging; past the budget a human decides (never an automatic rebuild)
      if gw_restart_budget_ok "$dir" "$vm" "$now"; then echo "RESTART"; else echo "STANDDOWN"; fi
    fi
  else
    # nothing in flight: idle is not wedged, and the watermark restarts from the next job
    _gw_set "$f" last_progress "$now"
  fi
}

# gw_should_alert_slow <dir> <vm> <now> -> 0 when a SLOW>=2 alert is due (first time, then every GW_ALERT_REPEAT_S)
gw_should_alert_slow() {
  local f="$1/$2.state"
  [ $(( $3 - $(_gw_get "$f" last_alert) )) -gt "$GW_ALERT_REPEAT_S" ]
}
gw_mark_alerted()   { _gw_set "$1/$2.state" last_alert "$3"; }
gw_mark_restarted() {
  _gw_set "$1/$2.state" last_restart "$3"; _gw_set "$1/$2.state" slow_count 0
  mkdir -p "$1"; printf '%s\n' "$3" >> "$1/$2.restarts"
}
# gw_restart_budget_ok <dir> <vm> <now> -> 0 while fewer than GW_MAX_RESTARTS_24H restarts happened in the last 24 h
gw_restart_budget_ok() {
  local n=0 t
  while read -r t; do
    [ -n "$t" ] && [ $(( $3 - t )) -lt 86400 ] && n=$((n + 1))
  done < "$1/$2.restarts" 2>/dev/null
  [ "$n" -lt "$GW_MAX_RESTARTS_24H" ]
}
gw_mark_overrun()   { mkdir -p "$1"; printf '%s\n' "$3" >> "$1/$2.overrun-alerted"; }

# umbra_start_flags: the flags every AUTOMATED `umbra start` must carry. `--fsck-if-dirty` (umbra U1) snapshots, fscks offline
# and starts only on a clean second pass; without it a dirty disk refuses the start. Detected from `umbra start --help` so an
# older installed umbra (no such flag) keeps working. Prints nothing when unsupported.
umbra_start_flags() {
  local bin="${1:-umbra}"
  "$bin" start --help 2>&1 | grep -q -- '--fsck-if-dirty' && printf '%s' '--fsck-if-dirty'
  return 0
}
