#!/usr/bin/env bash
# Ebda AI OS - alert-wait.sh   (ruling AIOS-8: the controller's alert feed)
#
# Blocks until the brain has a platform alert newer than the last one this script reported, prints the new alert(s) newest first,
# records the newest id, and exits 0. Run it as a background task: each exit = new alerts = wake up, read, re-run.
#
#   alert-wait.sh [--interval SEC] [--once] [--since ID] [--state FILE]
#     --interval   poll period (default 60)
#     --once       poll once: exit 0 with alerts, 1 when there is nothing new
#     --since ID   start after this id instead of the state file (0 = everything the brain still holds)
#     --state      last-seen id file (default $OS_STATE_DIR/alert-wait.last-id)
# First run with no state file and no --since: the current newest id becomes the baseline (history is not replayed) and it waits.
# Auth: Basic user ahmad, password from $EBDA_OS_DASH_PASSWORD or the Keychain item "ebda-os-dash" (never printed).
# Brain: $OS_BRAIN_URL (default https://os.ebda.app). Exit: 0 new alerts, 1 nothing new (--once), 2 config/auth error.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/os-config.sh
. "$HERE/lib/os-config.sh" 2>/dev/null && os_config_load 2>/dev/null || true
INTERVAL=60; ONCE=0; SINCE=""; STATE="${OS_STATE_DIR:-$HOME/.whisky-os-state}/alert-wait.last-id"
while [ $# -gt 0 ]; do
  case "$1" in
    --interval) shift; INTERVAL="${1:?}" ;;
    --once) ONCE=1 ;;
    --since) shift; SINCE="${1:?}" ;;
    --state) shift; STATE="${1:?}" ;;
    -h|--help) sed -n 2,15p "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "alert-wait: unknown option $1" >&2; exit 2 ;;
  esac
  shift
done
[[ "$INTERVAL" =~ ^[0-9]+$ ]] && [ "$INTERVAL" -ge 1 ] || { echo "alert-wait: --interval must be a positive integer" >&2; exit 2; }
BRAIN="${OS_BRAIN_URL:-https://os.ebda.app}"
PW="${EBDA_OS_DASH_PASSWORD:-$(security find-generic-password -a ahmad -s ebda-os-dash -w 2>/dev/null || security find-generic-password -a "$USER" -s ebda-os-dash -w 2>/dev/null || true)}"
[ -n "$PW" ] || { echo "alert-wait: no dashboard password (EBDA_OS_DASH_PASSWORD or Keychain item ebda-os-dash)" >&2; exit 2; }
mkdir -p "$(dirname "$STATE")"
AUTH="$(mktemp)"; OUT="$(mktemp)"; trap 'rm -f "$AUTH" "$OUT"' EXIT
chmod 600 "$AUTH"; printf 'user = "ahmad:%s"\n' "$PW" > "$AUTH"; unset PW

fetch() { # <since> -> body in $OUT, echoes the HTTP code
  curl -sS -m 20 -K "$AUTH" -o "$OUT" -w '%{http_code}' "${BRAIN%/}/api/alerts?since=$1&limit=100" 2>/dev/null || echo 000
}
if [ -n "$SINCE" ]; then last="$SINCE"
elif [ -s "$STATE" ]; then last="$(tr -dc '0-9' < "$STATE")"
else
  code="$(fetch 0)"
  [ "$code" = 401 ] && { echo "alert-wait: brain refused the password (401)" >&2; exit 2; }
  last="$(python3 -I -c 'import json,sys; a=json.load(open(sys.argv[1])).get("alerts") or []; print(max([int(x["id"]) for x in a] or [0]))' "$OUT" 2>/dev/null || echo 0)"
  printf '%s\n' "$last" > "$STATE"
  echo "alert-wait: no state yet; baseline = alert #$last (history not replayed; --since 0 shows it)" >&2
fi
last="${last:-0}"
while :; do
  code="$(fetch "$last")"
  if [ "$code" = 401 ]; then echo "alert-wait: brain refused the password (401)" >&2; exit 2; fi
  if [ "$code" = 200 ]; then
    newest="$(python3 -I - "$OUT" <<'PY'
import json, sys, time
a = json.load(open(sys.argv[1])).get("alerts") or []
if a:
    for x in a:
        t = time.strftime("%Y-%m-%d %H:%M:%SZ", time.gmtime(int(x["at"]) / 1000))
        n = f" x{x['count']}" if int(x.get("count") or 1) > 1 else ""
        print(f"#{x['id']} {t} [{x['level']}] {x['source']}: {x['title']}{n}")
        if x.get("url"): print(f"    {x['url']}")
        body = str(x.get("text") or "").strip().replace("\n", "\n    ")
        if body and body != x["title"]: print(f"    {body[:1500]}")
PY
)"
    if [ -n "$newest" ]; then
      printf '%s\n' "$newest"
      python3 -I -c 'import json,sys; a=json.load(open(sys.argv[1])).get("alerts") or []; print(max(int(x["id"]) for x in a))' "$OUT" > "$STATE"
      exit 0
    fi
  else
    echo "alert-wait: brain answered HTTP $code; retrying in ${INTERVAL}s" >&2
  fi
  [ "$ONCE" = 1 ] && exit 1
  sleep "$INTERVAL"
done
