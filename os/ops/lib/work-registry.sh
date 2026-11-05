# shellcheck shell=bash
# work-registry.sh — shared "who's handling what" across ALL OS responders + live sessions.
# Claim before acting; release when done. TTL auto-expiry = stale-safe. Atomic via mkdir-lock.
_WR_SD()   { echo "${WHISKY_STATE_DIR:-$HOME/.whisky-os-state}"; }
_WR_NOW()  { echo "${NOW:-$(date +%s)}"; }
_WR_FILE() { echo "$(_WR_SD)/work-registry.json"; }
_WR_ENSURE() { mkdir -p "$(_WR_SD)"; [ -f "$(_WR_FILE)" ] || echo '{}' > "$(_WR_FILE)"; }
_wr_lock()   { local l="$(_WR_SD)/.work-registry.lock" i=0 age
  while ! mkdir "$l" 2>/dev/null; do
    age=$(( $(date +%s) - $(stat -c %Y "$l" 2>/dev/null || stat -f %m "$l" 2>/dev/null || echo 0) ))
    [ "$age" -gt 30 ] && rmdir "$l" 2>/dev/null   # break a lock a dead holder left behind
    i=$((i+1)); [ "$i" -gt 100 ] && return 1; sleep 0.05
  done; }
_wr_unlock() { rmdir "$(_WR_SD)/.work-registry.lock" 2>/dev/null; }

wr_claim() { # <work_id> <owner> [ttl=1800] -> 0 owned, 1 held by other
  _WR_ENSURE; local id="$1" owner="$2" ttl="${3:-1800}" now rc; now="$(_WR_NOW)"
  _wr_lock || return 1
  rc="$(python3 - "$(_WR_FILE)" "$id" "$owner" "$now" "$ttl" <<'PY'
import json,sys,os
f,id,owner,now,ttl=sys.argv[1],sys.argv[2],sys.argv[3],int(sys.argv[4]),int(sys.argv[5])
d=json.load(open(f)); d={k:v for k,v in d.items() if v.get("expires_at",0)>now or k==id}  # lazy gc
e=d.get(id)
if e and e.get("expires_at",0)>now and e.get("owner")!=owner:
    print(1)
else:
    d[id]={"owner":owner,"claimed_at":now,"expires_at":now+ttl,"kind":(e or {}).get("kind","")}
    tmp=f+".tmp"; json.dump(d,open(tmp,"w")); os.replace(tmp,f); print(0)
PY
)"
  _wr_unlock; return "${rc:-1}"
}

wr_release() { # <work_id> <owner>
  _WR_ENSURE; local id="$1" owner="$2"; _wr_lock || return 0
  python3 - "$(_WR_FILE)" "$id" "$owner" <<'PY'
import json,sys,os; f,id,owner=sys.argv[1],sys.argv[2],sys.argv[3]
d=json.load(open(f))
if d.get(id,{}).get("owner")==owner:
    d.pop(id,None); tmp=f+".tmp"; json.dump(d,open(tmp,"w")); os.replace(tmp,f)
PY
  _wr_unlock; return 0
}

wr_heartbeat() { # <work_id> <owner> [ttl=1800] -> 0 extended, 1 not owner
  _WR_ENSURE; local id="$1" owner="$2" ttl="${3:-1800}" now rc; now="$(_WR_NOW)"; _wr_lock || return 1
  rc="$(python3 - "$(_WR_FILE)" "$id" "$owner" "$now" "$ttl" <<'PY'
import json,sys,os
f,id,owner,now,ttl=sys.argv[1],sys.argv[2],sys.argv[3],int(sys.argv[4]),int(sys.argv[5])
d=json.load(open(f)); e=d.get(id)
if e and e.get("owner")==owner and e.get("expires_at",0)>now:
    e["expires_at"]=now+ttl
    tmp=f+".tmp"; json.dump(d,open(tmp,"w")); os.replace(tmp,f); print(0)
else: print(1)
PY
)"
  _wr_unlock; return "${rc:-1}"
}

wr_owner() { # <work_id> -> print unexpired owner or empty
  _WR_ENSURE; local id="$1" now; now="$(_WR_NOW)"
  python3 - "$(_WR_FILE)" "$id" "$now" <<'PY'
import json,sys; f,id,now=sys.argv[1],sys.argv[2],int(sys.argv[3])
d=json.load(open(f)); e=d.get(id)
print(e["owner"] if e and e.get("expires_at",0)>now else "", end="")
PY
}

wr_gc() { _WR_ENSURE; local now; now="$(_WR_NOW)"; _wr_lock || return 0
  python3 - "$(_WR_FILE)" "$now" <<'PY'
import json,sys,os; f,now=sys.argv[1],int(sys.argv[2])
d=json.load(open(f)); tmp=f+".tmp"
json.dump({k:v for k,v in d.items() if v.get("expires_at",0)>now},open(tmp,"w")); os.replace(tmp,f)
PY
  _wr_unlock; }