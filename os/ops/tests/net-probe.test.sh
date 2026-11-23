#!/usr/bin/env bash
# ops/lib/net-probe.sh — unit suite.
#
# The defect this guards (measured 2026-09-16): the Mac lost network access and
# SEVEN monitors reported their targets as broken — "whatsapp auth: login FAILED
# (HTTP 000) — auth is broken for all users", "check RAILWAY_API_TOKEN",
# "PostHog API auth FAILED". Every service was healthy. curl exit 6/7/28 and
# http_code 000 mean THIS HOST could not connect; they are not evidence about
# the service and never evidence about a credential.
#
# The classifier half is pure and runs with NO network at all (exit codes are
# synthesised). The live half uses only 127.0.0.1: a closed port (guaranteed
# ECONNREFUSED -> curl exit 7) and a local fixture server. Nothing here can
# reach production or Telegram.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1   # -> ops/
OPS="$(pwd)"

TMP="$(mktemp -d)"
SERVER_PID=""
cleanup() { [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

_pass=0; _fail=0
pass() { echo "PASS: $1"; _pass=$((_pass+1)); }
fail() { echo "FAIL: $1"; _fail=$((_fail+1)); }

# shellcheck source=/dev/null
. "$OPS/lib/net-probe.sh" || { echo "FAIL: cannot source ops/lib/net-probe.sh"; exit 1; }

# ============ 1. net_class_for — the pure classifier, zero network ============
# form: <http_code> <curl_exit> <expected class>
CASES='
200 0 ok
201 0 ok
204 0 ok
301 0 ok
302 0 ok
308 0 ok
400 0 http_error
401 0 http_error
403 0 http_error
404 0 http_error
500 0 http_error
502 0 http_error
503 0 http_error
000 0 unreachable
000 5 unreachable
000 6 unreachable
000 7 unreachable
000 28 unreachable
000 35 unreachable
000 56 unreachable
000 60 unreachable
200 7 unreachable
200 28 unreachable
401 6 unreachable
'
cls_fails=0
while read -r code rc want; do
  [ -n "${code:-}" ] || continue
  got="$(net_class_for "$code" "$rc")"
  if [ "$got" != "$want" ]; then
    echo "   net_class_for($code,$rc) = '$got', want '$want'"
    cls_fails=$((cls_fails+1))
  fi
done <<EOF
$CASES
EOF
if [ "$cls_fails" -eq 0 ]; then
  pass "net_class_for classifies every status/exit pair correctly (24 cases, no network)"
else
  fail "net_class_for: $cls_fails case(s) misclassified"
fi

# A transport exit must WIN over any status that happens to be present. A probe
# that could not read an answer has not checked anything.
[ "$(net_class_for 200 7)" = unreachable ] \
  && pass "a transport exit outranks a status (200 + exit 7 is NOT 'ok')" \
  || fail "200 + curl exit 7 must be unreachable, got $(net_class_for 200 7)"

# Garbage/empty http_code must never become a status verdict.
[ "$(net_class_for '' 0)" = unreachable ] \
  && pass "empty http_code is unreachable, never 'ok'" \
  || fail "empty http_code must be unreachable"

# ============ 2. net_probe against a CLOSED local port (curl exit 7) ============
net_probe "http://127.0.0.1:1/anything"
if [ "$NET_CLASS" = unreachable ] && [ "$NET_STATUS" = "000" ] && [ "$NET_CURL_EXIT" != "0" ]; then
  pass "net_probe on a closed port -> unreachable (status 000, curl exit $NET_CURL_EXIT)"
else
  fail "closed port: class=$NET_CLASS status=$NET_STATUS exit=$NET_CURL_EXIT (want unreachable/000/non-zero)"
fi

# The curl exit code must be EXPOSED to callers — a monitor cannot word its
# message correctly without it.
[ -n "${NET_CURL_EXIT:-}" ] \
  && pass "net_probe exposes the curl exit code to callers" \
  || fail "NET_CURL_EXIT was not set"

# ============ 3. net_probe against a live local fixture ============
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
python3 "$OPS/tests/fixtures/fake-http-api.py" "$PORT" healthy > "$TMP/server.log" 2>&1 &
SERVER_PID=$!
disown 2>/dev/null || true   # keep bash job control from printing "Terminated" on cleanup
up=0
for _ in $(seq 1 50); do
  curl -sS -m 1 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && { up=1; break; }
  sleep 0.1
done
[ "$up" -eq 1 ] || { echo "FAIL: fake HTTP fixture never came up: $(cat "$TMP/server.log")"; exit 1; }

net_probe "http://127.0.0.1:$PORT/health"
if [ "$NET_CLASS" = ok ] && [ "$NET_STATUS" = "200" ]; then
  pass "net_probe on a healthy endpoint -> ok (200)"
else
  fail "healthy endpoint: class=$NET_CLASS status=$NET_STATUS (want ok/200)"
fi
grep -q '"status": "healthy"' < <(printf '%s' "$NET_BODY") \
  && pass "net_probe captures the response body for callers that parse it" \
  || fail "NET_BODY did not carry the JSON body: '$NET_BODY'"

# A REAL error status is http_error — the service answered. This is the half
# that must keep paging: it is not a transport problem.
net_probe "http://127.0.0.1:$PORT/api/health"
if [ "$NET_CLASS" = http_error ] && [ "$NET_STATUS" = "401" ]; then
  pass "a real 401 is http_error (service answered) — not unreachable"
else
  fail "401 endpoint: class=$NET_CLASS status=$NET_STATUS (want http_error/401)"
fi

net_probe "http://127.0.0.1:$PORT/nope"
[ "$NET_CLASS" = http_error ] && [ "$NET_STATUS" = "404" ] \
  && pass "a real 404 is http_error (service answered)" \
  || fail "404 endpoint: class=$NET_CLASS status=$NET_STATUS"

# ============ 4. host_online pre-flight ============
# ONLINE: any HTTP answer from the pre-flight target proves DNS+egress. The
# fixture 404s this path on purpose — a 404 still proves the host can connect.
( NET_PREFLIGHT_URLS="http://127.0.0.1:$PORT/preflight-probe" \
  NET_PREFLIGHT_TRIES=1 NET_PREFLIGHT_TIMEOUT=3 \
  bash -c ". '$OPS/lib/net-probe.sh'; host_online" )
if [ $? -eq 0 ]; then
  pass "host_online: a reachable endpoint (even a 404) reports ONLINE"
else
  fail "host_online reported offline against a live local fixture"
fi

# OFFLINE: every pre-flight target refuses the connection.
( NET_PREFLIGHT_URLS="http://127.0.0.1:1/a http://127.0.0.1:2/b" \
  NET_PREFLIGHT_TRIES=1 NET_PREFLIGHT_TIMEOUT=2 \
  bash -c ". '$OPS/lib/net-probe.sh'; host_online" )
if [ $? -ne 0 ]; then
  pass "host_online: all pre-flight targets unreachable reports OFFLINE"
else
  fail "host_online reported online while every pre-flight target was closed"
fi

# The verdict is cached per process (monitors call it from several places).
CACHED=$( NET_PREFLIGHT_URLS="http://127.0.0.1:$PORT/preflight-probe" \
  NET_PREFLIGHT_TRIES=1 NET_PREFLIGHT_TIMEOUT=3 \
  bash -c ". '$OPS/lib/net-probe.sh'
    host_online || exit 1
    NET_PREFLIGHT_URLS='http://127.0.0.1:1/gone'
    host_online && echo cached" )
[ "$CACHED" = "cached" ] \
  && pass "host_online caches its verdict for the process" \
  || fail "host_online did not cache (re-probed and flipped)"

# ============ 5. POSITIVE CONTROL on the pre-flight default ============
# The 2026-09-16 outage killed DNS ("Could not resolve host: api.telegram.org").
# A pre-flight whose default targets are IP literals would answer happily during
# exactly that outage — a gate that cannot fail. Every default MUST be a
# hostname, so DNS failure is detectable.
bad=0
for u in $NET_PREFLIGHT_URLS; do
  host="${u#*://}"; host="${host%%/*}"; host="${host%%:*}"
  case "$host" in
    *[0-9].[0-9]*) case "$host" in *[a-zA-Z]*) ;; *) echo "   IP-literal default target: $u"; bad=1 ;; esac ;;
  esac
done
[ "$bad" -eq 0 ] \
  && pass "every default pre-flight target is a hostname (DNS failure is detectable)" \
  || fail "a default pre-flight target is an IP literal — DNS loss would go undetected"

echo
echo "net-probe: $_pass passed, $_fail failed"
[ "$_fail" -eq 0 ]
