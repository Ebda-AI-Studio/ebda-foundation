#!/usr/bin/env bash
# sentry-stale-watch.sh — closes gaps G2 (alert-and-forget) + G5 (24h-window
# blind spot) from the 2026-07-22 audit.
#
# alert-triage.sh fires on NEW/SURGING Sentry errors in a 24h view — so a real
# error that was alerted once and then quietly kept firing for weeks (the Prisma
# tx-timeout class; the inngest COA-seed failure) drops out of view and is never
# chased to resolution. This is the closing loop: a LOW-frequency digest that
# re-surfaces REAL (noise-filtered) unresolved errors that are (a) old enough to
# be "forgotten" and (b) still firing — i.e. bleeding, not fixed-and-stale.
#
# Read-only. Meant for a daily/weekly cadence (not the 30-min alert-triage beat).
# Tunables: STALE_DAYS (default 5 — older than this = "forgotten"), MIN_COUNT
# (default 10 — ignore trivial), RECENT_DAYS (default 3 — must have fired within
# this to count as "still bleeding"). SENTRY_NOISE_RE mirrors alert-triage.
set -uo pipefail
# S0 (2026-10-26): --help runs nothing; one run at a time (lib/single-instance.sh)
. "$(dirname "${BASH_SOURCE[0]}")/lib/args.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/args.sh" || exit 2
. "$(dirname "${BASH_SOURCE[0]}")/lib/single-instance.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/single-instance.sh" || exit 2
args_help "${BASH_SOURCE[0]}" "$@"
single_instance sentry-stale-watch
export PATH="/opt/homebrew/bin:/usr/bin:/bin:$PATH"
HERE="$HOME/.claude/scripts"
STATE="$HOME/.whisky-os-state"; LOG="$STATE/sentry-stale.log"; mkdir -p "$STATE"
NOTIFY="$HERE/notify.sh"
ts(){ date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo now; }
. "$HERE/lib/os-state.sh" 2>/dev/null || true

STOK="${SENTRY_AUTH_TOKEN:-}"
[ -z "$STOK" ] && [ -f "${OS_SERVICES_ENV:-$HOME/.whisky-services.env}" ] && STOK="$(grep -E '^SENTRY_AUTH_TOKEN=' "${OS_SERVICES_ENV:-$HOME/.whisky-services.env}" 2>/dev/null | cut -d= -f2- | tr -d '"')"
SORG="${SENTRY_ORG:-}"
[ -z "$SORG" ] && [ -f "${OS_SERVICES_ENV:-$HOME/.whisky-services.env}" ] && SORG="$(grep -E '^SENTRY_ORG=' "${OS_SERVICES_ENV:-$HOME/.whisky-services.env}" 2>/dev/null | cut -d= -f2- | tr -d '"')"
[ -n "$STOK" ] && [ -n "$SORG" ] || { echo "sentry-stale-watch: sentry not configured — skip"; exit 0; }

PROJECTS="${SENTRY_PROJECTS:-ebda-api ebda-web ebda-admin}"
STALE_DAYS="${SENTRY_STALE_DAYS:-5}"
MIN_COUNT="${SENTRY_STALE_MIN_COUNT:-10}"
RECENT_DAYS="${SENTRY_STALE_RECENT_DAYS:-3}"
# same noise filter as alert-triage / anomaly-watch — these are expected/guardrail
# errors, not incidents. Override via SENTRY_NOISE_RE in ~/.whisky-services.env.
NOISE_RE="${SENTRY_NOISE_RE:-Not enough inventory|INSUFFICIENT_INVENTORY|Too many .* operations|Cart item not found|MINIMUM_ORDER|already .*refunded|window\.webkit|messageHandlers|Java object is gone|invoking postMessage|reading 'parentNode'|ResizeObserver loop|top\.GLOBALS|took too long to respond|NetworkError|Failed to fetch|AbortError}"

hits=""
for proj in $PROJECTS; do
  # statsPeriod valid values are only '', '24h', '14d' (Sentry rejects e.g. 90d
  # with an error DICT — which iterates as keys and silently matches nothing).
  # 14d is the widest allowed; firstSeen/lastSeen on each issue are all-time, so
  # a 14d window still surfaces issues whose firstSeen is much older.
  body=$(curl -sS -m 25 -H "Authorization: Bearer $STOK" \
    "https://sentry.io/api/0/projects/$SORG/$proj/issues/?query=is:unresolved&statsPeriod=14d&sort=freq&per_page=50" 2>/dev/null || echo '[]')
  out=$(PROJ="$proj" NOISE_RE="$NOISE_RE" STALE_DAYS="$STALE_DAYS" MIN_COUNT="$MIN_COUNT" RECENT_DAYS="$RECENT_DAYS" python3 -c "
import json,sys,os,re,datetime
p=os.environ['PROJ']; noise=re.compile(os.environ['NOISE_RE'],re.I)
staled=int(os.environ['STALE_DAYS']); minc=int(os.environ['MIN_COUNT']); recent=int(os.environ['RECENT_DAYS'])
now=datetime.datetime.now(datetime.timezone.utc)
def parse(s):
  try: return datetime.datetime.fromisoformat((s or '').replace('Z','+00:00'))
  except Exception: return None
try:
  d=json.load(sys.stdin)
  if not isinstance(d, list): d=[]   # error dict (bad token/period) → treat as empty, never crash
  for it in d:
    md=it.get('metadata') or {}
    title=(it.get('title') or ''); cul=(it.get('culprit') or ''); val=(md.get('value') or '')
    # Sentry truncates title to the exception class; the message is in metadata.value.
    if noise.search(title+' '+cul+' '+val): continue
    cnt=int(it.get('count',0) or 0)
    if cnt < minc: continue
    fs=parse(it.get('firstSeen')); ls=parse(it.get('lastSeen'))
    if not fs or not ls: continue
    age=(now-fs).days; since=(now-ls).days
    # flatten whitespace/newlines (Sentry values can be multi-line JSON) → one clean line
    label=' '.join((val or title).split())[:70]
    if age>=staled and since<=recent:   # old AND still bleeding
      print('  • [%s] %s — %d ev, age %dd, last %dd ago' % (p, label, cnt, age, since))
except Exception as e:
  sys.stderr.write('sentry-stale parse error [%s]: %s\n' % (p, e))
" <<<"$body")
  [ -n "$out" ] && hits="$hits$out"$'\n'
done

printf '%s [sentry-stale] scanned %s projects\n' "$(ts)" "$(echo $PROJECTS | wc -w | tr -d ' ')" >>"$LOG"
if [ -z "$hits" ]; then
  echo "sentry-stale-watch: OK — no stale-but-still-firing real errors."
  command -v write_status >/dev/null 2>&1 && write_status "sentry-stale" "true" "clean — no forgotten-but-bleeding errors" '{}'
  exit 0
fi

n=$(printf '%s' "$hits" | grep -c '•' || echo 0)
echo "sentry-stale-watch: $n forgotten-but-still-firing real error(s):"
printf '%s\n' "$hits"
printf '%s [sentry-stale] %s stale-bleeding\n' "$(ts)" "$n" >>"$LOG"
command -v write_status >/dev/null 2>&1 && write_status "sentry-stale" "warn" "$n real error(s) unresolved >${STALE_DAYS}d and still firing" "{\"count\":$n}"
[ -x "$NOTIFY" ] && "$NOTIFY" "🔁 Forgotten-but-bleeding Sentry errors ($n)" \
  "Real errors unresolved >${STALE_DAYS}d that are STILL firing (last ≤${RECENT_DAYS}d) — alerted once, never chased. Resolve or fix:"$'\n\n'"$hits" >/dev/null 2>&1 || true
exit 0
