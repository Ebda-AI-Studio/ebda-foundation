#!/usr/bin/env bash
# anomaly-watch.sh — Whisky AI OS post-deploy anomaly detection ("did something
# that WAS working just break?").
#
# alert-triage.sh answers "what errors exist". This answers the sharper, scarier
# question: "a NEW error class just appeared / an existing one is SPIKING, and a
# deploy landed right before it" — i.e. a regression we caused, flagged LOUDLY
# and correlated to the likely commit, within minutes.
#
# Per Force Sentry project it:
#   1. Pulls issues by firstSeen desc (last 2h).
#   2. Flags BRAND-NEW error classes (firstSeen within NEW_WINDOW_MIN).
#   3. Diffs each issue's 24h event count vs the previous snapshot -> SPIKE if it
#      grew >= SPIKE_DELTA since last run.
#   4. Correlates to the most recent main-branch commit of the mapped repo (the
#      likely cause) and the newest prod deploy time when resolvable.
#   5. Alerts via notify.sh (--notify) and writes ~/.whisky-os-state/anomaly-*.json.
#
# Creds: ~/.whisky-services.env (SENTRY_AUTH_TOKEN + SENTRY_ORG). Read-only.
#
# Usage:  ops/anomaly-watch.sh            # snapshot + print
#         ops/anomaly-watch.sh --notify   # also Telegram new/spiking-since-deploy
# shellcheck source=lib/os-config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/os-config.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-config.sh" 2>/dev/null || true
command -v os_config_load >/dev/null 2>&1 && os_config_load
set -uo pipefail
# S0 (2026-10-26): --help runs nothing; one run at a time (lib/single-instance.sh)
. "$(dirname "${BASH_SOURCE[0]}")/lib/args.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/args.sh" || exit 2
. "$(dirname "${BASH_SOURCE[0]}")/lib/single-instance.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/single-instance.sh" || exit 2
args_help "${BASH_SOURCE[0]}" "$@"
single_instance anomaly-watch

# _ut (hard wall clock on external calls) lives in the shared lib — without this
# source every _ut call below would be a "command not found", i.e. the guard
# would fail silently instead of bounding anything.
. "$(dirname "$0")/lib/os-state.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-state.sh" 2>/dev/null || true

cd "$(dirname "$0")" || exit 1

SVC_ENV="${WHISKY_SERVICES_ENV:-$OS_SERVICES_ENV}"
[ -f "$SVC_ENV" ] && { set -a; . "$SVC_ENV"; set +a; }
ORG="${SENTRY_ORG:-$OS_SENTRY_ORG}"
# sentry project -> github repo (for the "likely cause" commit lookup).
# bash 3.2-safe (macOS /bin/bash has no associative arrays).
repo_of() {
  case "$1" in
    ebda-api|ebda-web|ebda-admin) echo "$OS_ORG/ebda-store" ;;
    wbs) echo "$OS_ORG/ebda-whatsapp" ;;
    *) echo "" ;;
  esac
}
PROJECTS="${SENTRY_PROJECTS:-ebda-api ebda-web ebda-admin}"
NEW_WINDOW_MIN="${ANOMALY_NEW_WINDOW_MIN:-90}"
SPIKE_DELTA="${ANOMALY_SPIKE_DELTA:-50}"
# Known-NOISE denylist — expected 4xx business rejections, third-party
# in-app-browser / marketing-pixel noise, and transient blips are NOT
# regressions and must never be flagged NEW/SPIKE. Mirrors alert-triage.sh;
# override via SENTRY_NOISE_RE in ~/.whisky-services.env.
SENTRY_NOISE_RE="${SENTRY_NOISE_RE:-Not enough inventory|INSUFFICIENT_INVENTORY|Too many .* operations|Cart item not found|MINIMUM_ORDER|already .*refunded|window\.webkit|messageHandlers|Java object is gone|invoking postMessage|reading 'parentNode'|ResizeObserver loop|top\.GLOBALS|took too long to respond|NetworkError|Failed to fetch|AbortError}"
NOTIFY=0; [ "${1:-}" = "--notify" ] && NOTIFY=1

STATE_DIR="$HOME/.whisky-os-state"; mkdir -p "$STATE_DIR"
SNAP="$STATE_DIR/anomaly-snap.json"
ALERTED="$STATE_DIR/anomaly-alerted.json"  # classes already pinged (alert-once dedup)
[ -f "$SNAP" ] || echo '{}' > "$SNAP"

if [ -z "${SENTRY_AUTH_TOKEN:-}" ]; then
  echo "anomaly-watch: SENTRY_AUTH_TOKEN not set — skipping." >&2; exit 0
fi

# latest main commit of a repo (the likely cause anchor).
head_commit() {
  _ut "$OS_UT_FAST" gh api "repos/$1/commits/main" -q '.sha[0:8] + "  " + .commit.message' 2>/dev/null | head -1
}

ALL="$(mktemp)"; NT="$(mktemp)"; trap 'rm -f "$ALL" "$NT"; si_release anomaly-watch' EXIT
echo '[]' > "$ALL"

# The python bodies live in QUOTED heredocs, never inside `python3 -c "..."`.
# Inside a double-quoted -c string bash still performs command substitution, so a
# comment that mentioned a backticked word executed it as a command: "alerted:
# command not found" x1,240 (2026-10-03) and the alert path never ran.
# Quoted heredoc = no shell expansion of the program text; data goes via env/stdin.
read -r -d '' PY_PARSE <<'PYEOF'
import sys,json,os,re
from datetime import datetime, timezone, timedelta
try: issues=json.loads(sys.stdin.read() or '[]')
except Exception: issues=[]
if not isinstance(issues,list): issues=[]
proj=os.environ['PROJ']; newmin=int(os.environ['NEWMIN'])
noise=os.environ.get('NOISE_RE','').strip()
nre=re.compile(noise,re.I) if noise else None
now=datetime.now(timezone.utc); out=[]
def parse(t):
    try: return datetime.fromisoformat(t.replace('Z','+00:00'))
    except Exception: return None
for i in issues:
    if nre and nre.search(i.get('title') or ''):   # expected/third-party - not a regression
        continue
    fs=parse(i.get('firstSeen',''))
    is_new = bool(fs and (now-fs) <= timedelta(minutes=newmin))
    out.append({'project':proj,'id':str(i.get('id')),'count':int(i.get('count',0) or 0),
                'firstSeen':(i.get('firstSeen') or '')[:19],'isNew':is_new,
                'title':(i.get('title') or '')[:90]})
print(json.dumps(out))
PYEOF
read -r -d '' PY_MERGE <<'PYEOF'
import sys,json,os
add=json.loads(sys.stdin.read() or '[]')
p=os.environ['ALL']
cur=json.load(open(p)); cur.extend(add); json.dump(cur,open(p,'w'))
PYEOF
read -r -d '' PY_DIFF <<'PYEOF'
import json,os
alli=json.load(open(os.environ['ALL'])); snap=json.load(open(os.environ['SNAP']))
delta=int(os.environ['SPIKE_DELTA'])
# alert-once dedup: a class is flagged NEW while its firstSeen is inside the
# window, so without this it re-pings every 15-min cycle (~6x per issue).
ap=os.environ['ALERTED']
try: alerted=set(json.load(open(ap)))
except Exception: alerted=set()
new=[]; spike=[]; nextsnap={}
for it in alli:
    k=it['project']+':'+it['id']; nextsnap[k]=it['count']
    if it['isNew'] and k not in alerted:
        new.append(it); alerted.add(k)
    prev=snap.get(k)
    if prev is not None and it['count']-int(prev)>=delta and ('spike:'+k) not in alerted:
        spike.append(dict(it,grew=it['count']-int(prev))); alerted.add('spike:'+k)
# GC the alert-once set so it cannot grow unbounded: keep only keys whose
# underlying issue is still in the current pull.
present=set(nextsnap.keys())
alerted={a for a in alerted if (a[6:] if a.startswith('spike:') else a) in present}
# SNAP is the comparison baseline and the alerted set is the dedupe: losing
# either turns the next run into a false-positive storm.
def _aw(p, o):
    t = p + '.tmp.%d' % os.getpid()
    with open(t, 'w') as fh: json.dump(o, fh)
    os.replace(t, p)
_aw(os.environ['SNAP'], nextsnap)
_aw(ap, sorted(alerted))
print(json.dumps({'new':new,'spike':spike}))
PYEOF
read -r -d '' PY_REPORT <<'PYEOF'
import json,os
r=json.loads(os.environ['RES'])
n=r['new']; s=r['spike']
print(f"anomaly-watch: {len(n)} NEW error class(es) in window, {len(s)} SPIKING")
for i in n: print(f"  NEW   [{i['project']}] {i['count']:>4}x since {i['firstSeen']}  {i['title'][:70]}")
for i in sorted(s,key=lambda x:-x['grew']): print(f"  SPIKE [{i['project']}] +{i['grew']} (now {i['count']})  {i['title'][:70]}")
open(os.environ['NT'],'w').write('\n'.join(
  [f"NEW [{i['project']}] {i['count']}x: {i['title'][:70]}" for i in n] +
  [f"SPIKE [{i['project']}] +{i['grew']}: {i['title'][:70]}" for i in s]))
PYEOF

for proj in $PROJECTS; do
  body=$(curl -sS -m 25 -H "Authorization: Bearer $SENTRY_AUTH_TOKEN" \
    "https://sentry.io/api/0/projects/$ORG/$proj/issues/?query=is:unresolved&statsPeriod=24h&sort=date&per_page=25" 2>/dev/null || echo '[]')
  PROJ="$proj" NEWMIN="$NEW_WINDOW_MIN" NOISE_RE="$SENTRY_NOISE_RE" python3 -c "$PY_PARSE" <<<"$body" \
    | ALL="$ALL" python3 -c "$PY_MERGE"
done

# diff vs snapshot -> NEW + SPIKE
RES="$(SPIKE_DELTA="$SPIKE_DELTA" SNAP="$SNAP" ALL="$ALL" ALERTED="$ALERTED" python3 -c "$PY_DIFF")"

RES="$RES" NT="$NT" python3 -c "$PY_REPORT"

# correlate + notify only if something fired
if [ -s "$NT" ] && { [ "$NOTIFY" = "1" ]; }; then
  CORR=""
  for proj in $PROJECTS; do
    grep -q "\[$proj\]" "$NT" || continue
    repo="$(repo_of "$proj")"; [ -n "$repo" ] || continue
    CORR+="  $proj <- $repo @ $(head_commit "$repo")"$'\n'
  done
  MSG="🚨 Anomaly-watch — possible regression (new/spiking errors):"$'\n'"$(cat "$NT")"$'\n'"likely-cause HEADs:"$'\n'"$CORR"
  [ -x ./notify.sh ] && ./notify.sh "$MSG" >/dev/null 2>&1 || echo "$MSG"
fi
echo "snapshot -> $SNAP"
