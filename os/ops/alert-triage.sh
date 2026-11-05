#!/usr/bin/env bash
# alert-triage.sh — the OS reads ALL alert channels FOR me, so I know about
# production problems without Ahmad pinging me.
#
# WHY: the Force AI Telegram bot is OUTBOUND-ONLY — a bot cannot read its own
# sent history, so the OS can't "read the bot." Instead it reads every SOURCE the
# bot alerts on, in one place, and mirrors the result to an OS-readable file.
#
# CHANNELS (each one the Mac OS can reach via API; best-effort, skips if unauthed):
#   sentry       — top unresolved error issues per Force project (by frequency)
#   uptimerobot  — monitors not currently UP (downtime)
#   railway      — services whose latest deploy is FAILED/CRASHED
#   ci           — main-branch CI red + open PRs with failing required checks
#
# Each run:
#   1. Gather normalized events {channel,key,count,status,title} from every channel.
#   2. Diff vs last run (~/.whisky-os-state/alert-seen.json): NEW / SURGING / CHANGED.
#   3. Write ~/.whisky-os-state/alert-digest.json (the OS-readable bot-stream MIRROR).
#   4. Print a human digest; with --notify push NEW/SURGING/CHANGED to the notify bus.
#
# Creds: ~/.whisky-services.env (SENTRY_AUTH_TOKEN+SENTRY_ORG, UPTIMEROBOT_API_KEY).
# Railway via the `railway` CLI; CI via `gh`. Read-only; no secrets printed.
#
# Usage:  ops/alert-triage.sh            # read + digest, print only
#         ops/alert-triage.sh --notify   # also Telegram the new/surging/changed
set -euo pipefail

# _ut (hard wall clock on external calls) lives in the shared lib — without this
# source every _ut call below would be a "command not found", i.e. the guard
# would fail silently instead of bounding anything.
. "$(dirname "$0")/lib/os-state.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-state.sh" 2>/dev/null || true

cd "$(dirname "$0")"

# host pre-flight + unreachable classifier (2026-09-16). An offline run used to
# look like "every channel returned nothing" -> the digest + SEEN dedupe memory
# were overwritten with an empty set (the log shows 104 such runs: "0 still-firing",
# "no 'CI' runs found" for ALL four repos at once), and the first online run
# afterwards re-alerted every open issue as NEW (#197).
. "$(dirname "$0")/lib/net-probe.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/net-probe.sh" 2>/dev/null || true
command -v host_online >/dev/null 2>&1 || { echo "alert-triage: FATAL - lib/net-probe.sh not found; refusing to run (run ops/install.sh)" >&2; exit 2; }
CH_FAIL=0   # channel fetches that errored (as opposed to returning nothing)

SVC_ENV="${WHISKY_SERVICES_ENV:-${OS_SERVICES_ENV:-$HOME/.whisky-services.env}}"
[ -f "$SVC_ENV" ] && { set -a; . "$SVC_ENV"; set +a; }
SENTRY_ORG_V="${SENTRY_ORG:-org-lingering-river-25973882}"
SENTRY_PROJECTS="${SENTRY_PROJECTS:-ebda-api ebda-web}"
CI_REPOS="${CI_REPOS:-Ebda-AI-Studio/ebda-store Ebda-AI-Studio/ebda-whatsapp Ebda-AI-Studio/ebda-studio}"
RAILWAY_PROJECTS="${RAILWAY_PROJECTS:-}"   # optional "name:service" hints; CLI default if empty
SURGE_DELTA="${ALERT_SURGE_DELTA:-25}"
TOP_N="${SENTRY_TOP_N:-15}"
# An "ongoing" issue only counts as ongoing while it is STILL FIRING. Sentry
# issue counts here are LIFETIME totals (see the endpoint note below), so
# without this window a burst that stopped a month ago outranks a live one
# forever. Events with no last_seen (uptime/CI/railway) are always current.
ONGOING_RECENT_DAYS="${ALERT_ONGOING_RECENT_DAYS:-7}"
NOTIFY=0; [ "${1:-}" = "--notify" ] && NOTIFY=1

# Known-NOISE denylist (case-insensitive regex) — an issue whose Sentry title
# matches is NOT an actionable app bug, so it never becomes NEW/SURGING. Three
# buckets: (a) EXPECTED 4xx business rejections the customer sees inline;
# (b) THIRD-PARTY in-app-browser / marketing-pixel bootstrap noise injected by
# the host app, not our code; (c) transient network blips the user retries.
# Override via SENTRY_NOISE_RE in ~/.whisky-services.env. Set to empty to disable.
SENTRY_NOISE_RE="${SENTRY_NOISE_RE:-Not enough inventory|INSUFFICIENT_INVENTORY|Too many .* operations|Cart item not found|MINIMUM_ORDER|already .*refunded|window\.webkit|messageHandlers|Java object is gone|invoking postMessage|reading 'parentNode'|ResizeObserver loop|top\.GLOBALS|took too long to respond|NetworkError|Failed to fetch|AbortError}"

# Resolve the CI-gating workflow NAME per repo — it is NOT always literally
# "CI" (some repos gate on a differently named workflow; some have none). Hardcoding
# --workflow CI made the CI channel silently never fire for those repos.
_ci_workflow() {
  case "$1" in
    *no-ci-repo)           echo "" ;;   # repo without a CI workflow — skip, don't false-miss
    *)                     echo "CI" ;;
  esac
}

STATE_DIR="$HOME/.whisky-os-state"; mkdir -p "$STATE_DIR"
SEEN="$STATE_DIR/alert-seen.json"; DIGEST="$STATE_DIR/alert-digest.json"
[ -f "$SEEN" ] || echo '{}' > "$SEEN"

EVENTS="$(mktemp)"; NT="$(mktemp)"; trap 'rm -f "$EVENTS" "$NT"' EXIT
echo '[]' > "$EVENTS"

# append normalized events (JSON array of objects) into EVENTS
_emit() { # stdin = JSON array
  python3 -c "
import sys,json
try: add=json.loads(sys.stdin.read() or '[]')
except Exception: add=[]
if not isinstance(add,list): add=[]
cur=json.load(open('$EVENTS')); cur.extend(add); json.dump(cur,open('$EVENTS','w'))
"
}

# ---------- channel: sentry ----------
if [ -n "${SENTRY_AUTH_TOKEN:-}" ]; then
  for proj in $SENTRY_PROJECTS; do
    # NOTE (measured 2026-08-18): the per-PROJECT issues endpoint IGNORES
    # statsPeriod. It returns issues whose last event was months ago, and `count`
    # is the issue's LIFETIME total, not the period total. (The per-ORG endpoint
    # DOES honour statsPeriod — ops/lib/sentry-impact.py uses that one.)
    # statsPeriod is kept only because `sort=freq` reads it; do NOT infer from it
    # that this list is 24h-scoped. Lifetime counts are what surge detection
    # wants (monotonic ⇒ clean deltas); recency is handled by last_seen below.
    body=$(curl -sS -m 25 -H "Authorization: Bearer $SENTRY_AUTH_TOKEN" \
      "https://sentry.io/api/0/projects/$SENTRY_ORG_V/$proj/issues/?query=is:unresolved&statsPeriod=24h&sort=freq&per_page=$TOP_N" 2>/dev/null) || { CH_FAIL=$((CH_FAIL+1)); body='[]'; }
    PROJ="$proj" NOISE_RE="$SENTRY_NOISE_RE" python3 -c "
import sys,json,os,re
try: issues=json.loads(sys.stdin.read() or '[]')
except Exception: issues=[]
if not isinstance(issues,list): issues=[]
p=os.environ['PROJ']; out=[]
noise=os.environ.get('NOISE_RE','').strip()
nre=re.compile(noise,re.I) if noise else None
skipped=0
for i in issues:
    title=(i.get('title') or '')
    if nre and nre.search(title):   # expected 4xx / third-party / transient — not a bug
        skipped+=1; continue
    out.append({'channel':'sentry','key':f\"sentry:{p}:{i.get('id')}\",'count':int(i.get('count',0) or 0),
                'status':'unresolved','title':f\"[{p}] {title[:90]}\",
                'last_seen':i.get('lastSeen')})
if skipped: print(f'alert-triage: {p} suppressed {skipped} known-noise issue(s)',file=sys.stderr)
print(json.dumps(out))
" <<<"$body" | _emit
  done
else echo "alert-triage: sentry skipped (no SENTRY_AUTH_TOKEN)" >&2; fi

# ---------- channel: uptimerobot ----------
if [ -n "${UPTIMEROBOT_API_KEY:-}" ]; then
  body=$(curl -sS -m 20 -X POST "https://api.uptimerobot.com/v2/getMonitors" \
    -d "api_key=${UPTIMEROBOT_API_KEY}&format=json" 2>/dev/null) || { CH_FAIL=$((CH_FAIL+1)); body='{}'; }
  python3 -c "
import sys,json
try: d=json.loads(sys.stdin.read() or '{}')
except Exception: d={}
out=[]
for m in (d.get('monitors') or []):
    st=m.get('status')   # 2=up, 8/9=down, 0=paused
    if st in (8,9):
        out.append({'channel':'uptimerobot','key':f\"uptime:{m.get('id')}\",'count':1,'status':'DOWN',
                    'title':f\"DOWN: {m.get('friendly_name','')} {m.get('url','')}\"})
print(json.dumps(out))
" <<<"$body" | _emit
else echo "alert-triage: uptimerobot skipped (no UPTIMEROBOT_API_KEY)" >&2; fi

# ---------- channel: gmail (alert emails the bot also forwards) ----------
# Headless read via IMAP + a Gmail App Password (Account > Security > App
# passwords; requires 2FA). Set GMAIL_IMAP_USER + GMAIL_IMAP_APP_PASSWORD in
# ~/.whisky-services.env. Searches the last day from known alert senders.
if [ -n "${GMAIL_IMAP_USER:-}" ] && [ -n "${GMAIL_IMAP_APP_PASSWORD:-}" ]; then
  GMAIL_ALERT_SENDERS="${GMAIL_ALERT_SENDERS:-sentry.io railway.app railway.com vercel.com uptimerobot.com github.com neon.tech posthog.com onesignal.com google.com cloudflare.com}" \
  python3 -c "
import imaplib,email,os,json,sys
from email.header import decode_header
user=os.environ['GMAIL_IMAP_USER']; pw=os.environ['GMAIL_IMAP_APP_PASSWORD']
senders=os.environ['GMAIL_ALERT_SENDERS'].split()
out=[]
def dec(s):
    try: return ''.join((b.decode(c or 'utf-8','ignore') if isinstance(b,bytes) else b) for b,c in decode_header(s or ''))
    except Exception: return s or ''
try:
    M=imaplib.IMAP4_SSL('imap.gmail.com',993); M.login(user,pw); M.select('INBOX')
    # Gmail X-GM-RAW lets us OR the alert senders + restrict to last day
    q='newer_than:1d ('+' OR '.join('from:'+s for s in senders)+')'
    typ,data=M.search(None,'X-GM-RAW','\"%s\"'%q)
    ids=(data[0].split() if data and data[0] else [])[-25:]
    for i in ids:
        t,d=M.fetch(i,'(BODY.PEEK[HEADER.FIELDS (FROM SUBJECT MESSAGE-ID)])')
        if t!='OK' or not d or not d[0]: continue
        msg=email.message_from_bytes(d[0][1])
        frm=dec(msg.get('From','')); subj=dec(msg.get('Subject','')); mid=(msg.get('Message-ID','') or i.decode())
        out.append({'channel':'gmail','key':'gmail:'+mid,'count':1,'status':'EMAIL',
                    'title':(frm.split('<')[0].strip()[:30]+' — '+subj)[:90]})
    M.logout()
except Exception as e:
    print('alert-triage: gmail channel error: %s'%e, file=sys.stderr)
print(json.dumps(out))
" | _emit
else echo "alert-triage: gmail skipped (set GMAIL_IMAP_USER + GMAIL_IMAP_APP_PASSWORD)" >&2; fi

# ---------- channel: ci (main red + open PRs with failing required checks) ----------
if command -v gh >/dev/null 2>&1; then
  for repo in $CI_REPOS; do
    wf="$(_ci_workflow "$repo")"
    [ -z "$wf" ] && continue   # repo has no CI-gating workflow — nothing to read
    # latest main CI conclusion. `cancelled` is infra (a run killed to free the
    # single runner / superseded), NOT a code failure — only FAILURE counts.
    # Keep gh's stderr and exit code: `2>/dev/null || echo ""` made "gh failed"
    # (offline, auth, timeout) indistinguishable from "this workflow has no runs",
    # and the log blamed a workflow rename 104 times for a dead network.
    _ci_err="$(mktemp)"
    mc=$(_ut "$OS_UT_FAST" gh run list --repo "$repo" --branch main --workflow "$wf" --limit 1 --json conclusion,headSha -q '.[0] | "\(.conclusion) \(.headSha)"' 2>"$_ci_err") && _ci_rc=0 || _ci_rc=$?
    if [ "$_ci_rc" -ne 0 ]; then
      CH_FAIL=$((CH_FAIL+1)); mc=""
      echo "alert-triage: ci — gh run list FAILED for $repo (exit $_ci_rc): $(tr '\n' ' ' < "$_ci_err" | cut -c1-300)" >&2
    elif [ -z "$mc" ]; then
      echo "alert-triage: ci — no '$wf' runs found for $repo (workflow renamed? check _ci_workflow)" >&2
    fi
    rm -f "$_ci_err"
    REPO="$repo" MC="$mc" python3 -c "
import os,json
repo=os.environ['REPO']; mc=os.environ.get('MC','').split()
out=[]
if mc and mc[0]=='failure':   # cancelled/skipped/success are not code failures
    out.append({'channel':'ci','key':f\"ci-main:{repo}\",'count':1,'status':'FAILURE',
                'title':f\"main CI FAILING: {repo} @ {mc[1][:8] if len(mc)>1 else ''}\"})
print(json.dumps(out))
" | _emit
  done
else echo "alert-triage: ci skipped (no gh)" >&2; fi

# ---------- offline? then DO NOT diff: an empty fetch is not "all resolved" ----------
# Only consulted when a channel actually errored, so a healthy run pays nothing.
# SEEN/DIGEST are left untouched, so the next online run diffs against real history.
if [ "$CH_FAIL" -gt 0 ] && ! host_online; then
  net_host_offline_report alert-triage "alert-triage"
  exit 0
fi

# ---------- diff vs seen, classify, digest, notify ----------
SURGE_DELTA="$SURGE_DELTA" SEEN="$SEEN" DIGEST="$DIGEST" EVENTS="$EVENTS" NT="$NT" \
RECENT_DAYS="$ONGOING_RECENT_DAYS" LIB="$(pwd)/lib" python3 -c "
import json,os,importlib.util
spec=importlib.util.spec_from_file_location('ad',os.path.join(os.environ['LIB'],'alert-digest.py'))
ad=importlib.util.module_from_spec(spec); spec.loader.exec_module(ad)
ev=json.load(open(os.environ['EVENTS']))
seen=json.load(open(os.environ['SEEN']))
digest,nextseen=ad.build_digest(ev,seen,
    surge_delta=int(os.environ['SURGE_DELTA']),
    recent_days=int(os.environ['RECENT_DAYS']))
# SEEN is the dedupe memory: a torn write reads as 'nothing seen yet' and the
# next run re-alerts everything. DIGEST rides the same transform for free.
def _aw(p, o, **kw):
    t = p + '.tmp.%d' % os.getpid()
    with open(t, 'w') as fh: json.dump(o, fh, **kw)
    os.replace(t, p)
_aw(os.environ['DIGEST'], digest, indent=2)
_aw(os.environ['SEEN'], nextseen)
new,surge,changed=digest['new'],digest['surging'],digest['changed']
ongoing=digest['ongoing_top']
def ln(it):
    g=f\" (+{it['grew']})\" if 'grew' in it else ''
    c=it.get('count',0); cs=f\"{c:>5}x{g}\" if it['channel']=='sentry' else f\"  {it.get('status','')}\"
    return f\"  [{it['channel']}] {cs}  {it['title'][:80]}\"
print(f\"Alert triage — {len(new)} NEW, {len(surge)} SURGING, {len(changed)} CHANGED, \"
      f\"{len(ongoing)} still-firing (sentry counts are LIFETIME totals; \"
      f\"ongoing = fired within {os.environ['RECENT_DAYS']}d)\")
for tag,lst in (('NEW',new),('SURGING',surge),('CHANGED',changed)):
    if lst:
        print(tag+':'); [print(ln(i)) for i in sorted(lst,key=lambda x:-x.get('grew',x.get('count',0)))[:10]]
nt=[]
for i in new[:8]: nt.append('NEW'+ln(i))
for i in surge[:8]: nt.append('SURGE'+ln(i))
for i in changed[:6]: nt.append('CHG'+ln(i))
open(os.environ['NT'],'w').write('\n'.join(nt))
"

if [ "$NOTIFY" = "1" ] && [ -s "$NT" ]; then
  MSG="🔎 Alert triage (auto) — new/surging across all channels:"$'\n'"$(cat "$NT")"
  if [ -x ./notify.sh ]; then ./notify.sh "$MSG" >/dev/null 2>&1 || echo "$MSG"; else echo "$MSG"; fi
fi
echo "digest -> $DIGEST"
