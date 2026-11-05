#!/usr/bin/env bash
# Whisky AI OS — Cloudflare Workers/Pages deployment + health watch.
# Read-only. Detects NEW deployments per Force Worker/Pages project (so Ahmad gets a
# Telegram ping about WHAT got deployed) and health-checks each live domain. Alerts
# ONCE via notify.sh and records Mission Control state via write_status. Never mutates CF.
#
# Auth: reuses the wrangler OAuth token (already authed). Account fixed below.
# State: ~/.claude/state/cf-deploys.json (last-seen deployment id per target).
# Daily/interval via launchd: ~/Library/LaunchAgents/com.ebda.os.cf-workers-watch.plist
# Manual: bash ~/.claude/scripts/cf-workers-watch.sh
set -uo pipefail
# S0 (2026-10-26): --help runs nothing; one run at a time (lib/single-instance.sh)
. "$(dirname "${BASH_SOURCE[0]}")/lib/args.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/args.sh" || exit 2
. "$(dirname "${BASH_SOURCE[0]}")/lib/single-instance.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/single-instance.sh" || exit 2
args_help "${BASH_SOURCE[0]}" "$@"
single_instance cf-workers-watch
. "$(dirname "$0")/lib/os-state.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-state.sh" 2>/dev/null || true
# unreachable-vs-broken classifier + host pre-flight (2026-09-16)
. "$(dirname "$0")/lib/net-probe.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/net-probe.sh" 2>/dev/null || true
# FAIL LOUD if the classifier is absent — a missing gate must never fail open.
command -v net_probe >/dev/null 2>&1 || { echo "cf-workers-watch: FATAL — lib/net-probe.sh not found; refusing to run with unclassified probes (run ops/install.sh)" >&2; exit 2; }

HERE="$(cd "$(dirname "$0")" && pwd)"
ACC="9f70414f9a626137f1004fa2f4add904"
# Overridable so tests can point at a local fixture; default is unchanged.
CF_API_BASE="${CF_API_BASE:-https://api.cloudflare.com/client/v4}"
# Prefer a STABLE CF API token over the short-lived wrangler OAuth token (which
# expires every few hours and made this monitor false-alarm 6x). Order: env var,
# then ~/.whisky-services.env (CF_API_TOKEN=...), then the wrangler oauth fallback.
TKN="${CF_API_TOKEN:-}"
[ -z "$TKN" ] && [ -f "${OS_SERVICES_ENV:-$HOME/.whisky-services.env}" ] && TKN="$(grep -E '^CF_API_TOKEN=' "${OS_SERVICES_ENV:-$HOME/.whisky-services.env}" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"')"
[ -z "$TKN" ] && TKN="$(grep -E '^oauth_token' "$HOME/Library/Preferences/.wrangler/config/default.toml" 2>/dev/null | sed -E 's/.*= *"?([^"]+)"?/\1/')"
STATE_DIR="$HOME/.claude/state"; STATE="$STATE_DIR/cf-deploys.json"
mkdir -p "$STATE_DIR"; [ -f "$STATE" ] || echo '{}' >"$STATE"

findings=()
note() { findings+=("$1"); }
api() { curl -sS -m 20 "$CF_API_BASE/$1" -H "Authorization: Bearer $TKN" 2>/dev/null; }

if [ -z "$TKN" ]; then
  echo "[cf-workers-watch] no CF token — cannot query CF"; write_status "cf-workers" "false" "no CF token" '{}' 2>/dev/null; exit 1
fi

# Auth probe — RETRY before alerting (a single transient CF/network blip must not
# false-alarm "token expired"; 2026-07-06 the token was verified active + working
# yet a one-off failure fired the alert). 3 tries, 5s apart, then fail once.
auth_ok=0; auth_unreach=0
_cf_tries="${CF_WATCH_RETRIES:-3}"; _cf_sleep="${CF_WATCH_RETRY_SLEEP:-5}"
_try=1
while [ "$_try" -le "$_cf_tries" ]; do
  net_probe "$CF_API_BASE/accounts/$ACC/workers/scripts?per_page=1" -H "Authorization: Bearer $TKN"
  if [ "$NET_CLASS" = unreachable ]; then
    auth_unreach=1
  else
    auth_unreach=0
    printf '%s' "$NET_BODY" | grep -qE '"success":[[:space:]]*true' && { auth_ok=1; break; }
  fi
  _try=$((_try + 1))
  [ "$_try" -le "$_cf_tries" ] && sleep "$_cf_sleep"
done
if [ "$auth_ok" = 0 ]; then
  # IS IT CLOUDFLARE, OR IS IT MY NETWORK? Ask this BEFORE the token-verify
  # branch below, because that branch's own probe uses the same dead network and
  # its "could not verify the token" wording sent Ahmad hunting a credential bug
  # during a local DNS outage on 2026-09-16.
  if [ "$auth_unreach" = 1 ]; then
    if ! host_online; then
      net_host_offline_report cf-workers "cf-workers-watch"
      exit 0
    fi
    # Host is fine, CF is not answering this Mac at all — still a real finding,
    # but it is NOT a token problem and must not be described as one.
    msg="$(net_unreachable_note '⚠️ CF monitor: the Cloudflare API' 'Workers state UNKNOWN. This is NOT a token problem — check https://www.cloudflarestatus.com')"
    echo "[cf-workers-watch] $msg"
    "$HERE/notify.sh" "Cloudflare Workers" "$msg" >/dev/null 2>&1 || true
    write_status "cf-workers" "false" "CF API unreachable from this host (host network verified OK)" '{}' 2>/dev/null
    exit 1
  fi
  # NEVER assert "expired" without checking. 2026-07-31: this alert fired twice,
  # claimed the token had expired, and self-recovered on the next run — the token
  # was verified ACTIVE and all four workers readable minutes later. Ahmad had set
  # no expiry, so the message sent him hunting a credential bug that did not exist.
  # /user/tokens/verify answers "is this token actually dead?" definitively in one
  # call, so ask it before naming a cause. (Same root mistake as the 2026-07-06
  # false alarm the retry loop above was added for: the retry reduced frequency but
  # left the diagnosis unverified.)
  tok_status=$(curl -sS -m 20 "https://api.cloudflare.com/client/v4/user/tokens/verify" \
    -H "Authorization: Bearer $TKN" 2>/dev/null |
    python3 -c "import json,sys
try:
 d=json.load(sys.stdin); print((d.get('result') or {}).get('status','') if d.get('success') else 'invalid')
except Exception: print('unknown')" 2>/dev/null)

  case "$tok_status" in
    active)
      # Token is provably fine → the read failure is CF-side or network, and there
      # is nothing for Ahmad to fix. Report it as transient, do NOT blame the token.
      msg="⚠️ CF monitor: could not read Workers after 3 tries, but the token verifies as ACTIVE — treating as a transient CF API/network issue. No action needed unless this repeats."
      echo "[cf-workers-watch] $msg"
      "$HERE/notify.sh" "Cloudflare Workers" "$msg" >/dev/null 2>&1 || true
      write_status "cf-workers" "false" "CF API unreachable (token verified active)" '{}' 2>/dev/null
      ;;
    invalid | expired | disabled)
      msg="⚠️ CF monitor: token is $tok_status (verified via /user/tokens/verify). Fix: set a fresh CF_API_TOKEN (Workers Scripts:Read) in ~/.whisky-services.env, or run 'wrangler login'."
      echo "[cf-workers-watch] $msg"
      "$HERE/notify.sh" "Cloudflare Workers" "$msg" >/dev/null 2>&1 || true
      write_status "cf-workers" "false" "CF token $tok_status (verified)" '{}' 2>/dev/null
      ;;
    *)
      # Reaching here means CF DID answer over HTTP (a transport failure exits
      # above), so the old "(CF API unreachable?)" guess no longer applies: the
      # read failed and the verify endpoint gave an unrecognised answer.
      msg="⚠️ CF monitor: could not read Workers after ${_cf_tries} tries, and /user/tokens/verify returned an unrecognised status ('${tok_status}'). The CF API IS reachable from this Mac. Check https://www.cloudflarestatus.com before touching the token."
      echo "[cf-workers-watch] $msg"
      "$HERE/notify.sh" "Cloudflare Workers" "$msg" >/dev/null 2>&1 || true
      write_status "cf-workers" "false" "CF API + token verify both unreachable" '{}' 2>/dev/null
      ;;
  esac
  exit 1
fi

# friendly:script  (Workers) and friendly:pages:project (Pages). The targets are per-machine: set CF_WATCH_TARGETS to a
# space-separated list in $OS_SERVICES_ENV (no worker names live in the repo). Empty = nothing to watch.
read -r -a TARGETS <<< "${CF_WATCH_TARGETS:-}"
if [ "${#TARGETS[@]}" -eq 0 ]; then
  echo "[cf-workers-watch] CF_WATCH_TARGETS is empty - no workers to watch"
  exit 0
fi

get_state() { python3 -c "import json,sys; d=json.load(open('$STATE')); print(d.get('$1',''))" 2>/dev/null; }
set_state() { python3 -c "import json; d=json.load(open('$STATE')); d['$1']='$2'; json.dump(d,open('$STATE','w'))" 2>/dev/null; }

for entry in "${TARGETS[@]}"; do
  name="${entry%%:*}"; rest="${entry#*:}"
  if [ "${rest%%:*}" = "pages" ]; then
    proj="${rest#pages:}"
    j=$(api "accounts/$ACC/pages/projects/$proj/deployments?per_page=1")
    # The CF_API_TOKEN may lack Pages:Read (it has Workers:Read). Don't false-alarm
    # on that — skip Pages targets quietly until Pages:Read is added to the token.
    if printf '%s' "$j" | grep -q '"code":10000'; then
      echo "[cf-workers-watch] $name: Pages read needs 'Cloudflare Pages:Read' on CF_API_TOKEN — skipping"; continue
    fi
    read -r did when meta <<<"$(printf '%s' "$j" | python3 -c "import sys,json
try:
 r=json.load(sys.stdin)['result'][0]; print(r['id'], r.get('created_on','?'), (r.get('deployment_trigger',{}).get('metadata',{}) or {}).get('commit_hash','')[:7] or 'manual')
except Exception: print('','','')" 2>/dev/null)"
    label="Pages"
  else
    script="$rest"
    j=$(api "accounts/$ACC/workers/scripts/$script/deployments")
    read -r did when meta <<<"$(printf '%s' "$j" | python3 -c "import sys,json
try:
 r=json.load(sys.stdin)['result']; d=(r.get('deployments') if isinstance(r,dict) else r)[0]; print(d['id'], d.get('created_on','?'), d.get('author_email','?').split('@')[0])
except Exception: print('','','')" 2>/dev/null)"
    label="Worker"
  fi
  # Don't speculate about the cause here either — the auth probe above already
  # proved the token works to reach this line, so "(API/token?)" was misleading.
  [ -z "$did" ] && { note "⚠️ $name: no deployment returned (token already verified OK — transient CF read or worker renamed)"; continue; }
  prev=$(get_state "$name")
  if [ -z "$prev" ]; then
    set_state "$name" "$did"   # first run = baseline silently
  elif [ "$prev" != "$did" ]; then
    note "🚀 $label deployed: $name • ${did:0:8} • ${meta:-?} • ${when%.*}Z"
    set_state "$name" "$did"
  fi
done

# ---- health of the live domains ----
declare -a HEALTH=( "store.force-ai.co" "admin.force-ai.co" "orders.force-ai.co" "whatsapp.force-ai.co" "crm.force-ai.co" "www.forcemediakw.com" "wadyaljuz.com" )
for h in "${HEALTH[@]}"; do
  code=$(curl -s -o /dev/null -w '%{http_code}' -m 15 "https://$h/" 2>/dev/null)
  case "$code" in 200|301|302|307|308) ;; *) note "⚠️ $h unhealthy (HTTP ${code:-000})" ;; esac
done

if [ ${#findings[@]} -eq 0 ]; then
  echo "[cf-workers-watch] OK — no new deploys, all domains healthy."
  write_status "cf-workers" "true" "no new deploys; all domains healthy" '{}' 2>/dev/null
  exit 0
fi
msg="☁️ Cloudflare — ${#findings[@]} update(s):"$'\n'"$(printf '  • %s\n' ${findings[@]+"${findings[@]}"})"
echo "$msg"
"$HERE/notify.sh" "Cloudflare Workers" "$msg" >/dev/null 2>&1 || true
DETAIL=$(printf '%s\n' ${findings[@]+"${findings[@]}"} | python3 -c 'import json,sys; print(json.dumps({"items":[l for l in sys.stdin.read().splitlines() if l]}))')
write_status "cf-workers" "false" "${#findings[@]} CF update(s)" "$DETAIL" 2>/dev/null
exit 0
