#!/usr/bin/env bash
# Test sentry-impact.py — the impact gate behind services-watch.sh probe_sentry.
# Run: bash ops/lib/__tests__/sentry-impact.test.sh
set -euo pipefail

LIB="$(cd "$(dirname "$0")/.." && pwd)"
_pass=0
_fail=0

assert_py() {
  local label="$1" pycode="$2"
  if LIB="$LIB" python3 - <<PY
import importlib.util, os
spec = importlib.util.spec_from_file_location("si", os.path.join(os.environ["LIB"], "sentry-impact.py"))
si = importlib.util.module_from_spec(spec); spec.loader.exec_module(si)
def issue(events=1, users=0, short="X-1", title="boom"):
    return {"shortId": short, "count": events, "userCount": users, "title": title}
${pycode}
PY
  then
    echo "PASS: $label"; _pass=$((_pass + 1))
  else
    echo "FAIL: $label"; _fail=$((_fail + 1))
  fi
}

# --- the exact case that degraded Mission Control on 2026-08-18 ---------------
# FORCE-API-26: a Neon autosuspend cold-start. 1 event, 0 users, never repeated.
# The old probe degraded the whole board on len(issues) > 0.
assert_py "single 1-event 0-user issue is ok (the 2026-08-18 false alarm)" "
v, reason = si.verdict([issue(events=1, users=0)])
assert v == 'ok', (v, reason)
"

assert_py "no issues at all is ok" "
v, reason = si.verdict([])
assert v == 'ok', (v, reason)
assert 'no' in reason.lower(), reason
"

# --- real impact must still warn ---------------------------------------------
assert_py "any affected user warns even at 1 event" "
v, reason = si.verdict([issue(events=1, users=2)])
assert v == 'warn', (v, reason)
assert '2 user' in reason, reason
"

assert_py "high event volume warns even with 0 users" "
v, reason = si.verdict([issue(events=25, users=0)])
assert v == 'warn', (v, reason)
assert '25' in reason, reason
"

assert_py "several distinct issues warn even when each is trivial" "
v, reason = si.verdict([issue(short='A'), issue(short='B'), issue(short='C')])
assert v == 'warn', (v, reason)
"

assert_py "two trivial issues stay ok (below the issue-count floor)" "
v, reason = si.verdict([issue(short='A'), issue(short='B')])
assert v == 'ok', (v, reason)
"

assert_py "thresholds are overridable" "
v, _ = si.verdict([issue(events=5)], min_events=4)
assert v == 'warn', v
v, _ = si.verdict([issue(events=5)], min_events=99, min_issues=99, min_users=99)
assert v == 'ok', v
"

# --- the reason must name the worst offender so the alert is actionable ------
assert_py "reason names the worst issue by events" "
v, reason = si.verdict([issue(events=2, short='SMALL'), issue(events=30, short='BIG'), issue(events=1, short='TINY')])
assert v == 'warn', (v, reason)
assert 'BIG' in reason, reason
assert 'SMALL' not in reason, reason
"

# --- a broken API response must be VISIBLE, never silently green -------------
assert_py "unparseable payload is skip, not ok" "
v, reason = si.verdict('not-a-list')
assert v == 'skip', (v, reason)
v, reason = si.verdict(None)
assert v == 'skip', (v, reason)
"

assert_py "a Sentry error object is skip, not ok" "
v, reason = si.verdict({'detail': 'Invalid token'})
assert v == 'skip', (v, reason)
"

assert_py "missing count/userCount fields are treated as zero, not crash" "
v, reason = si.verdict([{'shortId': 'A', 'title': 't'}])
assert v == 'ok', (v, reason)
"

# --- CLI contract used by services-watch.sh ----------------------------------
out=$(printf '[{"shortId":"A","count":50,"userCount":0,"title":"boom"}]' | python3 "$LIB/sentry-impact.py")
if [ "${out%%	*}" = "warn" ]; then echo "PASS: CLI emits verdict<TAB>reason"; _pass=$((_pass+1));
else echo "FAIL: CLI emits verdict<TAB>reason (got: $out)"; _fail=$((_fail+1)); fi

out=$(printf 'garbage' | python3 "$LIB/sentry-impact.py")
if [ "${out%%	*}" = "skip" ]; then echo "PASS: CLI reports skip on garbage stdin"; _pass=$((_pass+1));
else echo "FAIL: CLI reports skip on garbage stdin (got: $out)"; _fail=$((_fail+1)); fi

# --- the documented env knobs must actually be read (not decorative) ---------
out=$(printf '[{"shortId":"A","count":5,"userCount":0,"title":"t"}]' | SENTRY_MIN_EVENTS=4 python3 "$LIB/sentry-impact.py")
if [ "${out%%	*}" = "warn" ]; then echo "PASS: SENTRY_MIN_EVENTS lowers the floor"; _pass=$((_pass+1));
else echo "FAIL: SENTRY_MIN_EVENTS lowers the floor (got: $out)"; _fail=$((_fail+1)); fi

out=$(printf '[{"shortId":"A","count":50,"userCount":0,"title":"t"}]' | SENTRY_MIN_EVENTS=999 SENTRY_MIN_ISSUES=999 SENTRY_MIN_USERS=999 python3 "$LIB/sentry-impact.py")
if [ "${out%%	*}" = "ok" ]; then echo "PASS: env knobs can raise the floor"; _pass=$((_pass+1));
else echo "FAIL: env knobs can raise the floor (got: $out)"; _fail=$((_fail+1)); fi

out=$(printf '[{"shortId":"A","count":50,"userCount":0,"title":"t"}]' | SENTRY_MIN_EVENTS=oops python3 "$LIB/sentry-impact.py")
if [ "${out%%	*}" = "warn" ]; then echo "PASS: garbage env falls back to the default"; _pass=$((_pass+1));
else echo "FAIL: garbage env falls back to the default (got: $out)"; _fail=$((_fail+1)); fi

out=$(printf '[{"shortId":"A","count":1,"userCount":0,"title":"t"}]' | SENTRY_MIN_EVENTS= python3 "$LIB/sentry-impact.py")
if [ "${out%%	*}" = "ok" ]; then echo "PASS: blank env (unset passthrough) falls back"; _pass=$((_pass+1));
else echo "FAIL: blank env (unset passthrough) falls back (got: $out)"; _fail=$((_fail+1)); fi

echo
echo "sentry-impact: PASS=$_pass FAIL=$_fail"
[ "$_fail" -eq 0 ]
