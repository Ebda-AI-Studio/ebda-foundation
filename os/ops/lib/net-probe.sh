# shellcheck shell=bash
# ops/lib/net-probe.sh — "unreachable" is not "broken".
#
# WHY THIS EXISTS (measured 2026-09-16). The Mac lost network access for a
# while. SEVEN scheduled monitors then reported their targets as broken, each
# naming a different and mutually contradictory cause:
#
#   wbs-monitor      "WBS auth: login FAILED (HTTP 000) — auth is broken for all users"
#   checkout-monitor "catalogue/store-resolve FAILED"           (both live stores)
#   cf-workers-watch "could not verify the token (CF API unreachable?)"
#   deploy-drift     "Railway API query failed (check RAILWAY_API_TOKEN)"
#   services-watch   "PostHog API auth FAILED or no project — check POSTHOG_API_KEY"
#   neon-backup      "Done. 0 succeeded, 5 failed."
#
# Every service was healthy minutes later. The tell was in the same logs: the
# Telegram sends failed too — `curl: (6) Could not resolve host: api.telegram.org`,
# then a 769-second resolve timeout. The one broken thing was this Mac.
#
# THE RULE: curl exit 5/6/7/28/35/56, or %{http_code} == 000, means THIS HOST
# COULD NOT CONNECT. It is not evidence that the service is down, and it is
# never evidence that a credential is wrong. Wording like "auth is broken for
# all users" or "check RAILWAY_API_TOKEN" for a transport failure trains Ahmad
# to ignore alerts, and one local outage becomes seven contradictory pages that
# each send him hunting a different non-existent bug.
#
# Source it the way monitors already source lib/os-state.sh:
#   . "$(dirname "$0")/lib/net-probe.sh" 2>/dev/null \
#     || . "$HOME/.claude/scripts/lib/net-probe.sh" 2>/dev/null || true
#
# PRIOR ART: ops/self-heal.sh §1.5 has carried a bespoke version of the
# pre-flight since 2026-07-06, after a Mac network blip faked an FWB outage and
# would have redeployed production. That guard is latency-based (a baseline host
# must answer in <2.5s) and therefore STRICTER than host_online here, so it is
# deliberately left alone rather than refactored onto this — see Ruling M-5 in
# docs/plans/2026-09-16-monitors-unreachable-vs-broken.md.

# Curl exit codes that mean "this host could not complete a connection":
#   5  couldn't resolve proxy      6  couldn't resolve host
#   7  failed to connect          28  operation timed out
#   35 TLS handshake failure      56  failure receiving network data
# Overridable only for tests (ops/tests/net-probe.test.sh mutates it to prove
# the classifier is load-bearing).
NET_TRANSPORT_EXITS="${NET_TRANSPORT_EXITS:-5 6 7 28 35 56}"

# net_class_for <http_code> <curl_exit> -> ok | http_error | unreachable
#
# PURE: no network, no side effects — so it is unit-testable with synthesised
# exit codes. The three classes are deliberately distinct:
#   ok          2xx/3xx — the service answered as expected
#   http_error  4xx/5xx — the service ANSWERED. A 401 means auth really is
#               broken; a 500 means the service really is failing. These must
#               still fail and still page, exactly as before.
#   unreachable no HTTP status was obtained. No verdict about the service is
#               available, and none may be invented.
#
# A transport exit OUTRANKS any status that happens to be present: a probe that
# could not read an answer has not checked anything.
net_class_for() {
  _npc_code="${1:-000}"
  _npc_rc="${2:-0}"
  case "$_npc_code" in ''|*[!0-9]*) _npc_code=000 ;; esac
  case "$_npc_rc" in ''|*[!0-9]*) _npc_rc=1 ;; esac

  for _npc_e in $NET_TRANSPORT_EXITS; do
    if [ "$_npc_rc" = "$_npc_e" ]; then printf 'unreachable\n'; return 0; fi
  done
  # Any OTHER non-zero curl exit also produced no usable HTTP verdict (e.g. 60,
  # a TLS certificate problem). Report it as unreachable rather than guessing a
  # cause — when the host is online this still fails and still pages, it just
  # does not name a fault it cannot prove.
  if [ "$_npc_rc" != "0" ]; then printf 'unreachable\n'; return 0; fi

  case "$_npc_code" in
    000)     printf 'unreachable\n' ;;
    2??|3??) printf 'ok\n' ;;
    *)       printf 'http_error\n' ;;
  esac
}

# net_probe <url> [curl-args...]
#
# Runs one HTTP probe and exposes BOTH halves of the outcome to the caller:
#   NET_CLASS      ok | http_error | unreachable
#   NET_STATUS     the HTTP status (000 when none was obtained)
#   NET_CURL_EXIT  curl's exit code
#   NET_BODY       the response body, for callers that parse JSON
#
# Callers may re-interpret NET_STATUS for their own endpoint (WBS /api/health
# legitimately accepts any HTTP answer as "the API layer is up"). No caller may
# re-interpret `unreachable` as a status-based verdict — that is the entire
# point of this file.
net_probe() {
  _np_url="$1"; shift
  _np_out="$(curl -sS -m "${NET_PROBE_TIMEOUT:-20}" -w $'\n%{http_code}' "$@" "$_np_url" 2>/dev/null)"
  NET_CURL_EXIT=$?
  NET_STATUS="${_np_out##*$'\n'}"
  NET_BODY="${_np_out%$'\n'*}"
  case "$NET_STATUS" in
    ''|*[!0-9]*) NET_STATUS=000; NET_BODY='' ;;
  esac
  NET_CLASS="$(net_class_for "$NET_STATUS" "$NET_CURL_EXIT")"
  # Never leave a half-read status on an unreachable verdict — a caller that
  # forgot to check NET_CLASS must not find a plausible-looking status there.
  [ "$NET_CLASS" = unreachable ] && NET_STATUS=000
  return 0
}

# net_unreachable_note <label> [suffix]
# The ONE canonical wording for a transport failure. Says what is unknown
# instead of naming a cause.
net_unreachable_note() {
  printf '%s UNREACHABLE — no HTTP response from this Mac (curl exit %s); %s\n' \
    "$1" "${NET_CURL_EXIT:-?}" "${2:-service state UNKNOWN}"
}

# ── pre-flight ────────────────────────────────────────────────────────────────
# Is it the service, or is it MY network?
#
# BOTH defaults are hostnames on purpose. The 2026-09-16 outage killed DNS
# ("Could not resolve host: api.telegram.org"), so a pre-flight pointed at an IP
# literal (1.1.1.1) would have answered happily throughout — a gate that cannot
# fail for the exact condition it exists to detect. ops/tests/net-probe.test.sh
# asserts this with a positive control.
#
# Both targets are deliberately unrelated to anything the OS monitors, so a
# Force AI outage can never look like a local network outage.
NET_PREFLIGHT_URLS="${NET_PREFLIGHT_URLS:-https://api.github.com/ https://www.cloudflare.com/cdn-cgi/trace}"
NET_PREFLIGHT_TRIES="${NET_PREFLIGHT_TRIES:-2}"
NET_PREFLIGHT_TIMEOUT="${NET_PREFLIGHT_TIMEOUT:-5}"

# host_online — 0 = this Mac has working DNS + egress, 1 = it does not.
#
# ANY HTTP answer proves DNS and egress work, including a 404 or a 405 from a
# HEAD the server dislikes — we are testing the network, not the endpoint. Only
# a transport failure against EVERY target, on every try, means offline.
#
# Cached per process: monitors consult it from several places, and it must not
# cost a fresh pair of requests each time. Call it LAZILY — only once a probe
# has actually come back `unreachable` — so a healthy run makes zero extra
# network calls.
host_online() {
  if [ -n "${NET_HOST_ONLINE:-}" ]; then return "$NET_HOST_ONLINE"; fi
  _nho_try=1
  while [ "$_nho_try" -le "$NET_PREFLIGHT_TRIES" ]; do
    for _nho_u in $NET_PREFLIGHT_URLS; do
      if curl -sS -I -m "$NET_PREFLIGHT_TIMEOUT" -o /dev/null "$_nho_u" >/dev/null 2>&1; then
        NET_HOST_ONLINE=0
        return 0
      fi
    done
    [ "$_nho_try" -lt "$NET_PREFLIGHT_TRIES" ] && sleep 2
    _nho_try=$((_nho_try + 1))
  done
  NET_HOST_ONLINE=1
  return 1
}

# net_host_offline_report <status-job-name> <monitor-label>
#
# The ONE line a blind monitor prints, plus the state write. Deliberately does
# NOT notify (Ruling M-1): when this host has no DNS, api.telegram.org cannot be
# resolved either, so the page is undeliverable by construction — on 2026-09-16
# every send failed exactly that way, one of them after a 769-second resolve
# timeout. The blind state is recorded as `warn` for the dashboard and for
# heal-watch's staleness sweep; the next healthy run reports the truth.
net_host_offline_report() {
  _nhor_job="$1"
  _nhor_label="${2:-$1}"
  printf '%s: host offline — this Mac could not reach the network; target state unknown (monitoring blind, NOT a service outage)\n' \
    "$_nhor_label"
  if command -v write_status >/dev/null 2>&1; then
    write_status "$_nhor_job" "warn" \
      "monitoring blind — host offline (this Mac has no DNS/egress); target state unknown" \
      '{"host_offline":true}'
  fi
  return 0
}
