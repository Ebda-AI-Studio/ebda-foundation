#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib/os-state.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-state.sh" 2>/dev/null || true
. "$HERE/remediation/classify.sh"; . "$HERE/remediation/registry.sh"
. "$HERE/remediation/ledger.sh";   . "$HERE/remediation/gate.sh"
. "$HERE/remediation/pr-fix.sh";   . "$HERE/remediation/approve.sh"
. "$HERE/lib/work-registry.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/work-registry.sh" 2>/dev/null || true
. "$HERE/lib/autonomy.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/autonomy.sh" 2>/dev/null || true
command -v wr_claim >/dev/null 2>&1 || { echo "REGISTRY UNAVAILABLE — coordination libs failed to source; aborting to avoid uncoordinated action" >&2; exit 3; }
FINDINGS="${1:-$HOME/.whisky-os-state/dream-findings.json}"
# --only <id> [findings-file]: process ONLY the finding with this id. The
# event-driven path (findings-watch -> dispatch-route) emits one event per NEW
# finding id, so remediating the whole file per event re-ran every still-open
# finding (and every operational action) N times on a burst. Scoping to the
# triggering id makes each event do exactly its own work. Falls through to the
# full-file behaviour when --only is absent (batch/manual runs).
ONLY_ID=""
if [ "${1:-}" = "--only" ]; then
  ONLY_ID="${2:-}"
  FINDINGS="${3:-$HOME/.whisky-os-state/dream-findings.json}"
fi
DRY="${REMEDIATE_DRYRUN:-0}"
merged=0; humaned=0; excluded=0; ops=0; queued=0

emit() { echo "$1"; }

# --approve <pr>: a Telegram-approved oversize fix. Move it pending -> queue; the drain
# loop below then runs it through the gate (skipped in DRY). FINDINGS is unused here
# ("--approve" isn't a JSON file, so count falls to 0 and the findings loop is a no-op).
[ "${1:-}" = "--approve" ] && { emit "$(approve_pr "${2:?pr number required}")"; }

if autonomy_is_off && [ "${1:-}" != "--approve" ]; then
  emit "AUTONOMY OFF — autonomous remediation frozen (/resume to re-enable)"
  type write_status >/dev/null 2>&1 && write_status "remediation" "warn" "autonomy frozen (/kill)" '{"frozen":true}'
  exit 0
fi

# dream-scan.sh writes {"findings":[...]}; test fixtures use a bare [...] array — accept both.
count="$(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));a=d.get("findings",[]) if isinstance(d,dict) else d;print(len(a))' "$FINDINGS" 2>/dev/null || echo 0)"
for (( i=0; i<count; i++ )); do   # naturally a no-op when count=0 (e.g. --approve mode)
  read -r repo cls <<<"$(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));a=d.get("findings",[]) if isinstance(d,dict) else d;f=a[int(sys.argv[2])];print(f.get("repo",""),f.get("class",""))' "$FINDINGS" "$i")"
  if [ -n "$ONLY_ID" ]; then
    cur_id="$(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));a=d.get("findings",[]) if isinstance(d,dict) else d;f=a[int(sys.argv[2])];print(f.get("id") or (f.get("class","")+"-"+f.get("repo","")))' "$FINDINGS" "$i" 2>/dev/null)"
    [ "$cur_id" = "$ONLY_ID" ] || continue   # scoped run: this isn't the triggering finding
  fi
  kind="$(classify "$cls")"
  if [ "$kind" = "EXCLUDED" ]; then emit "EXCLUDED $cls"; excluded=$((excluded+1)); continue; fi
  if is_operational "$cls"; then
    emit "OPERATIONAL $cls"; ops=$((ops+1))
    [ "$DRY" = "1" ] || { case "$cls" in graph-pending) op_graphify "$HOME/Desktop/projects/$repo";; dr-dump-missing) op_dr_backup "$repo";; esac; }
    continue
  fi
  if [ "$kind" = "CLASS_B" ]; then
    fid="$(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));a=d.get("findings",[]) if isinstance(d,dict) else d;f=a[int(sys.argv[2])];print(f.get("id") or (f.get("class","")+"-"+f.get("repo","")))' "$FINDINGS" "$i")"
    # 3600s > worst-case single fix; long fixes need wr_heartbeat (Phase B/C).
    wr_claim "finding:$fid" "remediate" 3600 || { emit "SKIP $cls (claimed)"; continue; }
    emit "CLASS_B $cls"
    [ "$DRY" = "1" ] && { wr_release "finding:$fid" "remediate"; queued=$((queued+1)); continue; }
    cb_allow class-b || { emit "SKIP $cls (circuit breaker)"; wr_release "finding:$fid" "remediate"; continue; }
    finding="$(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));a=d.get("findings",[]) if isinstance(d,dict) else d;print(json.dumps(a[int(sys.argv[2])],separators=(",",":")))' "$FINDINGS" "$i")"
    res="$(pr_fix "$finding" "$HOME/Desktop/projects/$repo")"
    cb_record class-b
    case "$res" in QUEUED*) queued=$((queued+1));; PENDING*) humaned=$((humaned+1));; esac
    emit "$res"
    wr_release "finding:$fid" "remediate"
    continue
  fi
  # CLASS_A (Phase 1) deterministic fixers.
  emit "CLASS_A $cls"
  [ "$DRY" = "1" ] && { queued=$((queued+1)); continue; }
  cb_allow class-a || { emit "SKIP $cls (circuit breaker)"; continue; }
  # branch + fix + PR (real mode)
  repo_path="$HOME/Desktop/projects/$repo"; br="remediate/${cls}-$(date +%s)"
  ( cd "$repo_path" && git checkout -q -b "$br" ) || continue
  case "$cls" in lockfile-drift|dep-bump) fix_lockfile_drift "$repo_path" || { emit "FIX FAILED $cls"; continue; };; esac
  ( cd "$repo_path" && git commit -q -m "fix(remediation): $cls" && git push -q -u origin "$br" ) || continue
  pr="$(gh pr create --repo "Ebda-AI-Studio/$repo" --head "$br" --title "remediation: $cls" --body "Automated $cls fix. Gated by CI + blast-radius + AI review score." 2>/dev/null | grep -oE '[0-9]+$')"
  cb_record class-a
  qitem="$(python3 -c 'import json,sys;print(json.dumps({"pr":sys.argv[1],"slug":sys.argv[2],"branch":sys.argv[3],"repo":sys.argv[4]}))' "$pr" "Ebda-AI-Studio/$repo" "$br" "$HOME/Desktop/projects/$repo")"
  queue_add "$qitem"; queued=$((queued+1))
done

# Drain the queue ONE at a time through the single runner (16GB governance)
if [ "$DRY" != "1" ]; then
  while [ "$(queue_depth)" -gt 0 ]; do
    item="$(queue_pop)"; [ -n "$item" ] || break
    qpr="$(printf '%s' "$item" | python3 -c 'import json,sys;print(json.load(sys.stdin)["pr"])')"
    qslug="$(printf '%s' "$item" | python3 -c 'import json,sys;print(json.load(sys.stdin)["slug"])')"
    qbr="$(printf '%s' "$item" | python3 -c 'import json,sys;print(json.load(sys.stdin)["branch"])')"
    qrepo="$(printf '%s' "$item" | python3 -c 'import json,sys;print(json.load(sys.stdin)["repo"])')"
    res="$(runner_lock gate_run "$qpr" "$qslug" "$qbr" "$qrepo")" || { queue_add "$item"; break; }
    case "$res" in MERGED*) merged=$((merged+1));; HUMAN*) humaned=$((humaned+1));; esac
  done
fi

depth="$(queue_depth 2>/dev/null || echo 0)"
sev="true"; [ "$humaned" -gt 0 ] && sev="warn"
detail="$(python3 -c 'import json,sys;print(json.dumps({"merged":int(sys.argv[1]),"awaiting_human":int(sys.argv[2]),"excluded":int(sys.argv[3]),"operational":int(sys.argv[4]),"queue_depth":int(sys.argv[5])}))' "$merged" "$humaned" "$excluded" "$ops" "$depth")"
type write_status >/dev/null 2>&1 && write_status "remediation" "$sev" "$merged merged · $humaned awaiting you · $depth queued" "$detail"
[ "$humaned" -gt 0 ] && "$HERE/notify.sh" "Remediation" "$humaned PR(s) need your admin-merge" >/dev/null 2>&1 || true
