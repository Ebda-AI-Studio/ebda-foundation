#!/usr/bin/env bash
# self-heal.sh — the OS medic. Given a service that a monitor found DOWN, confirm
# it's really down (anti-flap), run a bounded platform-appropriate recovery
# (redeploy/rollback - compute only, NEVER data), re-verify, and either log "healed" or hand
# the brain a finding "auto-heal failed".
# Strategy: heal-immediately, then report to the BRAIN (a finding), never to a chat. A successful heal, a network blip and a
# false alarm are logged only; an outage the recipes could not fix is a P1 prod-outage finding (selfHealExhausted).
# Guardrails: confirm-still-down, cooldown, max attempts, full audit log, DRY_RUN.
# Usage: self-heal.sh <service-id> [reason]   (DRY_RUN=1 to simulate, no mutation)
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/bin:/bin:$PATH"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/os-config.sh
. "$HERE/lib/os-config.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-config.sh" 2>/dev/null || true
command -v os_config_load >/dev/null 2>&1 && os_config_load
. "$HERE/lib/brain-post.sh" 2>/dev/null || true
. "$HERE/lib/heal-registry.sh" 2>/dev/null || true
REG="$(heal_registry_path 2>/dev/null)"
STATE="$OS_STATE_DIR"; LOG="$STATE/heal.log"; mkdir -p "$STATE"
DRY="${DRY_RUN:-0}"
ID="${1:?service-id required}"; REASON="${2:-monitor reported down}"
ts(){ date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo now; }
log(){ printf '%s [%s] %s\n' "$(ts)" "$ID" "$*" >>"$LOG"; }
j(){ python3 -c "import json,sys;d=[s for s in json.load(open('$REG'))['services'] if s['id']=='$ID'];print(d[0].get('$1','') if d else '')" 2>/dev/null; }
cfg(){ python3 -c "import json;print(json.load(open('$REG')).get('$1',''))" 2>/dev/null; }

[ -n "$REG" ] && [ -f "$REG" ] || { log "no registry (heal_services not configured in the local config)"; exit 1; }
# PAUSE-GUARD-BEGIN — a product parked on purpose ($OS_STATE_DIR/<product>-paused,
# e.g. a power-off script) is never probed or redeployed, whichever caller sent us.
# Product = the id's prefix (shop-api → shop). Checked here, not only in each caller:
# 2026-10-21 a product was stopped but heal-watch kept redeploying it every cycle.
. "$HERE/lib/os-state.sh" 2>/dev/null || true
command -v service_paused >/dev/null 2>&1 || service_paused() { [ -f "$STATE/$1-paused" ]; }
service_paused "${ID%%-*}" && { log "${ID%%-*} is paused on purpose — skip (no probe, no recovery)"; exit 0; }
# PAUSE-GUARD-END
NAME=$(j name); PLAT=$(j platform); URL=$(j health); EXPECT=$(j expect); REC=$(j recovery); EN=$(j enabled)
[ "$EN" = "True" ] || { log "disabled — skip"; exit 0; }
COOLDOWN=$(cfg cooldown_sec); MAXATT=$(cfg max_attempts); PROBES=$(cfg confirm_probes)
COOLDOWN=${COOLDOWN:-600}; MAXATT=${MAXATT:-3}; PROBES=${PROBES:-3}

probe(){ # returns 0 if UP per expect
  local code; code=$(curl -s -o /dev/null -w '%{http_code}' -m 12 "$URL" 2>/dev/null || echo 000)
  case "$EXPECT" in
    "<500") [ "$code" != "000" ] && [ "$code" -lt 500 ] 2>/dev/null ;;
    *)      [ "$code" = "${EXPECT:-200}" ] ;;
  esac
}

# --- 1. confirm still down (anti-flap) ---
up=0; for i in $(seq 1 "$PROBES"); do probe && { up=1; break; }; sleep 5; done
# re-probe UP = the service recovered (or a transient blip). RESET the attempt
# counter — otherwise counters accumulate across unrelated blips, hit max, and then
# every future blip escalates "FAILED" forever (the 2026-07-07 stuck-at-3 bug).
[ "$up" = 1 ] && { log "re-probe UP — transient, no action ($REASON); attempts reset"; python3 -c "import json;json.dump({'last':0,'attempts':0},open('$STATE/heal-$ID.json','w'))" 2>/dev/null; exit 0; }

# --- 1.5 IS IT THE SERVICE, OR MY NETWORK? (false-alarm guard) ---
# heal-watch runs on a machine with a consumer network; when THAT network blips,
# every probe returns 000 and a healthy prod service looks "down". Never redeploy
# prod on that. Two-layer confirm before we believe the outage is real:
#   (a) baseline: can we even reach the internet (cloudflare/google)? If NOT, the
#       "down" is monitor-side — abort, no action. (2026-07-06: a Mac network blip
#       faked an API outage + would have redeployed prod.)
#   (b) external: if UPTIMEROBOT_API_KEY is set and an external monitor reports this
#       health URL UP, it's a false alarm from here — abort.
# net_ok requires a baseline host to answer FAST (<2.5s). A healthy connection hits
# cloudflare/google in <0.5s; if the fastest baseline is slow OR unreachable, the
# local network is degraded — the "down" is untrustworthy (the 2026-07-06 incident:
# cloudflare answered in 3.6s while the API probe timed out → false "down").
net_ok=0
for _b in https://cloudflare.com https://www.google.com https://1.1.1.1; do
  t=$(curl -s -o /dev/null -w '%{time_total}' -m 10 "$_b" 2>/dev/null || echo 99)
  awk "BEGIN{exit !($t>0 && $t<2.5)}" 2>/dev/null && { net_ok=1; break; }
done
if [ "$net_ok" = 0 ]; then
  log "NETWORK-SIDE false alarm: baseline hosts slow/unreachable from here — '$ID' down is untrustworthy; NO action"
  write_status "heal-$ID" "warn" "$NAME: monitor-network degraded — no action (false-alarm guard)" '{}' 2>/dev/null || true
  exit 0
fi
UR_KEY="${UPTIMEROBOT_API_KEY:-}"
[ -z "$UR_KEY" ] && [ -f "$OS_SERVICES_ENV" ] && UR_KEY="$(grep -E '^UPTIMEROBOT_API_KEY=' "$OS_SERVICES_ENV" 2>/dev/null | cut -d= -f2- | tr -d '"')"
UR_HOST="$(printf '%s' "$URL" | sed -E 's#https?://##; s#/.*##')"
if [ -n "$UR_KEY" ] && [ -n "$UR_HOST" ]; then
  ext=$(curl -s -m 15 -X POST "https://api.uptimerobot.com/v2/getMonitors" -d "api_key=$UR_KEY&format=json" 2>/dev/null \
        | python3 -c "import json,sys,os
h=os.environ['H']
try:
 d=json.load(sys.stdin)
 for m in d.get('monitors',[]):
  if h in (m.get('url') or '') and m.get('status')==2: print('up'); break
except Exception: pass" H="$UR_HOST" 2>/dev/null)
  if [ "$ext" = "up" ]; then
    log "EXTERNAL prober says $UR_HOST is UP — local '$ID down' is a false alarm; NO action"
    write_status "heal-$ID" "warn" "$NAME: external prober UP — local false alarm, no action" '{}' 2>/dev/null || true
    exit 0
  fi
fi
log "CONFIRMED DOWN ($REASON) — recovery=$REC platform=$PLAT (network+external checks passed)"

# --- 2. cooldown / attempt state ---
SF="$STATE/heal-$ID.json"
now=$(date +%s 2>/dev/null || echo 0)
last=$(python3 -c "import json;print(json.load(open('$SF')).get('last',0))" 2>/dev/null || echo 0)
att=$(python3 -c "import json;print(json.load(open('$SF')).get('attempts',0))" 2>/dev/null || echo 0)
last=${last:-0}; att=${att:-0}
# stale-attempt decay: a counter from an OLD incident must not doom a fresh one.
# if the last attempt was long ago (>4x cooldown), the service has been fine since — reset.
if [ "$last" -gt 0 ] && [ $((now-last)) -gt $((COOLDOWN*4)) ]; then
  log "attempt state is stale (last $((now-last))s ago > $((COOLDOWN*4))s) — resetting counter"; att=0
fi
if [ "$last" -gt 0 ] && [ $((now-last)) -lt "$COOLDOWN" ]; then
  log "within cooldown (${COOLDOWN}s, last attempt $((now-last))s ago) — skip to avoid loop"; exit 0
fi
if [ "$att" -ge "$MAXATT" ]; then
  # NEVER scream FAILED about a healthy service — do a final live probe first.
  if probe; then
    log "attempts were exhausted but service is UP on final probe — resetting, no escalation"
    python3 -c "import json;json.dump({'last':0,'attempts':0},open('$SF','w'))" 2>/dev/null
    exit 0
  fi
  log "attempts exhausted ($att/$MAXATT) — ESCALATE"
  [ "$DRY" = 0 ] && heal_report prod-outage P1 true "$ID" "$NAME is DOWN and auto-heal is exhausted ($att attempts, recovery=$REC): $URL"
  exit 0
fi

# --- 3. run recovery (compute only) ---
att=$((att+1))
python3 -c "import json;json.dump({'last':$now,'attempts':$att},open('$SF','w'))" 2>/dev/null
log "recovery attempt $att/$MAXATT: $REC $([ "$DRY" = 1 ] && echo '(DRY_RUN)')"
run_recovery(){
  [ "$DRY" = 1 ] && { echo "[dry] would run: $REC for $ID"; return 0; }
  case "$REC" in
    railway-redeploy)
      # Auth: the Railway CLI is NOT `railway link`ed in the launchd context, so a bare
      # `railway redeploy` fails OAuth ("No linked project found") and no-ops. Authenticate
      # with the account token (RAILWAY_API_TOKEN in the services env) and pin the
      # project/env explicitly via --project/--environment (the CLI can't infer them
      # unlinked). Fail LOUD (return 2 → escalate) if the token or project id is missing —
      # never silently no-op and let step 4 falsely credit a "heal" (2026-07-22 incident).
      local rproj rtok
      rproj="$(j railway_project)"
      [ -z "$rproj" ] && { echo "railway-redeploy: registry has no railway_project id for $ID"; return 2; }
      rtok="${RAILWAY_API_TOKEN:-}"
      [ -z "$rtok" ] && [ -f "$OS_SERVICES_ENV" ] && rtok="$(grep -E '^RAILWAY_API_TOKEN=' "$OS_SERVICES_ENV" 2>/dev/null | cut -d= -f2- | tr -d '"')"
      [ -z "$rtok" ] && { echo "railway-redeploy: RAILWAY_API_TOKEN not set in the services env — cannot authenticate to Railway"; return 2; }
      RAILWAY_API_TOKEN="$rtok" railway redeploy --project "$rproj" --service "$(j railway_service)" --environment "$(j railway_env)" --yes 2>&1 | tail -3
      return "${PIPESTATUS[0]}";;
    vercel-rollback)
      # RETIRED 2026-07 — Vercel account cancelled, all hosting on Cloudflare Workers.
      # No registry entry uses this; kept as an explicit escalate so a stale entry alerts, never silently no-ops.
      echo "vercel-rollback RETIRED (Vercel cancelled) — escalating"; return 2;;
    wrangler-rollback)
      # capture the REAL wrangler exit (PIPESTATUS[1] = wrangler in printf|wrangler|tail),
      # so a failed rollback can't be mis-credited as a heal in step 4.
      printf 'y\n' | wrangler rollback --name "$(j cf_worker)" --message "auto-heal $(ts)" 2>&1 | tail -3
      return "${PIPESTATUS[1]}";;
    neon-prepare-recovery)
      # TIER 3 (data) — NEVER auto-cuts-over. Prepares a verified PITR recovery branch and
      # escalates for one-tap human approve (Ahmad's decision 2026-07-06). Non-destructive:
      # only creates a `recover-*` branch; prod data is untouched until a human approves.
      "$HERE/neon-recover.sh" prepare "$(j neon_project)" 2>&1 | tail -4; return 2;;
    escalate-only)
      echo "escalate-only (platform recovery not yet wired for $ID)"; return 2;;
    *) echo "unknown recovery: $REC"; return 2;;
  esac
}
rec_out=$(run_recovery); rec_rc=$?
log "recovery output: $(printf '%s' "$rec_out" | tr '\n' ' ' | cut -c1-200)"

# escalate-only or recovery not applicable → alert, no re-verify loop
if [ "$rec_rc" = 2 ]; then
  [ "$DRY" = 0 ] && heal_report prod-outage P1 true "$ID" "$NAME is down ($REASON); auto-recovery could not run ($REC): $(printf '%s' "$rec_out" | tr '\n' ' ' | cut -c1-160) $URL"
  log "escalate-only path — alerted"; exit 0
fi

# --- 4. re-verify after recovery ---
# A recovery command that EXITED NON-ZERO did nothing — if the service is up now it
# recovered on its OWN, and crediting "$REC healed it" is a false green (2026-07-22:
# railway redeploy failed OAuth for 71min while the API self-recovered, yet we notified
# " fixed automatically"). Only claim a heal when the recovery command actually succeeded.
sleep "$([ "$DRY" = 1 ] && echo 2 || echo 95)"
if probe; then
  python3 -c "import json;json.dump({'last':$now,'attempts':0},open('$SF','w'))" 2>/dev/null  # reset — service is up
  if [ "$rec_rc" = 0 ]; then
    log "HEALED ok (recovery=$REC, attempt $att)"
  elif printf '%s' "$rec_out" | grep -qiE 'dns error|failed to lookup address|client error \(Connect\)|Temporary failure in name resolution|Connection refused|Network is unreachable'; then
    # The recovery command failed with a HOST-NETWORK error (DNS/connect) — i.e. THIS monitor
    # couldn't even reach the platform's API. That means the earlier "down" was monitor-side
    # too: the same local-network blip the confirm guard exists to catch, just surfacing one
    # step later (the guard passed at probe time, the network flapped a second later at
    # redeploy time — all monitored Railway services 000000 together is the tell). The recovery
    # command is NOT broken; nothing was ever really down. Don't cry "auto-heal BROKEN".
    # (2026-07-27: two Railway APIs both flapped to 000000; redeploy hit "dns error / failed
    #  to lookup address information"; both were 200 the whole time — a host network blip.)
    log "MONITOR-NETWORK FALSE POSITIVE — $REC exited $rec_rc with a host-network error (DNS/connect); $NAME was never really down (probe + redeploy both failed because THIS host's network blipped). No action, not broken."
  else
    log "RECOVERED EXTERNALLY — $REC exited $rec_rc (did nothing); $NAME came back on its own, auto-heal path is BROKEN for $ID"
    [ "$DRY" = 0 ] && heal_report self-heal-broken P2 false "$ID" "$NAME recovered on its own: its $REC recovery command FAILED (exit $rec_rc), so the auto-heal path for $NAME is broken and needs a fix before the next outage. $URL"
  fi
else
  log "still DOWN after recovery (attempt $att/$MAXATT, recovery rc=$rec_rc)"
  if [ "$att" -ge "$MAXATT" ]; then
    [ "$DRY" = 0 ] && heal_report prod-outage P1 true "$ID" "$NAME still DOWN after $att recovery attempts ($REC, last exit $rec_rc): $URL"
    log "ESCALATED after $att attempts"
  else
    log "will retry next heal-watch cycle (attempt $att/$MAXATT)"
  fi
fi
