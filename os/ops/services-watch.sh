#!/usr/bin/env bash
# Whisky AI OS — Mission Control services watch.
# Read-only. Watches COST/quota across paid infra (Neon, GitHub Actions, Vercel, Railway)
# and HEALTH signal from the free observability stack (UptimeRobot, Sentry, Axiom,
# PostHog, OneSignal). Aggregates all findings and alerts ONCE through the Whisky
# Whoop / Ebda OS bot via notify.sh. Never mutates anything.
#
# Infra probes use the already-authed CLIs (gh, vercel, railway, neonctl).
# Observability probes are token-gated: they read API keys from ~/.whisky-services.env
# and SKIP cleanly if a key is absent — so this runs today and grows as keys are added.
# shellcheck source=lib/os-config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/os-config.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-config.sh" 2>/dev/null || true
command -v os_config_load >/dev/null 2>&1 && os_config_load
set -uo pipefail
# S0 (2026-10-26): --help runs nothing; one run at a time (lib/single-instance.sh)
. "$(dirname "${BASH_SOURCE[0]}")/lib/args.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/args.sh" || exit 2
. "$(dirname "${BASH_SOURCE[0]}")/lib/single-instance.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/single-instance.sh" || exit 2
args_help "${BASH_SOURCE[0]}" "$@"
single_instance services-watch
. "$(dirname "$0")/lib/os-state.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-state.sh" 2>/dev/null || true
# unreachable-vs-broken classifier + host pre-flight (2026-09-16). This monitor
# said "PostHog API auth FAILED or no project — check POSTHOG_API_KEY" during a
# local DNS outage; the key was fine. A probe that got no HTTP response has not
# checked the credential, so it may not name one.
. "$(dirname "$0")/lib/net-probe.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/net-probe.sh" 2>/dev/null || true
# FAIL LOUD if the classifier is absent — a missing gate must never fail open.
command -v net_probe >/dev/null 2>&1 || { echo "services-watch: FATAL — lib/net-probe.sh not found; refusing to run with unclassified probes (run ops/install.sh)" >&2; exit 2; }

HERE="$(cd "$(dirname "$0")" && pwd)"
ORG="$OS_NEON_ORG"
GH_USER="$OS_ORG"
findings=()   # human-readable problem lines
skipped=()    # probes skipped for missing creds
hard=0        # count of HARD failures (a service actually unreachable / OS blind)
UNREACH=0     # probes that got NO HTTP response at all (transport failure)

note() { findings+=("$1"); }                 # soft: observability/cost signal -> warn
down() { findings+=("$1"); hard=$((hard+1)); } # hard: real outage/blindness -> down
skip() { skipped+=("$1"); }

# load optional observability tokens
SVC_ENV="${WHISKY_SERVICES_ENV:-$OS_SERVICES_ENV}"
# set -a: the env file is plain KEY=value lines. Sourced WITHOUT allexport the
# vars stay shell-local, so child processes (neonctl reads NEON_API_KEY from its
# environment) never saw them: 8/8 Neon probes "query failed" (2026-10-03).
[ -f "$SVC_ENV" ] && { set -a; . "$SVC_ENV"; set +a; }

# ---------- COST: Neon (snapshots + branch sprawl) ----------
probe_neon() {
  # Dynamic — pull live project IDs so this never drifts on a Neon migration.
  local _pids; _pids=($(neonctl projects list --org-id "$ORG" 2>/dev/null | grep -oE '[a-z]+-[a-z]+-[0-9]{8}' | sort -u))
  [ ${#_pids[@]} -eq 0 ] && _pids=(crimson-king-40424588 spring-dew-80973306 round-credit-07038192 calm-shape-31707572 green-shadow-14491887 blue-pine-81712739 wandering-sunset-94679965 round-tooth-27059226)
  for pid in "${_pids[@]}"; do
    local json; json=$(neonctl branches list --project-id "$pid" --org-id "$ORG" -o json 2>/dev/null) || { skip "neon:$pid (query failed)"; continue; }
    read -r total prod <<<"$(printf '%s' "$json" | python3 -c "import sys,json;b=json.load(sys.stdin);b=b.get('branches',b) if isinstance(b,dict) else b;p=[x for x in b if x.get('name','').startswith('prod-')];print(len(b),len(p))" 2>/dev/null)"
    [ -n "${prod:-}" ] && [ "$prod" -gt 0 ] && note "Neon $pid: $prod prod-* snapshot branch(es) (snapshots retired)"
    [ -n "${total:-}" ] && [ "$total" -gt 8 ] && note "Neon $pid: $total branches (> 8)"
  done
  for slug in ebda-store ebda-whatsapp ebda-studio digital-card; do
    local st; st=$(_ut "$OS_UT_FAST" gh api "repos/$GH_USER/$slug/actions/workflows" --jq '.workflows[]|select(.path|test("neon-snapshot"))|.state' 2>/dev/null)
    [ "$st" = "active" ] && note "neon-snapshot RE-ENABLED on $GH_USER/$slug"
  done
}

# ---------- COST: GitHub Actions minutes ----------
probe_github() {
  local j; j=$(_ut "$OS_UT_FAST" gh api "users/$GH_USER/settings/billing/actions" 2>/dev/null) || { skip "github-actions (billing scope needed on the gh token)"; return; }
  read -r used incl <<<"$(printf '%s' "$j" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('total_minutes_used',0),d.get('included_minutes',0))" 2>/dev/null)"
  [ -n "${incl:-}" ] && [ "$incl" -gt 0 ] && [ "$used" -gt $(( incl * 80 / 100 )) ] && note "GitHub Actions: ${used}/${incl} included minutes used (>80%)"
}

# ---------- COST/HEALTH: Vercel (latest prod deploy per project errored?) ----------
probe_vercel() {
  command -v vercel >/dev/null || { skip "vercel (CLI missing)"; return; }
  local out; out=$(vercel projects ls 2>/dev/null) || { skip "vercel (not authed)"; return; }
  # surface any ERROR prod deployment in the last day
  local err; err=$(vercel ls --prod 2>/dev/null | grep -ciE 'error' || true)
  [ "${err:-0}" -gt 0 ] && note "Vercel: $err errored production deployment(s) recently — check dashboard"
}

# ---------- HEALTH/COST: Railway (GraphQL — token liveness + cost estimate) ----------
# Endpoint UPTIME is already covered by UptimeRobot; this probe guards (a) that the OS
# still has Railway API visibility (a rotated/expired token = blind spot) and (b) best-effort
# month-to-date cost vs the Hobby $5 credit. Railway's billing schema shifts, so cost is
# attempted defensively — a failed cost query degrades silently, never breaks the run.
probe_railway() {
  [ -n "${RAILWAY_API_TOKEN:-}" ] || { skip "railway (set RAILWAY_API_TOKEN)"; return; }
  local api="${RAILWAY_API_URL:-https://backboard.railway.com/graphql/v2}"
  net_probe "$api" -X POST \
    -H "Authorization: Bearer ${RAILWAY_API_TOKEN}" -H "Content-Type: application/json" \
    -d '{"query":"query { me { email } }"}'
  if [ "$NET_CLASS" = unreachable ]; then
    # No HTTP response: the token has not been tested at all. "rotated/expired"
    # here was a guess, and it was wrong on 2026-09-16 (Ruling M-3). Downgraded
    # from `down` to `note` too — a blind probe is not a confirmed outage.
    UNREACH=$((UNREACH + 1))
    note "$(net_unreachable_note 'Railway API' 'Railway visibility UNKNOWN — the token has NOT been tested')"
    return
  fi
  printf '%s' "$NET_BODY" | grep -q '"email"' || { down "Railway API auth FAILED (HTTP $NET_STATUS) — RAILWAY_API_TOKEN rotated/expired (OS lost Railway visibility)"; return; }
  # best-effort month-to-date cost; tolerate schema drift
  local thr="${RAILWAY_COST_ALERT_USD:-4.0}"
  local cost; cost=$(curl -sS -m 15 -X POST "$api" \
    -H "Authorization: Bearer ${RAILWAY_API_TOKEN}" -H "Content-Type: application/json" \
    -d '{"query":"query { me { workspaces { id name } } }"}' 2>/dev/null \
    | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin); ws=d.get('data',{}).get('me',{}).get('workspaces',[])
    print(len(ws))
except Exception: print('')" 2>/dev/null)
  # workspaces reachable confirms full API access; cost figure needs the (unstable) usage query,
  # left as an opt-in via RAILWAY_WORKSPACE_ID if Ahmad wants hard cost numbers later.
  [ -z "${cost:-}" ] && note "Railway: token valid but workspace query returned nothing (schema change?)"
  return 0
}

# ---------- HEALTH: UptimeRobot (any monitor DOWN) ----------
probe_uptimerobot() {
  [ -n "${UPTIMEROBOT_API_KEY:-}" ] || { skip "uptimerobot (set UPTIMEROBOT_API_KEY)"; return; }
  net_probe "https://api.uptimerobot.com/v2/getMonitors" -X POST -d "api_key=${UPTIMEROBOT_API_KEY}&format=json"
  if [ "$NET_CLASS" = unreachable ]; then
    # Reporting "UptimeRobot DOWN: ..." from an unreadable response would invent
    # an outage out of a local network failure.
    UNREACH=$((UNREACH + 1))
    skip "uptimerobot (API unreachable from this Mac, curl exit ${NET_CURL_EXIT} — monitor state unknown)"
    return
  fi
  local j="$NET_BODY"
  local downmons; downmons=$(printf '%s' "$j" | python3 -c "import sys,json;d=json.load(sys.stdin);print('|'.join(m['friendly_name'] for m in d.get('monitors',[]) if m.get('status')==9))" 2>/dev/null)

  # Drop monitors for services that are parked on purpose. UptimeRobot keeps
  # probing a paused service from outside our infrastructure, and the API key here
  # is read-only ("not_authorized" on editMonitor), so the monitor cannot be paused
  # from this side — filtering the relay is the only lever we own. Pausing it in
  # the UptimeRobot dashboard as well stops the emails it sends directly.
  if [ -n "${downmons:-}" ]; then
    local kept="" m
    IFS='|' read -ra _mons <<< "$downmons"
    for m in "${_mons[@]}"; do
      case "$m" in
        whatsapp|msg|whatsapp\ *) service_paused msg 2>/dev/null && { skip "uptimerobot whatsapp (paused on purpose)"; continue; } ;;
      esac
      kept="${kept:+$kept|}$m"
    done
    downmons="$kept"
  fi

  [ -n "${downmons:-}" ] && down "UptimeRobot DOWN: ${downmons//|/, }"
}

# ---------- HEALTH: Sentry (unresolved issues, IMPACT-gated) ----------
# Was: degrade Mission Control whenever `age:-24h` returned anything at all, with
# no impact test. On 2026-08-18 that fired on a single 1-event / 0-user Neon
# cold-start and reported the whole board degraded. Impact scoring now lives in
# ops/lib/sentry-impact.py (tested); this function only fetches and reports.
#
# The per-ORG endpoint below genuinely honours statsPeriod, so count/userCount are
# PERIOD totals. (The per-PROJECT endpoint does NOT — see ops/alert-triage.sh.)
# Thresholds: SENTRY_MIN_USERS / SENTRY_MIN_EVENTS / SENTRY_MIN_ISSUES.
probe_sentry() {
  [ -n "${SENTRY_AUTH_TOKEN:-}" ] && [ -n "${SENTRY_ORG:-}" ] || { skip "sentry (set SENTRY_AUTH_TOKEN + SENTRY_ORG)"; return; }
  local period="${SENTRY_PERIOD:-24h}"
  local j; j=$(curl -sS -m 15 -H "Authorization: Bearer ${SENTRY_AUTH_TOKEN}" \
    "https://sentry.io/api/0/organizations/${SENTRY_ORG}/issues/?query=is:unresolved&statsPeriod=${period}" 2>/dev/null)
  local lib="$HERE/lib/sentry-impact.py"
  [ -f "$lib" ] || { skip "sentry (ops/lib/sentry-impact.py missing)"; return; }
  local out; out=$(printf '%s' "$j" | \
    SENTRY_MIN_USERS="${SENTRY_MIN_USERS:-}" \
    SENTRY_MIN_EVENTS="${SENTRY_MIN_EVENTS:-}" \
    SENTRY_MIN_ISSUES="${SENTRY_MIN_ISSUES:-}" \
    python3 "$lib" 2>/dev/null)
  local v="${out%%	*}" reason="${out#*	}"
  case "$v" in
    warn) note "$reason (${period})" ;;
    skip) skip "sentry (${reason})" ;;
    *)    : ;;   # ok — below the alert floor; deliberately not a finding
  esac
}

# ---------- HEALTH/COST: Axiom (datasets reachable + ingest signal) ----------
probe_axiom() {
  # G4 (2026-07-22 audit): Axiom is DORMANT-BY-DESIGN, not a dead channel. Sentry
  # (errors) + PostHog (product/exceptions) cover observability today, so Axiom is
  # intentionally unwired — it self-skips cleanly below until a token is set. To
  # ACTIVATE: create an Axiom API token + org id and add AXIOM_API_TOKEN /
  # AXIOM_ORG_ID to ~/.whisky-services.env (Ahmad's action — only he can mint it).
  [ -n "${AXIOM_API_TOKEN:-}" ] || { skip "axiom (dormant by design — set AXIOM_API_TOKEN + AXIOM_ORG_ID to activate)"; return; }
  local hdr_org=(); [ -n "${AXIOM_ORG_ID:-}" ] && hdr_org=(-H "X-Axiom-Org-Id: ${AXIOM_ORG_ID}")
  net_probe "https://api.axiom.co/v2/datasets" \
    -H "Authorization: Bearer ${AXIOM_API_TOKEN}" ${hdr_org[@]+"${hdr_org[@]}"}
  if [ "$NET_CLASS" = unreachable ]; then
    UNREACH=$((UNREACH + 1))
    skip "axiom (API unreachable from this Mac, curl exit ${NET_CURL_EXIT} — token NOT tested)"
    return
  fi
  local j="$NET_BODY"
  # success = a JSON array of datasets; auth failure = {"message":...} or 4xx body
  local n; n=$(printf '%s' "$j" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    if isinstance(d,list): print(len(d))
    else: print('ERR')
except Exception: print('ERR')" 2>/dev/null)
  if [ "${n:-ERR}" = "ERR" ]; then note "Axiom API auth FAILED (HTTP $NET_STATUS) — check AXIOM_API_TOKEN / AXIOM_ORG_ID"; return; fi
  # Per-dataset month-to-date ingest needs the usage API; surface only if a dataset is near the
  # free-tier ceiling once Ahmad wires AXIOM_INGEST_QUOTA_GB. For now: liveness + dataset presence.
  [ "${n:-0}" -eq 0 ] && note "Axiom: token valid but 0 datasets (nothing ingesting — is the log drain wired?)"
  return 0
}

# ---------- COST: PostHog (30-day event count vs 1M/mo free) ----------
probe_posthog() {
  [ -n "${POSTHOG_API_KEY:-}" ] || { skip "posthog (set POSTHOG_API_KEY + POSTHOG_HOST)"; return; }
  local host="${POSTHOG_HOST:-https://eu.posthog.com}"
  # resolve first project id
  net_probe "$host/api/projects/" -H "Authorization: Bearer ${POSTHOG_API_KEY}"
  if [ "$NET_CLASS" = unreachable ]; then
    # THE 2026-09-16 LINE. "check POSTHOG_API_KEY" for a transport failure sent
    # Ahmad hunting a credential that was never tested (Ruling M-3).
    UNREACH=$((UNREACH + 1))
    note "$(net_unreachable_note 'PostHog API' 'PostHog state UNKNOWN — the key has NOT been tested')"
    return
  fi
  local pid; pid=$(printf '%s' "$NET_BODY" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin); r=d.get('results',d if isinstance(d,list) else [])
    print(r[0]['id'] if r else '')
except Exception: print('')" 2>/dev/null)
  [ -z "${pid:-}" ] && { note "PostHog API auth FAILED or no project (HTTP $NET_STATUS) — check POSTHOG_API_KEY / POSTHOG_HOST"; return; }
  # 30-day event count via HogQL
  local cnt; cnt=$(curl -sS -m 25 -X POST "$host/api/projects/$pid/query/" \
    -H "Authorization: Bearer ${POSTHOG_API_KEY}" -H "Content-Type: application/json" \
    -d '{"query":{"kind":"HogQLQuery","query":"SELECT count() FROM events WHERE timestamp > now() - INTERVAL 30 DAY"}}' 2>/dev/null \
    | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin); res=d.get('results') or d.get('result') or []
    print(int(res[0][0]) if res and res[0] else 0)
except Exception: print('')" 2>/dev/null)
  [ -z "${cnt:-}" ] && { note "PostHog: query failed (HogQL shape changed?)"; return; }
  local free="${POSTHOG_FREE_EVENTS:-1000000}"
  [ "$cnt" -gt $(( free * 80 / 100 )) ] && note "PostHog: ${cnt} events/30d (>80% of ${free} free tier)"
  return 0
}

# ---------- HEALTH: OneSignal (recent push delivery failures) ----------
probe_onesignal() {
  [ -n "${ONESIGNAL_REST_API_KEY:-}" ] && [ -n "${ONESIGNAL_APP_ID:-}" ] || { skip "onesignal (set ONESIGNAL_REST_API_KEY + ONESIGNAL_APP_ID)"; return; }
  # new OneSignal auth is "Key <REST_API_KEY>"; fall back to Basic for legacy keys
  net_probe "https://api.onesignal.com/notifications?app_id=${ONESIGNAL_APP_ID}&limit=20" \
    -H "Authorization: Key ${ONESIGNAL_REST_API_KEY}"
  if [ "$NET_CLASS" = unreachable ]; then
    UNREACH=$((UNREACH + 1))
    skip "onesignal (API unreachable from this Mac, curl exit ${NET_CURL_EXIT} — key NOT tested)"
    return
  fi
  local j="$NET_BODY"
  printf '%s' "$j" | grep -q '"notifications"' || j=$(curl -sS -m 15 \
    "https://api.onesignal.com/notifications?app_id=${ONESIGNAL_APP_ID}&limit=20" \
    -H "Authorization: Basic ${ONESIGNAL_REST_API_KEY}" 2>/dev/null)
  local out; out=$(printf '%s' "$j" | python3 -c "
import sys,json,time
try:
    d=json.load(sys.stdin); ns=d.get('notifications')
    if ns is None: print('AUTH'); sys.exit()
    cutoff=time.time()-86400; failed=0; total=0
    for n in ns:
        ca=n.get('completed_at') or n.get('queued_at') or 0
        if ca and ca>=cutoff:
            failed+=int(n.get('failed',0) or 0); total+=int(n.get('successful',0) or 0)+int(n.get('failed',0) or 0)
    print(f'{failed} {total}')
except Exception: print('ERR')" 2>/dev/null)
  case "${out:-ERR}" in
    AUTH) note "OneSignal API auth FAILED — check ONESIGNAL_REST_API_KEY / ONESIGNAL_APP_ID" ;;
    ERR|"") note "OneSignal: query failed (API shape changed?)" ;;
    *) local f="${out%% *}" t="${out##* }"
       [ "${f:-0}" -gt 0 ] && [ "${t:-0}" -gt 0 ] && [ "$f" -gt $(( t * 10 / 100 )) ] \
         && note "OneSignal: ${f}/${t} push deliveries FAILED in 24h (>10%)" ;;
  esac
  return 0
}

# The probe list is overridable ONLY so tests can exercise one probe in
# isolation; the default is every probe, exactly as before.
# A probe "ran" only if it added no skip note. The old summary subtracted the
# number of skip NOTES (one per Neon project) from a fixed 9, which went negative
# ("checked -2/9") and could not tell "9 probes OK" from "0 probes ran".
probes_total=0; probes_ran=0
for p in ${SERVICES_WATCH_PROBES:-probe_neon probe_github probe_vercel probe_railway probe_uptimerobot probe_sentry probe_axiom probe_posthog probe_onesignal}; do
  _skips_before=${#skipped[@]}
  "$p"
  probes_total=$((probes_total+1))
  [ ${#skipped[@]} -eq "$_skips_before" ] && probes_ran=$((probes_ran+1))
done

# IS IT THE SERVICES, OR IS IT MY NETWORK? Only consulted when a probe actually
# returned no HTTP response, so a healthy run pays nothing. If this Mac has no
# DNS/egress, every finding above is an artefact of the local outage: report ONE
# blind line and do NOT page (Ruling M-1).
if [ "$UNREACH" -gt 0 ] && ! host_online; then
  net_host_offline_report services "services-watch"
  exit 0
fi

# An all-skipped run checked NOTHING; reporting it OK is a monitor that fails open.
if [ "$probes_total" -gt 0 ] && [ "$probes_ran" -eq 0 ]; then
  down "services-watch is BLIND: all ${probes_total} probes skipped, nothing was checked (${skipped[*]:-no reason recorded})"
fi
summary="checked ${probes_ran}/${probes_total} service probes; ${#skipped[@]} skip note(s)"
if [ ${#findings[@]} -eq 0 ]; then
  echo "[services-watch] OK — no cost/health violations. $summary"
  [ ${#skipped[@]} -gt 0 ] && printf '  skipped: %s\n' ${skipped[@]+"${skipped[@]}"}
  write_status "services" "true" "no cost/health violations. $summary" '{}'
  exit 0
fi

# ---------- a pause that stopped holding ----------
# Enumerating wakers does not scale. 2026-08-09: merging PRs to main triggered
# RAILWAY GITHUB AUTO-DEPLOY, which rebuilt both "paused" whatsapp services while the
# marker still read PAUSED and every watcher stayed silent — the pause was undone
# and nothing said so. Railway's CLI has no auto-deploy switch, so prevention
# isn't available from here; enforce the INVARIANT instead.
#
# While the marker exists the API must not answer. Any waker — auto-deploy, a
# manual redeploy, a resume that forgot the marker — trips this on the next run.
# Counts as HARD: a pause silently not holding is the cost problem returning
# under a green dashboard.
if service_paused msg 2>/dev/null && [ -x "$HERE/msg-power.sh" ]; then
  if ! bash "$HERE/msg-power.sh" enforce >/dev/null 2>&1; then
    down "whatsapp is marked PAUSED but its API is answering — the pause is NOT holding. Known cause: Railway GitHub auto-deploy on a push to main (any merge does it). Re-pause: ops/msg-power.sh pause — or if it was resumed deliberately, ops/msg-power.sh resume (clears the marker + SERVICE_PAUSED so CI smoke tests run again)."
  fi
fi

# Severity: a real outage/blindness (hard) => down; observability/cost signal only => warn.
if [ "$hard" -gt 0 ]; then sev="false"; word="DOWN"; else sev="warn"; word="degraded"; fi
msg="⚠️ Mission Control — ${#findings[@]} issue(s) [$word]:"$'\n'"$(printf '  • %s\n' ${findings[@]+"${findings[@]}"})"
echo "$msg"
"$HERE/notify.sh" "Mission Control" "$msg" >/dev/null 2>&1 || true
DETAIL=$(printf '%s\n' ${findings[@]+"${findings[@]}"} | python3 -c 'import json,sys; print(json.dumps({"items":[l for l in sys.stdin.read().splitlines() if l]}))')
write_status "services" "$sev" "${#findings[@]} cost/health issue(s) detected [$word]" "$DETAIL"
[ "$hard" -gt 0 ] && exit 1 || exit 0
