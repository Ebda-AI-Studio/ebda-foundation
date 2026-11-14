#!/usr/bin/env bash
# Ebda AI OS — main-first CI.
#
# Problem (measured 3x on 2026-11-14): the main-branch CI run of ebda-store sat `queued` for hours because the
# self-hosted heavy runners (labels self-hosted + ebda-mac) were taken by pull_request runs; GitHub does not
# schedule self-hosted jobs FIFO across runs. While main CI is not green the merge drain only merges fixes-main PRs,
# so every other approved PR stalls. This script does by machine what the controller did by hand.
#
# Per repo in $MAIN_FIRST_REPOS, if the NEWEST main CI run is queued/in_progress AND any of its jobs has been
# queued longer than $MAIN_FIRST_MIN minutes (default 10):
#   1. cancel OLDER main CI runs whose head is an ancestor of the newest main head (superseded);
#   2. cancel QUEUED pull_request runs holding a queued job that asks for the heavy label ($MAIN_FIRST_LABEL,
#      default ebda-mac) - never in_progress runs, never a branch in $MAIN_FIRST_ALLOW_BRANCHES or a PR labelled
#      $MAIN_FIRST_ALLOW_LABEL (default fixes-main); one PR comment per head;
#   3. once the newest main CI run completes `success`, re-run the cancelled PR runs once (approved PRs first,
#      oldest approval first), at most $MAIN_FIRST_RERUN_CAP (default 2) per tick; a run whose PR closed or whose head
#      moved (a push already started a fresh run) is dropped, not re-run. Entries expire after 24 h.
# Every GitHub read is gathered BEFORE any mutation; an API failure (5xx/504/bad JSON) skips that repo for this tick.
# Idempotent: state is $MAIN_FIRST_STATE (cancelled-run ledger + commented heads). --dry-run mutates nothing.
# Log: ~/Library/Logs/ebda-main-first.log. Exit 0 always except usage errors (2).
# Seams: gh from PATH, MAIN_FIRST_{REPOS,MIN,LABEL,ALLOW_BRANCHES,ALLOW_LABEL,RERUN_CAP,WORKFLOW,STATE,LOG,NOW}.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/os-state.sh
. "$HERE/lib/os-state.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-state.sh" 2>/dev/null || true
command -v _ut >/dev/null 2>&1 || _ut() { shift; "$@"; }
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"

DRY=0
case "${1:-}" in
  --dry-run) DRY=1 ;;
  -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
  '') ;;
  *) echo "main-first: unknown arg $1 (only --dry-run)" >&2; exit 2 ;;
esac

REPOS="${MAIN_FIRST_REPOS:-Ebda-AI-Studio/ebda-store Ebda-AI-Studio/ebda-whatsapp Ebda-AI-Studio/ebda-foundation}"
MIN="${MAIN_FIRST_MIN:-10}"
LABEL="${MAIN_FIRST_LABEL:-ebda-mac}"
ALLOW_BRANCHES="${MAIN_FIRST_ALLOW_BRANCHES:-}"
ALLOW_LABEL="${MAIN_FIRST_ALLOW_LABEL:-fixes-main}"
CAP="${MAIN_FIRST_RERUN_CAP:-2}"
WORKFLOW="${MAIN_FIRST_WORKFLOW:-CI}"
STATE="${MAIN_FIRST_STATE:-$HOME/.whisky-os-state/main-first}"
LOG="${MAIN_FIRST_LOG:-$HOME/Library/Logs/ebda-main-first.log}"
NOW="${MAIN_FIRST_NOW:-$(date +%s)}"
GH_TIMEOUT="${GH_TIMEOUT:-45}"
for v in MIN CAP; do case "${!v}" in ''|*[!0-9]*) echo "main-first: $v must be a whole number" >&2; exit 2 ;; esac; done
mkdir -p "$STATE" "$(dirname "$LOG")" 2>/dev/null || true

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG"; }

# one run at a time (launchd tick vs a manual run); a lock older than 10 min is dead
LOCK="$STATE/lock.d"
if ! mkdir "$LOCK" 2>/dev/null; then
  if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +10 2>/dev/null)" ]; then rmdir "$LOCK" 2>/dev/null; mkdir "$LOCK" 2>/dev/null || exit 0
  else log "skip: another main-first run holds the lock"; exit 0; fi
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

# gh GET -> stdout; non-zero on any failure (5xx/504/timeout) or non-JSON body
api() {
  local out
  out="$(_ut "$GH_TIMEOUT" gh api "$@" 2>/dev/null)" || return 1
  printf '%s' "$out" | python3 -c 'import sys,json; json.load(sys.stdin)' 2>/dev/null || return 1
  printf '%s' "$out"
}
# mutation wrapper: honours --dry-run
act() { # <description> <gh args...>
  local desc="$1"; shift
  if [ "$DRY" = 1 ]; then log "DRYRUN would $desc"; return 0; fi
  if _ut "$GH_TIMEOUT" gh api "$@" >/dev/null 2>&1; then log "$desc"; return 0; fi
  log "FAILED $desc"; return 1
}
# jq-ish helper: py '<expr over d>' reads JSON on stdin
py() { python3 -c 'import sys,json; d=json.load(sys.stdin); '"$1" 2>/dev/null; }

process_repo() {
  local repo="$1" slug; slug="${repo//\//__}"
  local ledger="$STATE/$slug.cancelled.tsv" commented="$STATE/$slug.commented"
  touch "$ledger" "$commented"

  # ---- gather (no mutation until everything needed is in hand) ----
  local mains; mains="$(api "repos/$repo/actions/runs?branch=main&event=push&per_page=30")" || { log "$repo: API failure reading main runs, skip tick"; return; }
  local newest
  newest="$(printf '%s' "$mains" | WF="$WORKFLOW" python3 -c '
import sys,json,os
d=json.load(sys.stdin)
r=[x for x in d.get("runs",[]) if x.get("name")==os.environ["WF"]]
r.sort(key=lambda x:x.get("created_at",""),reverse=True)
print(json.dumps(r[0]) if r else "")' 2>/dev/null)" || { log "$repo: bad main runs JSON, skip tick"; return; }
  [ -n "$newest" ] || { log "$repo: no main $WORKFLOW run found"; return; }
  local nid nsha nstatus nconc
  nid="$(printf '%s' "$newest" | py 'print(d["id"])')"; nsha="$(printf '%s' "$newest" | py 'print(d["head_sha"])')"
  nstatus="$(printf '%s' "$newest" | py 'print(d["status"])')"; nconc="$(printf '%s' "$newest" | py 'print(d.get("conclusion") or "")')"
  [ -n "$nid" ] && [ -n "$nsha" ] || { log "$repo: unparsable newest main run, skip tick"; return; }

  # ---- phase 3: main completed green -> re-request cancelled PR runs ----
  if [ "$nstatus" = "completed" ]; then
    if [ "$nconc" = "success" ]; then rerun_cancelled "$repo" "$ledger" "$nid"; else log "$repo: newest main run $nid completed $nconc; nothing re-run"; fi
    return
  fi
  [ "$nstatus" = "queued" ] || [ "$nstatus" = "in_progress" ] || { log "$repo: newest main run $nid is $nstatus; no action"; return; }

  # ---- is main starved? any job of the newest run queued > MIN minutes ----
  local njobs; njobs="$(api "repos/$repo/actions/runs/$nid/jobs?per_page=100")" || { log "$repo: API failure reading jobs of $nid, skip tick"; return; }
  local starved
  starved="$(printf '%s' "$njobs" | NOW="$NOW" MIN="$MIN" python3 -c '
import sys,json,os,datetime
d=json.load(sys.stdin); now=int(os.environ["NOW"]); lim=int(os.environ["MIN"])*60
def ep(s): return int(datetime.datetime.strptime(s,"%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc).timestamp())
ages=[now-ep(j["created_at"]) for j in d.get("jobs",[]) if j.get("status")=="queued"]
m=max(ages) if ages else 0
print(m//60 if m>lim else "")' 2>/dev/null)" || { log "$repo: bad jobs JSON, skip tick"; return; }
  [ -n "$starved" ] || { log "$repo: main run $nid not starved (no job queued > ${MIN}m); no action"; return; }
  log "$repo: main run $nid ($nsha) has a job queued ~${starved}m > ${MIN}m: acting"

  # superseded main runs
  local older; older="$(printf '%s' "$mains" | WF="$WORKFLOW" NID="$nid" python3 -c '
import sys,json,os
d=json.load(sys.stdin)
for x in d.get("runs",[]):
    if x.get("name")==os.environ["WF"] and str(x["id"])!=os.environ["NID"] and x.get("status") in ("queued","in_progress"):
        print(x["id"],x["head_sha"])' 2>/dev/null)" || { log "$repo: bad main runs JSON, skip tick"; return; }
  local to_cancel_main=() oid osha cmp
  while read -r oid osha; do
    [ -n "$oid" ] || continue
    cmp="$(api "repos/$repo/compare/$osha...$nsha")" || { log "$repo: API failure on compare $osha...$nsha, skip tick"; return; }
    case "$(printf '%s' "$cmp" | py 'print(d.get("status",""))')" in
      ahead|identical) to_cancel_main+=("$oid:$osha") ;;
      *) log "$repo: main run $oid ($osha) is not an ancestor of $nsha; kept" ;;
    esac
  done <<<"$older"

  # queued PR runs asking for the heavy label
  local prruns; prruns="$(api "repos/$repo/actions/runs?status=queued&event=pull_request&per_page=100")" || { log "$repo: API failure reading queued PR runs, skip tick"; return; }
  local cand; cand="$(printf '%s' "$prruns" | python3 -c '
import sys,json
d=json.load(sys.stdin)
for x in d.get("runs",[]):
    if x.get("status")!="queued": continue
    prs=x.get("pull_requests") or []
    print(x["id"], x.get("head_branch",""), x.get("head_sha",""), prs[0]["number"] if prs else 0)' 2>/dev/null)" || { log "$repo: bad PR runs JSON, skip tick"; return; }
  local to_cancel_pr=() rid br sha prn jobs labels
  while read -r rid br sha prn; do
    [ -n "$rid" ] || continue
    case ",$ALLOW_BRANCHES," in *",$br,"*) log "$repo: PR run $rid branch $br allowlisted; untouched"; continue ;; esac
    jobs="$(api "repos/$repo/actions/runs/$rid/jobs?per_page=100")" || { log "$repo: API failure reading jobs of $rid, skip tick"; return; }
    printf '%s' "$jobs" | LABEL="$LABEL" python3 -c '
import sys,json,os
d=json.load(sys.stdin)
sys.exit(0 if any(j.get("status")=="queued" and os.environ["LABEL"] in (j.get("labels") or []) for j in d.get("jobs",[])) else 1)' 2>/dev/null || continue
    if [ "$prn" != 0 ]; then
      labels="$(api "repos/$repo/issues/$prn/labels")" || { log "$repo: API failure reading labels of #$prn, skip tick"; return; }
      if printf '%s' "$labels" | AL="$ALLOW_LABEL" python3 -c '
import sys,json,os
sys.exit(0 if any(l.get("name")==os.environ["AL"] for l in json.load(sys.stdin)) else 1)' 2>/dev/null; then
        log "$repo: PR #$prn run $rid labelled $ALLOW_LABEL; untouched"; continue
      fi
    fi
    to_cancel_pr+=("$rid:$sha:$prn:$br")
  done <<<"$cand"

  # ---- mutate ----
  local e rest
  for e in "${to_cancel_main[@]+"${to_cancel_main[@]}"}"; do
    act "cancel superseded main run ${e%%:*} ($repo, head ${e#*:})" -X POST "repos/$repo/actions/runs/${e%%:*}/cancel" || true
  done
  for e in "${to_cancel_pr[@]+"${to_cancel_pr[@]}"}"; do
    rid="${e%%:*}"; rest="${e#*:}"; sha="${rest%%:*}"; rest="${rest#*:}"; prn="${rest%%:*}"
    if act "cancel queued PR run $rid ($repo PR #$prn, head $sha) so main CI $nid gets a runner" -X POST "repos/$repo/actions/runs/$rid/cancel"; then
      [ "$DRY" = 1 ] || printf '%s\t%s\t%s\t%s\n' "$rid" "$prn" "$sha" "$NOW" >> "$ledger"
      if [ "$prn" != 0 ] && ! grep -qx "$prn:$sha" "$commented"; then
        if act "comment on $repo#$prn (head $sha)" -X POST "repos/$repo/issues/$prn/comments" -f "body=CI re-run deferred: main CI first (main run $nid is waiting for a heavy runner). Push or re-run to retry; the OS re-requests this run once main is green."; then
          [ "$DRY" = 1 ] || echo "$prn:$sha" >> "$commented"
        fi
      fi
    fi
  done
  log "$repo: done (cancelled ${#to_cancel_main[@]} superseded main, ${#to_cancel_pr[@]} queued PR runs)"
}

rerun_cancelled() { # <repo> <ledger> <main run id>
  local repo="$1" ledger="$2" nid="$3"
  [ -s "$ledger" ] || return 0
  local rid prn sha ts pr st hsha ap tmp done_n=0 rows="" drops="" cleared=""
  # resolve each entry (PR open? head unchanged? approval time) BEFORE any re-run
  while IFS=$'\t' read -r rid prn sha ts; do
    [ -n "$rid" ] || continue
    if [ $((NOW - ts)) -gt 86400 ]; then log "$repo: ledger entry run $rid expired (>24h); dropped"; drops="$drops $rid"; continue; fi
    if [ "$prn" = 0 ]; then rows="$rows"$'\n'"9999999999 $ts $rid $prn $sha"; continue; fi
    pr="$(api "repos/$repo/pulls/$prn")" || { log "$repo: API failure reading PR #$prn, skip tick"; return; }
    st="$(printf '%s' "$pr" | py 'print(d.get("state",""))')"; hsha="$(printf '%s' "$pr" | py 'print(d["head"]["sha"])')"
    if [ "$st" != open ] || [ "$hsha" != "$sha" ]; then log "$repo: PR #$prn closed or head moved; run $rid dropped from ledger"; drops="$drops $rid"; continue; fi
    ap="$(api "repos/$repo/pulls/$prn/reviews?per_page=100")" || { log "$repo: API failure reading reviews of #$prn, skip tick"; return; }
    ap="$(printf '%s' "$ap" | python3 -c '
import sys,json
d=json.load(sys.stdin); last={}
for r in sorted(d,key=lambda r:r.get("submitted_at","")): last[r["user"]["login"]]=r
t=sorted(r["submitted_at"] for r in last.values() if r.get("state")=="APPROVED")
print(t[0] if t else "")' 2>/dev/null)" || ap=""
    # approved first (key = approval time), unapproved after
    if [ -n "$ap" ]; then rows="$rows"$'\n'"0$ap $ts $rid $prn $sha"; else rows="$rows"$'\n'"9999999999 $ts $rid $prn $sha"; fi
  done < "$ledger"
  local key _t
  while read -r key _t rid prn sha; do
    [ -n "$rid" ] || continue
    if [ "$done_n" -ge "$CAP" ]; then log "$repo: rerun cap $CAP reached; run $rid waits for the next tick"; continue; fi
    if act "re-request cancelled run $rid ($repo PR #$prn, head $sha) after main run $nid went green" -X POST "repos/$repo/actions/runs/$rid/rerun"; then
      done_n=$((done_n+1)); cleared="$cleared $rid"
    fi
  done <<<"$(printf '%s\n' "$rows" | sort)"
  [ "$DRY" = 1 ] && return 0
  tmp="$ledger.tmp"; : > "$tmp"
  while IFS=$'\t' read -r rid prn sha ts; do
    [ -n "$rid" ] || continue
    case " $cleared $drops " in *" $rid "*) continue ;; esac
    printf '%s\t%s\t%s\t%s\n' "$rid" "$prn" "$sha" "$ts" >> "$tmp"
  done < "$ledger"
  mv -f "$tmp" "$ledger"
}

log "tick start (dry=$DRY repos: $REPOS)"
for r in $REPOS; do process_repo "$r"; done
if [ "$DRY" = 0 ] && command -v write_status >/dev/null 2>&1; then write_status main-first true "main-first tick ok" '{}'; fi
exit 0
