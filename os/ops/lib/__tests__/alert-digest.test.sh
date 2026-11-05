#!/usr/bin/env bash
# Test alert-digest.py — the pure digest builder behind alert-triage.sh.
# Run: bash ops/lib/__tests__/alert-digest.test.sh
set -euo pipefail

LIB="$(cd "$(dirname "$0")/.." && pwd)"
_pass=0
_fail=0

assert_py() {
  local label="$1" pycode="$2"
  if LIB="$LIB" python3 - <<PY
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("ad", os.path.join(os.environ["LIB"], "alert-digest.py"))
ad = importlib.util.module_from_spec(spec); spec.loader.exec_module(ad)
${pycode}
PY
  then
    echo "PASS: $label"; _pass=$((_pass + 1))
  else
    echo "FAIL: $label"; _fail=$((_fail + 1))
  fi
}

# NOW is fixed so the tests never drift with the wall clock.
NOW='"2026-08-18T12:00:00Z"'

# --- ongoing_top must rank by RECENT activity, not lifetime total -------------
# This is the exact defect: FORCE-API-M had lifetime count 35 but last fired
# 2026-08-09. It outranked everything and read as a live incident for weeks.
assert_py "stale high-count issue is excluded from ongoing_top" "
stale = {'channel':'sentry','key':'sentry:ebda-api:1','count':35,'status':'unresolved',
         'title':'[ebda-api] Not allowed by CORS','last_seen':'2026-07-19T18:16:04Z'}
seen = {'sentry:ebda-api:1': {'count':35,'status':'unresolved'}}
digest, _ = ad.build_digest([stale], seen, surge_delta=5, recent_days=7, now=${NOW})
assert digest['ongoing_top'] == [], digest['ongoing_top']
"

assert_py "recently-active low-count issue is included in ongoing_top" "
fresh = {'channel':'sentry','key':'sentry:ebda-api:2','count':2,'status':'unresolved',
         'title':'[ebda-api] ZodError','last_seen':'2026-08-17T08:17:32Z'}
seen = {'sentry:ebda-api:2': {'count':2,'status':'unresolved'}}
digest, _ = ad.build_digest([fresh], seen, surge_delta=5, recent_days=7, now=${NOW})
assert [i['key'] for i in digest['ongoing_top']] == ['sentry:ebda-api:2'], digest['ongoing_top']
"

assert_py "fresh outranks stale even with a far lower count" "
stale = {'channel':'sentry','key':'stale','count':35,'status':'unresolved','title':'t',
         'last_seen':'2026-07-19T18:16:04Z'}
fresh = {'channel':'sentry','key':'fresh','count':2,'status':'unresolved','title':'t',
         'last_seen':'2026-08-17T08:17:32Z'}
seen = {'stale':{'count':35,'status':'unresolved'}, 'fresh':{'count':2,'status':'unresolved'}}
digest, _ = ad.build_digest([stale, fresh], seen, surge_delta=5, recent_days=7, now=${NOW})
assert [i['key'] for i in digest['ongoing_top']] == ['fresh'], digest['ongoing_top']
"

# --- channels without a last_seen are point-in-time signals -------------------
# uptimerobot DOWN / CI FAILURE describe the state RIGHT NOW. Treating a missing
# last_seen as 'stale' would silently drop every outage from the digest.
assert_py "event with no last_seen is treated as current" "
ci = {'channel':'ci','key':'ci-main:store','count':1,'status':'FAILURE','title':'store main red'}
seen = {'ci-main:store': {'count':1,'status':'FAILURE'}}
digest, _ = ad.build_digest([ci], seen, surge_delta=5, recent_days=7, now=${NOW})
assert [i['key'] for i in digest['ongoing_top']] == ['ci-main:store'], digest['ongoing_top']
"

assert_py "unparseable last_seen fails open into ongoing_top" "
bad = {'channel':'sentry','key':'k','count':1,'status':'unresolved','title':'t','last_seen':'not-a-date'}
seen = {'k': {'count':1,'status':'unresolved'}}
digest, _ = ad.build_digest([bad], seen, surge_delta=5, recent_days=7, now=${NOW})
assert [i['key'] for i in digest['ongoing_top']] == ['k'], digest['ongoing_top']
"

# --- surge detection must keep using LIFETIME counts --------------------------
# Period-scoped counts fall as the window slides, which would fabricate shrink
# and destroy surge detection. The recency filter must not touch this path.
assert_py "surge still fires on a lifetime-count delta for a stale-dated issue" "
it = {'channel':'sentry','key':'k','count':40,'status':'unresolved','title':'t',
      'last_seen':'2026-07-19T18:16:04Z'}
seen = {'k': {'count':35,'status':'unresolved'}}
digest, _ = ad.build_digest([it], seen, surge_delta=5, recent_days=7, now=${NOW})
assert [i['key'] for i in digest['surging']] == ['k'], digest
assert digest['surging'][0]['grew'] == 5, digest['surging']
"

assert_py "unseen key is NEW regardless of recency" "
it = {'channel':'sentry','key':'k','count':1,'status':'unresolved','title':'t',
      'last_seen':'2026-07-01T00:00:00Z'}
digest, _ = ad.build_digest([it], {}, surge_delta=5, recent_days=7, now=${NOW})
assert [i['key'] for i in digest['new']] == ['k'], digest
assert digest['ongoing_top'] == [], digest
"

assert_py "status change is CHANGED, not ongoing" "
it = {'channel':'sentry','key':'k','count':1,'status':'resolved','title':'t',
      'last_seen':'2026-08-17T00:00:00Z'}
seen = {'k': {'count':1,'status':'unresolved'}}
digest, _ = ad.build_digest([it], seen, surge_delta=5, recent_days=7, now=${NOW})
assert [i['key'] for i in digest['changed']] == ['k'], digest
"

assert_py "nextseen carries every key forward for the next run" "
evs = [{'channel':'sentry','key':'a','count':3,'status':'unresolved','title':'t'},
       {'channel':'sentry','key':'b','count':4,'status':'unresolved','title':'t'}]
_, nextseen = ad.build_digest(evs, {}, surge_delta=5, recent_days=7, now=${NOW})
assert set(nextseen) == {'a','b'}, nextseen
assert nextseen['b']['count'] == 4, nextseen
"

assert_py "ongoing_top is capped at 12" "
evs, seen = [], {}
for n in range(20):
    k = f'k{n}'
    evs.append({'channel':'sentry','key':k,'count':n,'status':'unresolved','title':'t',
                'last_seen':'2026-08-17T00:00:00Z'})
    seen[k] = {'count':n,'status':'unresolved'}
digest, _ = ad.build_digest(evs, seen, surge_delta=100, recent_days=7, now=${NOW})
assert len(digest['ongoing_top']) == 12, len(digest['ongoing_top'])
assert digest['ongoing_top'][0]['count'] == 19, digest['ongoing_top'][0]
"

echo
echo "alert-digest: PASS=$_pass FAIL=$_fail"
[ "$_fail" -eq 0 ]
