#!/usr/bin/env bash
# Ebda AI OS - outside-watch.sh: the probe loop that runs OFF Cloudflare (F-OBS-1).
# Replaces the disabled GitHub-hosted prod-watch workflow (Ruling NO-HOSTED-RUNNERS-1: never hosted runners). The brain's Cron Trigger
# stays the primary probe; this Mac launchd job is the independent second opinion that still fires when the brain Worker or Cloudflare is down.
#
#   outside-watch.sh [--config FILE] [--once]       (launchd: every 5 min; ~12 curls, each capped at 10 s)
#
# Targets: the probes of os/config/prod-watch.json (name, url, expect = HTTP status, contains = body regex). A probe FAILS on a wrong status,
# a body that does not match, a timeout or a connection error.
# Alerting (state in $OS_STATE_DIR/outside-watch/<probe>.json):
#   - 2 consecutive failures before the first alert (one blip never pages); ONE message per run lists every newly-down probe
#   - while still down: a reminder every OUTSIDE_WATCH_REMIND_H hours (default 6), never every tick (dedupe)
#   - a probe that recovers after an alert sends ONE recovery message
#   - control probe (OUTSIDE_WATCH_CONTROL, default Apple's captive-portal page): if THAT fails the Mac itself is offline, the run is skipped and
#     logged, so an offline Mac never reports the whole suite as down.
# Delivery goes through notify.sh (Keychain token, brain fallback). If delivery fails the probe is NOT marked alerted, so the next tick retries.
# Test hooks: OUTSIDE_WATCH_CURL (curl binary), OUTSIDE_WATCH_NOTIFY (notify binary), OUTSIDE_WATCH_NOW (epoch seconds).
# shellcheck source=lib/os-config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/os-config.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-config.sh" 2>/dev/null || true
command -v os_config_load >/dev/null 2>&1 && os_config_load
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
CONFIG="$HERE/../config/prod-watch.json"; [ -f "$CONFIG" ] || CONFIG="$HOME/.claude/prod-watch.json"
while [ $# -gt 0 ]; do
  case "$1" in
    --config) CONFIG="${2:?}"; shift ;;
    --once) ;;
    -h|--help) sed -n 2,19p "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "outside-watch: unknown option $1" >&2; exit 2 ;;
  esac
  shift
done
CURL="${OUTSIDE_WATCH_CURL:-curl}"
NOTIFY="${OUTSIDE_WATCH_NOTIFY:-$HERE/notify.sh}"; [ -x "$NOTIFY" ] || NOTIFY="$HOME/.claude/scripts/notify.sh"
NOW="${OUTSIDE_WATCH_NOW:-$(date +%s)}"
REMIND_S=$(( ${OUTSIDE_WATCH_REMIND_H:-6} * 3600 ))
CONTROL="${OUTSIDE_WATCH_CONTROL:-https://captive.apple.com/}"
SD="${OS_STATE_DIR:-$HOME/.whisky-os-state}/outside-watch"; mkdir -p "$SD"
log() { printf '%s outside-watch: %s\n' "$(date -u +%H:%M:%S)" "$*"; }

[ -f "$CONFIG" ] || { log "FAILED: no probe config at $CONFIG"; exit 1; }
if ! "$CURL" -sS -o /dev/null -m 8 "$CONTROL" 2>/dev/null; then log "control probe failed ($CONTROL): this Mac is offline, run skipped"; exit 0; fi

# name|url|expect (names/urls have no pipes)
PROBES="$(python3 -I - "$CONFIG" <<'PY'
import json, sys
for p in json.load(open(sys.argv[1])).get("probes", []):
    print("|".join([p["name"], p["url"], str(p.get("expect", 200))]))
PY
)" || { log "FAILED: cannot read $CONFIG"; exit 1; }
# the body regex may hold '|', so it is read separately per probe name
CONTAINS_OF() { python3 -I - "$CONFIG" "$1" <<'PY'
import json, sys
for p in json.load(open(sys.argv[1])).get("probes", []):
    if p["name"] == sys.argv[2]: print(p.get("contains") or "")
PY
}

newly=(); recovered=(); reminders=()
while IFS='|' read -r name url expect _; do
  [ -n "$name" ] || continue
  body="$(mktemp)"
  code="$("$CURL" -sS -o "$body" -w '%{http_code}' -m 10 --connect-timeout 5 "$url" 2>/dev/null)"; crc=$?
  contains="$(CONTAINS_OF "$name")"
  ok=1; why=""
  if [ "$crc" != 0 ]; then ok=0; why="curl exit $crc"
  elif [ "$code" != "$expect" ]; then ok=0; why="HTTP $code (want $expect)"
  elif [ -n "$contains" ] && ! grep -Eiq -- "$contains" "$body"; then ok=0; why="body does not match /$contains/"; fi
  rm -f "$body"
  st="$SD/$name.state"   # lines: fails=N alerted=EPOCH|0 why=...
  fails=0; alerted=0
  if [ -f "$st" ]; then fails="$(sed -n 's/^fails=//p' "$st")"; alerted="$(sed -n 's/^alerted=//p' "$st")"; fi
  fails="${fails:-0}"; alerted="${alerted:-0}"
  if [ "$ok" = 1 ]; then
    [ "$alerted" != 0 ] && recovered+=("$name ($url)")
    rm -f "$st"; continue
  fi
  fails=$((fails + 1))
  log "FAIL $name $url: $why (consecutive $fails)"
  if [ "$fails" -ge 2 ]; then
    if [ "$alerted" = 0 ]; then newly+=("$name ($url): $why")
    elif [ $(( NOW - alerted )) -ge "$REMIND_S" ]; then reminders+=("$name ($url): $why"); fi
  fi
  printf 'fails=%s\nalerted=%s\nwhy=%s\n' "$fails" "$alerted" "$why" > "$st"
done <<< "$PROBES"

mark() { # mark <name...> alerted now (only after a delivered alert)
  for n in "$@"; do n="${n%% *}"; [ -f "$SD/$n.state" ] && sed -i '' "s/^alerted=.*/alerted=$NOW/" "$SD/$n.state"; done
}
if [ "${#newly[@]}" -gt 0 ]; then
  if "$NOTIFY" "PROD DOWN (outside Cloudflare, 2 checks)" "$(printf '%s\n' "${newly[@]}")"; then mark "${newly[@]}"; else log "alert delivery FAILED, will retry next tick"; fi
fi
if [ "${#reminders[@]}" -gt 0 ]; then
  if "$NOTIFY" "still down" "$(printf '%s\n' "${reminders[@]}")"; then mark "${reminders[@]}"; else log "reminder delivery FAILED"; fi
fi
if [ "${#recovered[@]}" -gt 0 ]; then
  "$NOTIFY" --silent "RECOVERED" "$(printf '%s\n' "${recovered[@]}")" || log "recovery delivery FAILED"
fi
exit 0
