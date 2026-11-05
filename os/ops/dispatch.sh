# shellcheck shell=bash
# dispatch.sh — single entry point for ALL remediation events (Telegram transport + local).
HERE_D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE_D/lib/work-registry.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/work-registry.sh" 2>/dev/null || true

_disp_field() { printf '%s' "$1" | python3 -c 'import json,sys;print(json.load(sys.stdin).get(sys.argv[1],""))' "$2" 2>/dev/null; }
_disp_workid() { # <kind> <target-json> -> work_id
  local kind="$1" t="$2"
  case "$kind" in
    ci-failure)    printf 'ci:%s@%s' "$(_disp_field "$t" slug)" "$(_disp_field "$t" sha)";;
    code-finding)  printf 'finding:%s' "$(_disp_field "$t" id)";;
    service-down)  printf 'svc:%s' "$(_disp_field "$t" name)";;
    runner-offline)printf 'runner:%s' "$(_disp_field "$t" name)";;
    *) printf 'unknown:%s' "$kind";;
  esac
}

dispatch_event() { # <event-json> -> one result token
  local ev="$1" now id kind ts target wid seen cool flag
  now="$(_WR_NOW)"
  flag="${AUTONOMY_FLAG:-$(_WR_SD)/AUTONOMY_OFF}"
  [ -f "$flag" ] && { echo "NOTIFY-ONLY"; return 0; }
  id="$(_disp_field "$ev" id)"; kind="$(_disp_field "$ev" kind)"; ts="$(_disp_field "$ev" ts)"
  target="$(printf '%s' "$ev" | python3 -c 'import json,sys;print(json.dumps(json.load(sys.stdin).get("target",{}),separators=(",",":")))')"
  seen="${SEEN_FILE:-$(_WR_SD)/seen-events.json}"; [ -f "$seen" ] || echo '{}' > "$seen"
  # dedup by id (24h TTL)
  if python3 - "$seen" "$id" "$now" <<'PY'
import json,sys,os; f,id,now=sys.argv[1],sys.argv[2],int(sys.argv[3])
d=json.load(open(f)); d={k:v for k,v in d.items() if v>now-86400}
seen=id in d; d[id]=now; tmp=f+".tmp"; json.dump(d,open(tmp,"w")); os.replace(tmp,f); sys.exit(0 if seen else 1)
PY
  then echo "DROP replay"; return 0; fi
  # max-age (24h)
  [ -n "$ts" ] && [ "$((now-ts))" -gt 86400 ] 2>/dev/null && { echo "DROP stale"; return 0; }
  # re-verify current state
  local reverify="${DISPATCH_REVERIFY:-$HERE_D/dispatch-reverify.sh}"
  if ! $reverify "$kind" "$target" >/dev/null 2>&1; then echo "DROP resolved"; return 0; fi
  wid="$(_disp_workid "$kind" "$target")"
  # claim (skip if held by another owner)
  local me="dispatch:$$"
  # 3600s > worst-case single fix; long fixes need wr_heartbeat (Phase B/C).
  if ! wr_claim "$wid" "$me" 3600; then echo "SKIP $wid owned-by $(wr_owner "$wid")"; return 0; fi
  # cooldown (per work_id last-acted)
  cool="${COOLDOWN_FILE:-$(_WR_SD)/dispatch-cooldown.json}"; [ -f "$cool" ] || echo '{}' > "$cool"
  if python3 - "$cool" "$wid" "$now" "${COOLDOWN_SECS:-300}" <<'PY'
import json,sys,os; f,wid,now,win=sys.argv[1],sys.argv[2],int(sys.argv[3]),int(sys.argv[4])
d=json.load(open(f)); last=d.get(wid,0); recent = now-last < win
d[wid]=now; tmp=f+".tmp"; json.dump(d,open(tmp,"w")); os.replace(tmp,f); sys.exit(0 if recent else 1)
PY
  then wr_release "$wid" "$me"; echo "COOLDOWN $wid"; return 0; fi
  # route to the responder, then release
  local route="${DISPATCH_ROUTE:-$HERE_D/dispatch-route.sh}"
  $route "$kind" "$target" >/dev/null 2>&1 || true
  wr_release "$wid" "$me"
  echo "HANDLED $wid via $kind"; return 0
}