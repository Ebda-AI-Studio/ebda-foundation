#!/usr/bin/env bash
# app-error-heal.sh — closes gap G1 (2026-07-22 audit): the OS detects app-level
# errors (alert-triage) but only ACTS on service up/down. This adds instant,
# PRECISE action for known application-error CLASSES that return 200 to a health
# probe while failing underneath (Prisma pool-timeout on refunds; inngest COA
# seed missing). Registry-driven: ops/lib/app-error-registry.json.
#
# Action model (mirrors self-heal's tiering):
#   escalate            → fire the class's precise runbook via notify.sh. SAFE
#                         default; MANDATORY for any data-touching class.
#   redeploy:<svc-id>   → compute-only recovery via self-heal.sh <svc-id> for
#                         leaked-connection/stuck-process classes. Never data.
# Guardrails: per-class cooldown, count-in-window threshold, full audit log,
# DRY_RUN=1 simulates. Read-only against Sentry; the only mutation is an OPT-IN
# compute redeploy that self-heal.sh itself guards (confirm/cooldown/max-attempts).
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/bin:/bin:$PATH"
HERE="$HOME/.claude/scripts"
REG="${APP_ERR_REG:-$HERE/lib/app-error-registry.json}"
STATE="$HOME/.whisky-os-state"; LOG="$STATE/app-error-heal.log"; mkdir -p "$STATE"
NOTIFY="$HERE/notify.sh"; DRY="${DRY_RUN:-0}"
ts(){ date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo now; }
log(){ printf '%s [app-error-heal] %s\n' "$(ts)" "$*" >>"$LOG"; }
. "$HERE/lib/os-state.sh" 2>/dev/null || true

[ -f "$REG" ] || { log "no registry at $REG"; exit 1; }
# creds
STOK="${SENTRY_AUTH_TOKEN:-}"
[ -z "$STOK" ] && [ -f "${OS_SERVICES_ENV:-$HOME/.whisky-services.env}" ] && STOK="$(grep -E '^SENTRY_AUTH_TOKEN=' "${OS_SERVICES_ENV:-$HOME/.whisky-services.env}" 2>/dev/null | cut -d= -f2- | tr -d '"')"
SORG="${SENTRY_ORG:-}"
[ -z "$SORG" ] && [ -f "${OS_SERVICES_ENV:-$HOME/.whisky-services.env}" ] && SORG="$(grep -E '^SENTRY_ORG=' "${OS_SERVICES_ENV:-$HOME/.whisky-services.env}" 2>/dev/null | cut -d= -f2- | tr -d '"')"
[ -n "$STOK" ] && [ -n "$SORG" ] || { log "SENTRY_AUTH_TOKEN/SENTRY_ORG not set — skip"; echo "app-error-heal: sentry not configured — skip"; exit 0; }

COOLDOWN=$(python3 -c "import json;print(json.load(open('$REG')).get('cooldown_sec',3600))" 2>/dev/null || echo 3600)
NCLASSES=$(python3 -c "import json;print(len(json.load(open('$REG'))['classes']))" 2>/dev/null || echo 0)
now=$(date +%s 2>/dev/null || echo 0)
acted=0; checked=0

for i in $(seq 0 $((NCLASSES-1))); do
  IFS=$'\t' read -r NAME PROJS WIN THRESH ACTION < <(python3 -c "
import json
c=json.load(open('$REG'))['classes'][$i]
print('\t'.join([c['name'], c['projects'], str(c['window_h']), str(c['threshold']), c['action']]))" 2>/dev/null)
  [ -n "${NAME:-}" ] || continue
  REGEX=$(python3 -c "import json;print(json.load(open('$REG'))['classes'][$i]['title_regex'])" 2>/dev/null)
  RUNBOOK=$(python3 -c "import json;print(json.load(open('$REG'))['classes'][$i].get('runbook',''))" 2>/dev/null)
  checked=$((checked+1))

  # Count matching issues STILL FIRING within the class window (instant-action
  # semantics — respond to live incidents, not historical unresolved). Sentry's
  # statsPeriod only accepts ''/'24h'/'14d', and issue `count` is all-time, so we
  # query with a valid period and gate recency on each issue's lastSeen <= WIN
  # hours. `total` = sum of all-time counts of the matching STILL-FIRING issues.
  total=0; sample=""
  for proj in $PROJS; do
    body=$(curl -sS -m 25 -H "Authorization: Bearer $STOK" \
      "https://sentry.io/api/0/projects/$SORG/$proj/issues/?query=is:unresolved&statsPeriod=14d&sort=freq&per_page=50" 2>/dev/null || echo '[]')
    IFS=$'\t' read -r sub samp < <(REGEX="$REGEX" WIN="$WIN" python3 -c "
import json,sys,os,re,datetime
now=datetime.datetime.now(datetime.timezone.utc); winh=int(os.environ['WIN'])
def parse(s):
  try: return datetime.datetime.fromisoformat((s or '').replace('Z','+00:00'))
  except Exception: return None
try:
  rx=re.compile(os.environ['REGEX'],re.I); tot=0; samp=''
  d=json.load(sys.stdin)
  if not isinstance(d, list): d=[]
  for it in d:
    md=it.get('metadata') or {}
    # Sentry truncates the title to the exception CLASS (e.g. PrismaClientKnownRequestError);
    # the discriminating message lives in metadata.value — must search it too.
    # (No backticks here: this whole -c body is a bash double-quoted string, where
    #  backticks would be command-substituted before python ever sees them.)
    t=' '.join([it.get('title') or '', it.get('culprit') or '', md.get('value') or '', md.get('type') or ''])
    if not rx.search(t): continue
    ls=parse(it.get('lastSeen'))
    if not ls or (now-ls).total_seconds() > winh*3600: continue   # not firing in-window
    tot+=int(it.get('count',0) or 0)
    if not samp: samp=((md.get('value') or it.get('title') or '')[:80])
  print('%d\t%s' % (tot, samp or '-'))
except Exception: print('0\t-')
" <<<"$body")
    total=$((total + ${sub:-0}))
    [ -z "$sample" ] && [ "${samp:-}" != "-" ] && sample="$samp"
  done

  log "class '$NAME' -> $total matching events in ${WIN}h (threshold $THRESH) action=$ACTION"
  [ "${total:-0}" -lt "${THRESH:-1}" ] && continue

  # cooldown
  SF="$STATE/app-error-$NAME.json"
  last=$(python3 -c "import json;print(json.load(open('$SF')).get('last',0))" 2>/dev/null || echo 0); last=${last:-0}
  if [ "$last" -gt 0 ] && [ $((now-last)) -lt "$COOLDOWN" ]; then
    log "'$NAME' within cooldown (${COOLDOWN}s, last $((now-last))s ago) — skip"; continue
  fi

  acted=$((acted+1))
  msg="Class: $NAME — $total events in last ${WIN}h (e.g. \"${sample:-?}\"). $RUNBOOK"
  case "$ACTION" in
    escalate)
      log "ESCALATE '$NAME' ($total ev): $sample"
      [ "$DRY" = 0 ] && "$NOTIFY" "⚠️ App-error class firing: $NAME" "$msg" >/dev/null 2>&1 || echo "[dry] escalate $NAME"
      ;;
    redeploy:*)
      svc="${ACTION#redeploy:}"
      log "COMPUTE-HEAL '$NAME' -> self-heal $svc (redeploy) + escalate context ($total ev)"
      [ "$DRY" = 0 ] && "$NOTIFY" "⚠️ App-error class firing: $NAME → redeploy $svc" "$msg" >/dev/null 2>&1 || true
      [ "$DRY" = 0 ] && "$HERE/self-heal.sh" "$svc" "app-error-heal: $NAME class breached ($total ev/${WIN}h)" >/dev/null 2>&1 || echo "[dry] would self-heal $svc"
      ;;
    *) log "'$NAME' unknown action '$ACTION' — escalate as fallback"
       [ "$DRY" = 0 ] && "$NOTIFY" "⚠️ App-error class firing: $NAME (unmapped action)" "$msg" >/dev/null 2>&1 || true ;;
  esac
  [ "$DRY" = 0 ] && python3 -c "import json;json.dump({'last':$now,'events':$total},open('$SF','w'))" 2>/dev/null
done

log "checked $checked classes, acted on $acted"
command -v write_status >/dev/null 2>&1 && write_status "app-error-heal" "$([ "$acted" -eq 0 ] && echo true || echo warn)" "checked $checked app-error classes, $acted firing" "{\"acted\":$acted,\"checked\":$checked}"
echo "app-error-heal: checked $checked classes, $acted firing."
exit 0
