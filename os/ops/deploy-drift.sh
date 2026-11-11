#!/usr/bin/env bash
# deploy-drift.sh — detect stale / stuck prod deployments across Force services.
#
# Gap it closes (2026-06-13): prod ran a broken 06-10 build for 3 days because every
# deploy was stuck "WAITING FOR CI" (saturated runners) — the OS had no awareness that
# the running commit was days/commits behind `main`. This monitor closes that gap.
#
# What it does, per service:
#   - Compares the running deployment's commit vs the repo's `main` (or `master`) HEAD.
#   - ALERTS when the running commit is behind by >DRIFT_COMMITS commits OR >DRIFT_HOURS hours.
#   - ALERTS when the latest deployment status is stuck (WAITING_FOR_CI, FAILED, CRASHED,
#     NEEDS_APPROVAL, SKIPPED, or anything other than SUCCESS/DEPLOYING).
#   - Read-only. No mutations. Never restarts/re-deploys anything.
#
# Services monitored:
#
#   Railway (primary) — the services listed in the local config, fetched via Railway GraphQL API.
#   Token: ~/.railway/config.json → .user.accessToken (already present).
#   Alternatively: set RAILWAY_API_TOKEN in ~/.whisky-services.env.
#
#   Vercel (optional) — if VERCEL_TOKEN is set in ~/.whisky-services.env.
#   Skipped silently if the token is absent (Hobby plan token lives in keychain).
#
# Usage:  ops/deploy-drift.sh            # run + print
#         ops/deploy-drift.sh --notify   # also Telegram on failure/drift
#
# Env / config overrides (all optional):
#   DRIFT_COMMITS=5        — commits behind threshold to alert (default 5)
#   DRIFT_HOURS=6          — hours behind threshold to alert (default 6)
#   RAILWAY_API_TOKEN      — Railway API token (falls back to ~/.railway/config.json)
#   VERCEL_TOKEN           — Vercel REST API token (probe skipped if unset)
# shellcheck source=lib/os-config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/os-config.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-config.sh" 2>/dev/null || true
command -v os_config_load >/dev/null 2>&1 && os_config_load
set -uo pipefail
cd "$(dirname "$0")" || exit 1
. "$(dirname "$0")/lib/os-state.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-state.sh" 2>/dev/null || true
# drift means prod runs DIFFERENT CODE, not that its sha differs from HEAD
. "$(dirname "$0")/lib/deployable-change.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/deployable-change.sh" 2>/dev/null || true
# unreachable-vs-broken classifier + host pre-flight (2026-09-16). This monitor
# told Ahmad to "check RAILWAY_API_TOKEN" for both services during a local DNS
# outage; the token was fine.
. "$(dirname "$0")/lib/net-probe.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/net-probe.sh" 2>/dev/null || true
# FAIL LOUD if the classifier is absent — a missing gate must never fail open.
command -v net_probe >/dev/null 2>&1 || { echo "deploy-drift: FATAL — lib/net-probe.sh not found; refusing to run with unclassified probes (run ops/install.sh)" >&2; exit 2; }

NOTIFY=0; [ "${1:-}" = "--notify" ] && NOTIFY=1
FAILS=()
ALERTS=()
UNREACH=0   # probes that got NO HTTP response at all (transport failure)

DRIFT_COMMITS="${DRIFT_COMMITS:-5}"
DRIFT_HOURS="${DRIFT_HOURS:-6}"

# ── load env from whisky-services.env ─────────────────────────────────────────
SERVICES_ENV="${SERVICES_ENV:-$OS_SERVICES_ENV}"
if [ -f "$SERVICES_ENV" ]; then
  # shellcheck disable=SC1090
  . "$SERVICES_ENV"
fi

echo "deploy-drift: checking prod services"

# ── Railway token ─────────────────────────────────────────────────────────────
# Prefer explicit env var, then fall back to the Railway CLI config.
if [ -z "${RAILWAY_API_TOKEN:-}" ]; then
  RAILWAY_API_TOKEN=$(python3 -c "
import json, os
cfg = os.path.expanduser('~/.railway/config.json')
try:
    d = json.load(open(cfg))
    print(d.get('user',{}).get('accessToken') or '')
except Exception:
    print('')
" 2>/dev/null)
fi

# ── helper: GitHub commit lookup ──────────────────────────────────────────────
# Returns the sha of HEAD on the default branch for a repo slug ($OS_ORG/<repo>).
github_main_sha() {
  local slug="$1"
  local branch="${2:-master}"
  _ut "$OS_UT_FAST" gh api "repos/$slug/commits/$branch" --jq '.sha' 2>/dev/null || true
}

# ── helper: commit age in hours (via GH API commit date) ─────────────────────
# Accepts a commit sha and repo slug. Returns a float (hours since commit was authored).
commit_age_hours() {
  local sha="$1"
  local slug="$2"
  python3 -c "
import subprocess, json, sys
from datetime import datetime, timezone
try:
    result = subprocess.run(
        ['gh', 'api', 'repos/$slug/commits/$sha', '--jq', '.commit.author.date'],
        capture_output=True, text=True, timeout=20
    )
    datestr = result.stdout.strip().strip('\"')
    if not datestr:
        print(-1); sys.exit(0)
    dt = datetime.fromisoformat(datestr.replace('Z','+00:00'))
    now = datetime.now(timezone.utc)
    print(round((now - dt).total_seconds() / 3600, 1))
except Exception as e:
    print(-1)
" 2>/dev/null
}

# ── helper: how many commits behind is 'running_sha' compared to 'head_sha'? ──
commits_behind() {
  local slug="$1"
  local base="$2"   # running (older) commit
  local head="$3"   # current HEAD
  [ "$base" = "$head" ] && echo 0 && return
  # gh compare: ahead_by counts commits from base..head
  _ut "$OS_UT_FAST" gh api "repos/$slug/compare/$base...$head" --jq '.ahead_by' 2>/dev/null || echo -1
}

# ── Railway GraphQL probe ─────────────────────────────────────────────────────
# Fetches the latest SUCCESS deployment for a Railway service instance and returns
# the deployed commit hash + deployment status.
#
# Args: <service_env_id> <service_id>  (Railway requires BOTH or returns "Bad Access")
# Prints: "<commitHash> <deployedAt_iso> <status>"
# Returns: 1 if Railway API is unavailable or token is missing.
railway_latest_deploy() {
  local env_id="$1"
  local service_id="$2"
  [ -n "${RAILWAY_API_TOKEN:-}" ] || return 1

  python3 - <<PYEOF
import urllib.request, urllib.error, json, sys, os

token = os.environ.get('RAILWAY_API_TOKEN', '${RAILWAY_API_TOKEN}')
env_id = '${env_id}'
service_id = '${service_id}'
api_url = os.environ.get('RAILWAY_API_URL') or 'https://backboard.railway.app/graphql/v2'

# Railway's deployments query requires BOTH environmentId AND serviceId — an
# environmentId-only filter returns "Bad Access" (verified 2026-06-13).
# NOTE: 'meta' is a JSON SCALAR (no sub-selection); commitHash/branch/commitMessage
# live INSIDE it. The timestamp field is 'createdAt' (there is no 'deployedAt').
query = '''
query DeployDrift(\$envId: String!, \$svcId: String!) {
  deployments(
    input: {
      environmentId: \$envId
      serviceId: \$svcId
    }
    first: 5
  ) {
    edges {
      node {
        id
        status
        createdAt
        meta
      }
    }
  }
}
'''

payload = json.dumps({'query': query, 'variables': {'envId': env_id, 'svcId': service_id}}).encode()
req = urllib.request.Request(
    api_url,
    data=payload,
    headers={
        'Authorization': 'Bearer ' + token,
        'Content-Type': 'application/json',
        # backboard sits behind Cloudflare, which bans the default Python-urllib
        # User-Agent with error 1010. A browser-like UA is required (2026-06-13).
        'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36',
    }
)
try:
    with urllib.request.urlopen(req, timeout=20) as resp:
        data = json.load(resp)
    # GraphQL reports auth and query failures as HTTP 200 + an `errors` array with
    # data=null. Before 2026-10-22 that fell through to "no edges" and surfaced as
    # "deployment stuck in status=-" for weeks while the token was simply dead.
    errs = data.get('errors') or []
    if errs:
        msg = str(errs[0].get('message', 'unknown error')).replace('\n', ' ')[:120]
        print(('AUTHERROR ' if 'not authorized' in msg.lower() or 'unauthorized' in msg.lower() else 'GQLERROR ') + msg)
        sys.exit(1)
    edges = ((data.get('data') or {}).get('deployments') or {}).get('edges', [])
    if not edges:
        # status is the 3rd field the caller reads; the sentinel must sit there
        print('-  -  NO_DEPLOYMENTS')
        sys.exit(0)
    # find most recent SUCCESS or fall back to the latest of any status
    success = [e['node'] for e in edges if e['node'].get('status') == 'SUCCESS']
    latest = success[0] if success else edges[0]['node']
    sha = (latest.get('meta') or {}).get('commitHash', '')
    deployed_at = latest.get('createdAt', '-')
    status = latest.get('status', '?')
    print(sha + ' ' + deployed_at + ' ' + status)
except urllib.error.HTTPError as e:
    # Railway ANSWERED with an error status. That is attributable: a 401/403
    # really does implicate the token.
    print('HTTPERROR ' + str(e.code))
    sys.exit(1)
except (urllib.error.URLError, TimeoutError, OSError) as e:
    # DNS / connect / TLS / timeout — NO HTTP response was obtained, so this
    # says nothing about the token. Before 2026-09-16 every one of these landed
    # on "check RAILWAY_API_TOKEN".
    print('UNREACHABLE ' + str(getattr(e, 'reason', e)).replace('\n', ' ')[:120])
    sys.exit(1)
except Exception as e:
    print('ERROR  -  ' + str(e))
    sys.exit(1)
PYEOF
}

# ── Railway service check ─────────────────────────────────────────────────────
# Args: <label> <gh_repo_slug> <railway_env_id> <railway_service_id> [<default_branch>]
check_railway_service() {
  local label="$1"
  local gh_slug="$2"
  local env_id="$3"
  local service_id="$4"
  local branch="${5:-main}"

  if [ -z "${RAILWAY_API_TOKEN:-}" ]; then
    echo "  SKIP $label — RAILWAY_API_TOKEN not set"
    return
  fi

  # Get running commit from Railway
  local deploy_info deploy_rc
  deploy_info=$(RAILWAY_API_TOKEN="$RAILWAY_API_TOKEN" railway_latest_deploy "$env_id" "$service_id" 2>/dev/null)
  deploy_rc=$?
  if [ "$deploy_rc" -ne 0 ]; then
    case "$deploy_info" in
      UNREACHABLE*)
        # No HTTP response. Naming the token here is a guess, and it was the
        # wrong guess on 2026-09-16 (Ruling M-3).
        UNREACH=$((UNREACH + 1))
        FAILS+=("$label: Railway API UNREACHABLE — no HTTP response from this Mac (${deploy_info#UNREACHABLE }); deployment state UNKNOWN, NOT a token problem")
        ;;
      HTTPERROR*)
        FAILS+=("$label: Railway API returned HTTP ${deploy_info#HTTPERROR } — check RAILWAY_API_TOKEN")
        ;;
      AUTHERROR*)
        # Railway ANSWERED and rejected the token: this one really is the token.
        FAILS+=("$label: Railway rejected RAILWAY_API_TOKEN (${deploy_info#AUTHERROR }) — token expired or revoked; deployment state UNKNOWN. Create a new account token (railway.com/account/tokens) and set it in ~/.whisky-services.env")
        ;;
      GQLERROR*)
        FAILS+=("$label: Railway API answered with an error (${deploy_info#GQLERROR }); deployment state UNKNOWN")
        ;;
      *)
        FAILS+=("$label: Railway API query failed — $deploy_info")
        ;;
    esac
    return
  fi

  local running_sha; running_sha=$(printf '%s' "$deploy_info" | awk '{print $1}')
  local deployed_at; deployed_at=$(printf '%s' "$deploy_info" | awk '{print $2}')
  local deploy_status; deploy_status=$(printf '%s' "$deploy_info" | awk '{print $3}')

  # Alert on stuck deployment statuses
  case "$deploy_status" in
    SUCCESS|DEPLOYING) : ;;
    NO_DEPLOYMENTS)
      ALERTS+=("$label: no deployments found in Railway (env $env_id)")
      return
      ;;
    ERROR)
      FAILS+=("$label: Railway API error querying deployments")
      return
      ;;
    *)
      ALERTS+=("$label: deployment stuck in status=$deploy_status (env $env_id) — may be waiting for CI or failed")
      ;;
  esac

  if [ -z "$running_sha" ] || [ "$running_sha" = "-" ]; then
    ALERTS+=("$label: no commit hash in latest Railway deployment (env $env_id)")
    return
  fi

  # Get main HEAD from GitHub
  local head_sha; head_sha=$(github_main_sha "$OS_ORG/$gh_slug" "$branch")
  if [ -z "$head_sha" ]; then
    ALERTS+=("$label: could not fetch HEAD sha for $OS_ORG/$gh_slug ($branch)")
    return
  fi

  # Already up to date?
  local short_run="${running_sha:0:8}" short_head="${head_sha:0:8}"
  if [ "$running_sha" = "$head_sha" ]; then
    echo "  OK  $label — prod is at HEAD ($short_run) status=$deploy_status"
    return
  fi

  # How far behind?
  local behind; behind=$(commits_behind "$OS_ORG/$gh_slug" "$running_sha" "$head_sha")
  local age; age=$(commit_age_hours "$running_sha" "$OS_ORG/$gh_slug")

  # Check thresholds
  local over_commits=0 over_hours=0
  if [ "${behind:-0}" -gt 0 ] 2>/dev/null && [ "${behind:-0}" -ge "$DRIFT_COMMITS" ] 2>/dev/null; then
    over_commits=1
  fi
  if python3 -c "import sys; sys.exit(0 if float('${age:--1}') >= $DRIFT_HOURS else 1)" 2>/dev/null; then
    over_hours=1
  fi

  if [ "$over_commits" -eq 1 ] || [ "$over_hours" -eq 1 ]; then
    # Drift means prod is running DIFFERENT CODE, not that its sha != HEAD.
    # whatsapp sat "1 commit behind, ~68h old" for 32h over a delta of three
    # .github/workflows files — nothing deployable. Alerting on that makes the
    # only remedy a pointless prod deploy, which is how a REAL drift alert gets
    # ignored later. "unknown" is treated exactly like deployable, so a failed
    # lookup or a missing lib still alerts.
    local _verdict
    _verdict=$(changed_files "$OS_ORG/$gh_slug" "$running_sha" "$head_sha" | deployable_verdict)
    if [ "$_verdict" = "none" ]; then
      echo "  OK  $label — prod $short_run is ${behind:-?} commits / ~${age}h behind HEAD $short_head, but the delta is NON-DEPLOYABLE (CI/docs only) status=$deploy_status"
      return
    fi
    ALERTS+=("$label: DRIFT — prod running $short_run, HEAD is $short_head (${behind:-?} commits behind, running sha is ~${age}h old) status=$deploy_status")
  else
    echo "  OK  $label — prod $short_run is ${behind:-?} commits / ~${age}h behind HEAD $short_head (within threshold) status=$deploy_status"
  fi
}

# ── Vercel service check (optional) ──────────────────────────────────────────
# Only runs if VERCEL_TOKEN is set. Compares latest Vercel deployment commit vs HEAD.
check_vercel_service() {
  local label="$1"
  local project_id="$2"
  local gh_slug="$3"
  local branch="${4:-master}"

  if [ -z "${VERCEL_TOKEN:-}" ]; then
    echo "  SKIP $label (Vercel) — VERCEL_TOKEN not set"
    return
  fi

  net_probe "https://api.vercel.com/v6/deployments?projectId=$project_id&limit=1&state=READY&target=production" \
    -H "Authorization: Bearer $VERCEL_TOKEN"
  if [ "$NET_CLASS" = unreachable ]; then
    UNREACH=$((UNREACH + 1))
    FAILS+=("$(net_unreachable_note "$label (Vercel): API" 'deployment state UNKNOWN')")
    return
  fi
  local deploy="$NET_BODY"

  local running_sha; running_sha=$(printf '%s' "$deploy" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    deps = d.get('deployments', [])
    if not deps:
        print('')
    else:
        print(deps[0].get('meta', {}).get('githubCommitSha', '') or '')
except Exception:
    print('')
" 2>/dev/null)

  if [ -z "$running_sha" ]; then
    echo "  SKIP $label (Vercel) — no production deployments or no commit sha in response"
    return
  fi

  local head_sha; head_sha=$(github_main_sha "$OS_ORG/$gh_slug" "$branch")
  if [ -z "$head_sha" ]; then
    ALERTS+=("$label (Vercel): could not fetch HEAD sha for $OS_ORG/$gh_slug")
    return
  fi

  local short_run="${running_sha:0:8}" short_head="${head_sha:0:8}"
  if [ "$running_sha" = "$head_sha" ]; then
    echo "  OK  $label (Vercel) — prod at HEAD ($short_run)"
    return
  fi

  local behind; behind=$(commits_behind "$OS_ORG/$gh_slug" "$running_sha" "$head_sha")
  local age; age=$(commit_age_hours "$running_sha" "$OS_ORG/$gh_slug")

  local over_commits=0 over_hours=0
  if [ "${behind:-0}" -gt 0 ] 2>/dev/null && [ "${behind:-0}" -ge "$DRIFT_COMMITS" ] 2>/dev/null; then
    over_commits=1
  fi
  if python3 -c "import sys; sys.exit(0 if float('${age:--1}') >= $DRIFT_HOURS else 1)" 2>/dev/null; then
    over_hours=1
  fi

  if [ "$over_commits" -eq 1 ] || [ "$over_hours" -eq 1 ]; then
    ALERTS+=("$label (Vercel): DRIFT — prod $short_run, HEAD $short_head (${behind:-?} commits / ~${age}h old)")
  else
    echo "  OK  $label (Vercel) — prod $short_run is ${behind:-?} commits / ~${age}h behind (within threshold)"
  fi
}

# ── service definitions ───────────────────────────────────────────────────────
# Per-machine, never in git: ~/.ebda-os.local.json
#   "railway_services": ["<label>|<repo>|<railway env id>|<railway service id>|<branch>", ...]
#   "vercel_services":  ["<label>|<vercel project id>|<repo>|<branch>", ...]
# (see os/config/local.example.json). Nothing configured = nothing to compare (one log line, exit 0).
_configured=0
while IFS='|' read -r _label _repo _env _svc _branch; do
  [ -n "${_label:-}" ] || continue
  _configured=$((_configured + 1))
  check_railway_service "$_label" "$_repo" "$_env" "$_svc" "${_branch:-main}"
done < <(os_local_list railway_services)
while IFS='|' read -r _label _pid _repo _branch; do
  [ -n "${_label:-}" ] || continue
  _configured=$((_configured + 1))
  check_vercel_service "$_label" "$_pid" "$_repo" "${_branch:-main}"
done < <(os_local_list vercel_services)
[ "$_configured" -gt 0 ] || echo "  SKIP no railway_services / vercel_services configured in the local config"

# ── report ─────────────────────────────────────────────────────────────────────

total_fails=${#FAILS[@]}
total_alerts=${#ALERTS[@]}

# IS IT THE PLATFORMS, OR IS IT MY NETWORK? Only consulted when a probe actually
# returned no HTTP response (Ruling M-1).
if [ "$UNREACH" -gt 0 ] && ! host_online; then
  net_host_offline_report deploy-drift "deploy-drift"
  exit 0
fi

if [ "$total_fails" -gt 0 ]; then
  echo
  printf 'FAIL: %s\n' ${FAILS[@]+"${FAILS[@]}"}
fi

if [ "$total_alerts" -gt 0 ]; then
  echo
  printf 'ALERT: %s\n' ${ALERTS[@]+"${ALERTS[@]}"}
fi

if [ $(( total_fails + total_alerts )) -gt 0 ]; then
  # ${A[@]+"${A[@]}"} — under bash 3.2 (what launchd runs) `set -u` calls an
  # EMPTY array's expansion an unbound variable. Reaching here means
  # fails+alerts is non-zero, NOT that both are non-empty: the real case was 0
  # fails and 1 alert, which aborted the script right here for 32 consecutive
  # hourly runs. The whatsapp prod drift was detected and printed, then thrown away
  # before write_status — so a live drift went unreported for 32h while the job
  # looked merely stale. See lib/__tests__/empty-array-guard.test.sh.
  if [ "$NOTIFY" = "1" ]; then
    parts=()
    for f in ${FAILS[@]+"${FAILS[@]}"}; do parts+=("FAIL: $f"); done
    for a in ${ALERTS[@]+"${ALERTS[@]}"}; do parts+=("ALERT: $a"); done
    MSG="Deploy Drift detected:"$'\n'"$(printf '  - %s\n' ${parts[@]+"${parts[@]}"})"
    [ -x ./notify.sh ] && ./notify.sh "Deploy Drift" "$MSG" >/dev/null 2>&1 || echo "$MSG"
  fi
  _dd_all=(${FAILS[@]+"${FAILS[@]}"} ${ALERTS[@]+"${ALERTS[@]}"})
  DETAIL=$(printf '%s\n' "${_dd_all[@]}" | python3 -c 'import json,sys; print(json.dumps({"items":[l for l in sys.stdin.read().splitlines() if l]}))')
  write_status "deploy-drift" "false" "drift or failures detected (${#FAILS[@]} fail, ${#ALERTS[@]} alert)" "$DETAIL"
  exit 1
fi

write_status "deploy-drift" "true" "all services within drift thresholds (commits<=$DRIFT_COMMITS, hours<=$DRIFT_HOURS)" '{}'
echo "deploy-drift: all services within drift thresholds (commits<=$DRIFT_COMMITS, hours<=$DRIFT_HOURS)"
