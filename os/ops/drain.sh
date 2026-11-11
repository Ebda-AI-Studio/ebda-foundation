#!/usr/bin/env bash
# Ebda AI OS - drain.sh: the durable merge loop for ONE repo (replaces the controller's drain2.sh / drain-fdn.sh).
#
#   drain.sh --repo OWNER/NAME --dir CHECKOUT [--gate PATH] [--hold-risky] [--name N] [--interval S]
#            [--stall-min 60] [--held-min 120] [--max-wait-min 20] [--once]
#
# Every cycle: list open PRs into main that are green and mergeable, and merge each through the merge gate (head pinned, three
# consecutive polls, explicit required checks: never `gh pr merge` directly). With --hold-risky a PR labelled `risky-path` (set by
# the ai-review workflow) waits until it also carries `ai-review-passed`.
#   --gate     the merge-gate script, absolute or relative to --dir (default: $HOME/.claude/scripts/merge-gate.sh). It runs as
#              `<gate> <pr> <sha> --repo R --interval 30 --max-wait-min M`. DRAIN_REQUIRED_JSON, when set, becomes MERGE_GATE_REQUIRED_JSON.
#   --once     one cycle, then exit (tests, manual runs).
# Safety:
#   - OFF until switched over: does nothing unless $OS_STATE_DIR/drain/<name>.enabled exists (so installing the launchd job never
#     races a controller's own loop). Turn on: touch it. Turn off: rm it, or touch <name>.stop. A global ~/.claude/handoff/drain.stop
#     also stops it (same file the controller loops honour).
#   - one instance per repo (lock drain-<name>) and one gate per PR (lock drain-<name>-pr<N>, plus a gate-process check): launchd
#     restarts it every 5 minutes, a second copy exits at once.
#   - a PR whose gate failed is not retried on the same head for 10 minutes.
# Heartbeat + stall: every cycle writes $OS_STATE_DIR/drain/<name>.heartbeat and the os-state status; every 10 minutes it POSTs a
# findings snapshot (source drain-<name>) to the brain. Progress = a merge, or nothing waiting. Eligible PRs waiting with no progress for
# --stall-min opens ONE finding `drain-stall` (P1; the brain alerts once per finding and resolves it when the next snapshot omits it);
# risky PRs held longer than --held-min open `drain-held` (digest). Brain unreachable: the finding stays visible in the heartbeat file.
# Exit: 0 normally / when off or stopped, 2 usage.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/args.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/args.sh" || exit 2
args_help "${BASH_SOURCE[0]}" "$@"
REPO=""; DIR=""; GATE="$HOME/.claude/scripts/merge-gate.sh"; HOLD=0; NAME=""; INTERVAL=60; STALL_MIN=60; HELD_MIN=120; MAXWAIT=20; ONCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:?}"; shift ;; --dir) DIR="${2:?}"; shift ;; --gate) GATE="${2:?}"; shift ;; --hold-risky) HOLD=1 ;;
    --name) NAME="${2:?}"; shift ;; --interval) INTERVAL="${2:?}"; shift ;; --stall-min) STALL_MIN="${2:?}"; shift ;;
    --held-min) HELD_MIN="${2:?}"; shift ;; --max-wait-min) MAXWAIT="${2:?}"; shift ;; --once) ONCE=1 ;;
    *) args_unknown "${BASH_SOURCE[0]}" "$1" ;;
  esac
  shift
done
[ -n "$REPO" ] && [ -n "$DIR" ] || { echo "drain: --repo and --dir are required (try --help)" >&2; exit 2; }
case "$REPO" in */*) ;; *) echo "drain: --repo must be OWNER/NAME" >&2; exit 2 ;; esac
whole() { case "$2" in ''|*[!0-9]*) echo "drain: $1 must be a whole number" >&2; exit 2 ;; esac; }
whole --interval "$INTERVAL"; whole --stall-min "$STALL_MIN"; whole --held-min "$HELD_MIN"; whole --max-wait-min "$MAXWAIT"
[ -n "$NAME" ] || NAME="${REPO##*/}"
case "$NAME" in *[!A-Za-z0-9._-]*|'') echo "drain: --name must be [A-Za-z0-9._-]" >&2; exit 2 ;; esac
[ -d "$DIR" ] || { echo "drain: --dir $DIR does not exist" >&2; exit 2; }
case "$GATE" in /*) ;; *) GATE="$DIR/$GATE" ;; esac
[ -n "${DRAIN_REQUIRED_JSON:-}" ] && export MERGE_GATE_REQUIRED_JSON="$DRAIN_REQUIRED_JSON"

# shellcheck source=lib/os-config.sh
. "$HERE/lib/os-config.sh" 2>/dev/null && os_config_load 2>/dev/null || true
# shellcheck source=lib/single-instance.sh
. "$HERE/lib/single-instance.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/single-instance.sh" || exit 2
# shellcheck source=lib/brain-post.sh
. "$HERE/lib/brain-post.sh" 2>/dev/null || true
. "$HERE/lib/os-state.sh" 2>/dev/null || true
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"

SD="${OS_STATE_DIR:-$HOME/.whisky-os-state}/drain"; mkdir -p "$SD"
ENABLED="$SD/$NAME.enabled"; STOP="$SD/$NAME.stop"; GLOBAL_STOP="$HOME/.claude/handoff/drain.stop"
HB="$SD/$NAME.heartbeat"; PROG="$SD/$NAME.progress"; POSTED="$SD/$NAME.last-post"
log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*"; }
halted() { [ -f "$STOP" ] || [ -f "$GLOBAL_STOP" ]; }
[ -f "$ENABLED" ] || { log "drain $NAME: not switched over ($ENABLED absent); idle"; exit 0; }
halted && { log "drain $NAME: stop file present; idle"; exit 0; }
single_instance "drain-$NAME"

epoch() { date +%s; }
read_int() { local v; v="$(cat "$1" 2>/dev/null || true)"; case "$v" in ''|*[!0-9]*) echo 0 ;; *) echo "$v" ;; esac; }

# prints "<pr> <sha> <risky 0|1> <passed 0|1>" per green+mergeable PR; exit 3 when GitHub cannot be read (unknown is not "nothing")
list_ready() {
  local raw; raw="$(gh pr list --repo "$REPO" --state open --base main --limit 60 --json number,mergeable,statusCheckRollup,isDraft,labels,headRefOid 2>/dev/null)" || return 3
  printf '%s' "$raw" | python3 -I -c '
import json, sys
for p in json.load(sys.stdin):
    if p.get("isDraft") or p.get("mergeable") != "MERGEABLE": continue
    cs = p.get("statusCheckRollup") or []
    if not cs: continue                      # zero checks is "CI has not started", never green
    ok = True
    for c in cs:
        st = c.get("status") or ("COMPLETED" if c.get("state") in ("SUCCESS", "FAILURE", "ERROR") else "PENDING")
        co = c.get("conclusion") or {"SUCCESS": "SUCCESS", "FAILURE": "FAILURE", "ERROR": "FAILURE"}.get(c.get("state"), "")
        if st != "COMPLETED" or co in ("FAILURE", "CANCELLED", "TIMED_OUT", "STARTUP_FAILURE", "ACTION_REQUIRED"): ok = False; break
    if not ok: continue
    names = {l.get("name") for l in p.get("labels") or []}
    print(p["number"], p["headRefOid"], int("risky-path" in names), int("ai-review-passed" in names))
' 2>/dev/null || return 3
}

# PR numbers repeat across repos: match this repo too, or a gate on another repo's #N would skip ours
gate_running() { pgrep -f "merge-gate.sh $1 .*--repo $REPO " >/dev/null 2>&1; }

cycle() {
  local ready rc now merged=0 eligible=0 held=0 p sha risky passed fk fail_at oldest_held hf a
  now="$(epoch)"
  ready="$(list_ready)"; rc=$?
  if [ "$rc" -ne 0 ]; then log "cannot read PRs of $REPO; skipping this cycle (no progress claimed, no stall judged)"; return 3; fi
  oldest_held=0
  while read -r p sha risky passed; do
    [ -n "$p" ] || continue
    if [ "$HOLD" = 1 ] && [ "$risky" = 1 ] && [ "$passed" != 1 ]; then
      held=$((held + 1)); log "HOLD #$p risky, awaiting ai-review-passed"
      hf="$SD/$NAME.held.$p"; [ -f "$hf" ] || epoch > "$hf"
      continue
    fi
    eligible=$((eligible + 1))
    fk="$SD/$NAME.failed.$p.$sha"; fail_at="$(read_int "$fk")"
    if [ "$fail_at" -gt 0 ] && [ $((now - fail_at)) -lt 600 ]; then log "skip #$p ${sha:0:8}: gate failed $((now - fail_at))s ago"; continue; fi
    gate_running "$p" && { log "skip #$p: a gate is already running"; continue; }
    si_acquire "drain-$NAME-pr$p" >/dev/null 2>&1 || { log "skip #$p: another drain holds it"; continue; }
    log "gate #$p ${sha:0:8}"
    if "$GATE" "$p" "$sha" --repo "$REPO" --interval 30 --max-wait-min "$MAXWAIT"; then
      log "MERGED #$p"; merged=$((merged + 1)); epoch > "$PROG"; rm -f "$SD/$NAME.held.$p"
    else
      log "gate failed #$p ${sha:0:8}"; epoch > "$fk"
    fi
    si_release "drain-$NAME-pr$p"
  done <<EOF2
$ready
EOF2
  # forget held markers of PRs that are no longer held (merged, closed, or reviewed)
  for hf in "$SD/$NAME.held."*; do
    [ -f "$hf" ] || continue; p="${hf##*.held.}"
    printf '%s\n' "$ready" | awk -v n="$p" '$1==n && $4!=1 {f=1} END{exit !f}' || rm -f "$hf"
  done
  # nothing waiting is progress; a merge already stamped it
  [ "$eligible" -eq 0 ] && epoch > "$PROG"
  for hf in "$SD/$NAME.held."*; do
    [ -f "$hf" ] || continue
    a="$(read_int "$hf")"
    if [ "$oldest_held" -eq 0 ] || [ "$a" -lt "$oldest_held" ]; then oldest_held="$a"; fi
  done
  CYC_ELIGIBLE="$eligible"; CYC_HELD="$held"; CYC_MERGED="$merged"; CYC_OLDEST_HELD="$oldest_held"
  return 0
}

heartbeat() { # $1 = cycle rc
  local now prog stalled=0 heldlong=0 stall_age=0 findings="[]" summary last
  now="$(epoch)"; prog="$(read_int "$PROG")"; [ "$prog" -gt 0 ] || { epoch > "$PROG"; prog="$now"; }
  if [ "$1" = 0 ]; then
    stall_age=$(( (now - prog) / 60 ))
    [ "${CYC_ELIGIBLE:-0}" -gt 0 ] && [ "$stall_age" -ge "$STALL_MIN" ] && stalled=1
    [ "${CYC_OLDEST_HELD:-0}" -gt 0 ] && [ $(( (now - CYC_OLDEST_HELD) / 60 )) -ge "$HELD_MIN" ] && heldlong=1
    findings="$(python3 -I - "$REPO" "$NAME" "$stalled" "$heldlong" "${CYC_ELIGIBLE:-0}" "${CYC_HELD:-0}" "$stall_age" "$STALL_MIN" "$HELD_MIN" <<'PY'
import json, sys
repo, name, stalled, held, elig, nheld, age, smin, hmin = sys.argv[1:10]
out = []
if stalled == "1":
    out.append({"source": "drain-" + name, "kind": "drain-stall", "key": repo, "repo": repo, "severity": "P1",
                "title": "drain for %s is stalled: %s green PR(s) waiting, no merge for %s min" % (repo, elig, age),
                "detail": {"eligible": int(elig), "minutesWithoutProgress": int(age), "stallMin": int(smin)}})
if held == "1":
    out.append({"source": "drain-" + name, "kind": "drain-held", "key": repo + "|held", "repo": repo, "severity": "P2",
                "title": "%s risky PR(s) in %s have waited over %s min for ai-review-passed (is the review secret set?)" % (nheld, repo, hmin),
                "detail": {"held": int(nheld), "heldMin": int(hmin)}})
print(json.dumps(out))
PY
)"
  fi
  summary="eligible=${CYC_ELIGIBLE:-?} held=${CYC_HELD:-?} merged=${CYC_MERGED:-0} stalled=$stalled"
  printf '{"at":%s,"cycleRc":%s,"stalled":%s,"heldLong":%s,"minutesWithoutProgress":%s}\n' "$now" "$1" \
    "$([ "$stalled" = 1 ] && echo true || echo false)" "$([ "$heldlong" = 1 ] && echo true || echo false)" "$stall_age" > "$HB"
  if command -v write_status >/dev/null 2>&1; then
    if [ "$stalled" = 1 ]; then write_status "drain-$NAME" false "$summary" '{}'; else write_status "drain-$NAME" true "$summary" '{}'; fi
  fi
  [ "$1" = 0 ] || return 0
  last="$(read_int "$POSTED")"
  # post every 10 min, and at once when the finding set changed (opened or cleared)
  if [ $((now - last)) -ge 600 ] || [ "$findings" != "$(cat "$SD/$NAME.last-findings" 2>/dev/null)" ]; then
    if command -v _brain_env >/dev/null 2>&1; then
      _brain_env
      if [ -n "${OS_BRAIN_URL:-}" ] && [ -n "${INGEST_TOKEN:-}" ] && [ "${DRY_RUN:-0}" != 1 ]; then
        python3 -I -c 'import json,sys; print(json.dumps({"findings": json.loads(sys.argv[1]), "reconcile": {"source": "drain-" + sys.argv[2], "keep": []}}))' "$findings" "$NAME" > "$SD/$NAME.snapshot.json"
        if curl -fsS -m 30 -o /dev/null -X POST "${OS_BRAIN_URL%/}/findings" -H "Authorization: Bearer $INGEST_TOKEN" -H 'content-type: application/json' --data-binary "@$SD/$NAME.snapshot.json" 2>/dev/null; then
          epoch > "$POSTED"; printf '%s' "$findings" > "$SD/$NAME.last-findings"
        else log "brain unreachable: heartbeat not delivered (local heartbeat file is current)"; fi
      fi
    fi
  fi
}

while :; do
  halted && { log "drain $NAME: stop file; exiting"; exit 0; }
  [ -f "$ENABLED" ] || { log "drain $NAME: switched off; exiting"; exit 0; }
  CYC_ELIGIBLE=0; CYC_HELD=0; CYC_MERGED=0; CYC_OLDEST_HELD=0
  cycle; crc=$?
  heartbeat "$crc"
  [ "$ONCE" = 1 ] && exit 0
  sleep "$INTERVAL"
done
