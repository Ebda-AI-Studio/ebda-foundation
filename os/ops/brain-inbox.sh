#!/usr/bin/env bash
# Ebda AI OS - brain-inbox.sh: read Ahmad's Telegram texts that the brain stored (GET /api/inbox, POST /api/inbox/ack).
#   brain-inbox.sh list [--since MS]            unread items as JSON ({items:[...]})
#   brain-inbox.sh ack ID [ID...]               mark items read (idempotent)
#   brain-inbox.sh wait [--max-min N] [--interval S] [--since MS]
#       long-poll every S s (default 20), up to N min (default 30); print new unread items and exit 0 when one arrives, 1 on timeout.
#       Run it as a background task: the exit wakes the controller session. It does NOT ack; ack after you act.
# Never prints the token (lib/brain-call.sh). Exit 2 = config/auth error.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/os-config.sh
. "$HERE/lib/os-config.sh" 2>/dev/null && os_config_load 2>/dev/null || true
# shellcheck source=lib/brain-call.sh
. "$HERE/lib/brain-call.sh"
cmd="${1:-}"; shift || true
SINCE=0; MAXMIN=30; INTERVAL=20
while [ $# -gt 0 ] && [ "$cmd" != ack ]; do
  case "$1" in
    --since) shift; SINCE="${1:?}" ;;
    --max-min) shift; MAXMIN="${1:?}" ;;
    --interval) shift; INTERVAL="${1:?}" ;;
    *) echo "brain-inbox: unknown option $1" >&2; exit 2 ;;
  esac
  shift
done
[[ "$SINCE" =~ ^[0-9]+$ && "$MAXMIN" =~ ^[0-9]+$ && "$INTERVAL" =~ ^[0-9]+$ && "$INTERVAL" -ge 1 ]] || { echo "brain-inbox: numeric options required" >&2; exit 2; }
count() { python3 -I -c 'import json,sys; print(len(json.load(sys.stdin).get("items",[])))' 2>/dev/null || echo 0; }
case "$cmd" in
  list) brain_call GET "/api/inbox?since=$SINCE" ;;
  ack)
    [ $# -ge 1 ] || { echo "usage: brain-inbox.sh ack ID [ID...]" >&2; exit 2; }
    body="$(python3 -I -c 'import json,sys; print(json.dumps({"ids": sys.argv[1:]}))' "$@")"
    brain_call POST /api/inbox/ack -H 'content-type: application/json' --data-binary "$body" ;;
  wait)
    deadline=$(( $(date +%s) + MAXMIN * 60 ))
    while :; do
      out="$(brain_call GET "/api/inbox?since=$SINCE")"; rc=$?
      if [ "$rc" = 2 ] || [ "$rc" = 22 ]; then echo "brain-inbox: brain call failed (exit $rc)" >&2; exit 2; fi
      if [ "$rc" = 0 ] && [ "$(printf '%s' "$out" | count)" -gt 0 ]; then printf '%s\n' "$out"; exit 0; fi
      [ "$(date +%s)" -ge "$deadline" ] && exit 1
      sleep "$INTERVAL"
    done ;;
  *) sed -n 2,10p "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
