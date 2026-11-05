# shellcheck shell=bash
#
# All ledger/queue writes go through _aw() — temp + os.replace. They were
# json.dump(d, open(f,"w")): a crash or kill between the truncate and the flush
# left a zero-length remediation ledger or queue, and the next run read that as
# "no circuit-breaker history, nothing queued". queue_pop was the sharpest case:
# it printed the popped item BEFORE persisting the shortened queue, so a failed
# write handed the caller an item that was still queued.
_SD() { echo "${WHISKY_STATE_DIR:-$HOME/.whisky-os-state}"; }
_now() { echo "${NOW:-$(date +%s)}"; }
_ledger() { echo "$(_SD)/remediation-ledger.json"; }
_queue()  { echo "$(_SD)/remediation-queue.json"; }
_ensure() { mkdir -p "$(_SD)"; [ -f "$(_ledger)" ] || echo '{"actions":[],"stall":{}}' > "$(_ledger)"; [ -f "$(_queue)" ] || echo '[]' > "$(_queue)"; }

cb_record() { _ensure; local cls="$1" t; t="$(_now)"; python3 - "$(_ledger)" "$cls" "$t" <<'PY'
import os as _os
def _aw(_p,_o):
    _t="%s.tmp.%d"%(_p,_os.getpid()); open(_t,"w").write(json.dumps(_o)); _os.replace(_t,_p)
import json,sys; f,cls,t=sys.argv[1],sys.argv[2],int(sys.argv[3])
d=json.load(open(f)); d["actions"].append({"class":cls,"t":t}); _aw(f,d)
PY
}
cb_allow() { _ensure; local cls="$1" t; t="$(_now)"; python3 - "$(_ledger)" "$cls" "$t" <<'PY'
import json,sys; f,cls,t=sys.argv[1],sys.argv[2],int(sys.argv[3])
d=json.load(open(f)); win=3600 if cls=="class-a" else 86400; cap=3 if cls=="class-a" else 5
n=sum(1 for a in d["actions"] if a["class"]==cls and t-a["t"]<win)
sys.exit(0 if n<cap else 1)
PY
}
queue_add()  { _ensure; python3 - "$(_queue)" "$1" <<'PY'
import os as _os
def _aw(_p,_o):
    _t="%s.tmp.%d"%(_p,_os.getpid()); open(_t,"w").write(json.dumps(_o)); _os.replace(_t,_p)
import json,sys; f=sys.argv[1]; q=json.load(open(f)); q.append(json.loads(sys.argv[2])); _aw(f,q)
PY
}
queue_depth() { _ensure; python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$(_queue)"; }
queue_pop()   { _ensure; python3 - "$(_queue)" <<'PY'
import os as _os
def _aw(_p,_o):
    _t="%s.tmp.%d"%(_p,_os.getpid()); open(_t,"w").write(json.dumps(_o)); _os.replace(_t,_p)
import json,sys; f=sys.argv[1]; q=json.load(open(f))
print(json.dumps(q.pop(0), separators=(",",":")) if q else "", end=""); _aw(f,q)
PY
}
# macOS has no flock -> atomic mkdir lock, non-blocking.
runner_lock() { _ensure; local lock="$(_SD)/.remediation-runner.lock"
  if mkdir "$lock" 2>/dev/null; then trap 'rmdir "'"$lock"'" 2>/dev/null' RETURN; "$@"; local rc=$?; rmdir "$lock" 2>/dev/null; trap - RETURN; return $rc
  else return 1; fi
}
stall_bump() { _ensure; python3 - "$(_ledger)" "$1" <<'PY'
import os as _os
def _aw(_p,_o):
    _t="%s.tmp.%d"%(_p,_os.getpid()); open(_t,"w").write(json.dumps(_o)); _os.replace(_t,_p)
import json,sys; f,k=sys.argv[1],sys.argv[2]; d=json.load(open(f)); d["stall"][k]=d["stall"].get(k,0)+1; _aw(f,d)
PY
}
stall_over() { _ensure; python3 - "$(_ledger)" "$1" <<'PY'
import json,sys; f,k=sys.argv[1],sys.argv[2]; d=json.load(open(f)); sys.exit(0 if d["stall"].get(k,0)>2 else 1)
PY
}
pending_add() { _ensure; python3 - "$(_ledger)" "$1" "$2" <<'PY'
import os as _os
def _aw(_p,_o):
    _t="%s.tmp.%d"%(_p,_os.getpid()); open(_t,"w").write(json.dumps(_o)); _os.replace(_t,_p)
import json,sys; f,pr,item=sys.argv[1],sys.argv[2],sys.argv[3]
d=json.load(open(f)); d.setdefault("pending",{})[pr]=json.loads(item); _aw(f,d)
PY
}
pending_get() { _ensure; python3 - "$(_ledger)" "$1" <<'PY'
import json,sys; f,pr=sys.argv[1],sys.argv[2]
d=json.load(open(f)); v=d.get("pending",{}).get(pr)
print(json.dumps(v,separators=(",",":")) if v is not None else "", end="")
PY
}
pending_pop() { _ensure; python3 - "$(_ledger)" "$1" <<'PY'
import os as _os
def _aw(_p,_o):
    _t="%s.tmp.%d"%(_p,_os.getpid()); open(_t,"w").write(json.dumps(_o)); _os.replace(_t,_p)
import json,sys; f,pr=sys.argv[1],sys.argv[2]
d=json.load(open(f)); v=d.get("pending",{}).pop(pr,None); _aw(f,d)
print(json.dumps(v,separators=(",",":")) if v is not None else "", end="")
PY
}