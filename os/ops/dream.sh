#!/usr/bin/env bash
# ============================================================
# Ebda AI OS - dream.sh   (orchestrator - the dreaming cycle, Mac side)
#
# Runs on the Mac because it reads local memory and runs the Claude CLI. Its OUTPUT goes to the brain, not to a chat:
# the cycle's findings are POSTed to the brain's findings endpoint (lib/brain-post.sh), which queues them as jobs;
# with no brain configured they are spooled to $OS_STATE_DIR/brain-spool.ndjson. Nothing here messages anyone.
#
# Phases (a phase whose script is not installed is reported "absent", never silently "ok"):
#   1 LEARN   dream-research.sh   (external CVE / ecosystem digest)
#   2 SCAN    dream-scan.sh       (lockfile drift, audits; deep on Sundays)
#   2.5 REFLECT dream-reflect.sh  (deep/weekly only: recurring memory lessons with no enforcement mechanism)
#   3 ACT     dream-act.sh        (classify + dispatch fixes)
#   3.5 STANDARD-DRIFT dream-standard-drift.sh (propose-only: memory lesson -> os/standard draft PR / issue)
#   4 LEARN-BACK  ledger entry     5 HAND-OFF  findings -> brain
# Ebda-only (Ahmad 2026-11-06): targets come from the Ebda memory and ~/.ebda-os.local.json lists, never the predecessor's products.
#
# Usage: dream.sh [--daily|--weekly] [--notify (accepted, ignored)] [--always (ignored)]
#        dream.sh --reflect-only          # just the reflect phase + hand-off (the midweek reflect job)
#        DRY_RUN=1 dream.sh --weekly      # end to end, no writes, nothing posted
# Env: DREAM_PHASES_DIR (where phase scripts live; default: next to this script, for tests)
# ============================================================
set -uo pipefail
_SCRIPT_DIR="${DREAM_PHASES_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
_OPS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/os-config.sh
. "$_OPS_DIR/lib/os-config.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-config.sh" 2>/dev/null || true
command -v os_config_load >/dev/null 2>&1 && os_config_load
# shellcheck source=lib/brain-post.sh
. "$_OPS_DIR/lib/brain-post.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/brain-post.sh" 2>/dev/null || true

SVC_ENV="${WHISKY_SERVICES_ENV:-$OS_SERVICES_ENV}"
[ -f "$SVC_ENV" ] && { set -a; . "$SVC_ENV"; set +a; }

STATE_DIR="$OS_STATE_DIR"; mkdir -p "$STATE_DIR"
LEDGER_FILE="$STATE_DIR/dream-ledger.json"
FINDINGS_FILE="$STATE_DIR/dream-findings.json"
DRY_RUN="${DRY_RUN:-0}"
FORCE_WEEKLY=0; ONLY_REFLECT=0
for _arg in "$@"; do case "$_arg" in --weekly) FORCE_WEEKLY=1 ;; --reflect-only) ONLY_REFLECT=1; FORCE_WEEKLY=1 ;; esac; done

_log()  { printf '[dream] %s\n' "$*" >&2; }
_info() { printf '%s\n' "$*"; }
_sep()  { _info "------------------------------------------------------------"; }
_now_iso() { python3 -I -c "import datetime; print(datetime.datetime.now().isoformat(timespec='seconds'))"; }

DEEP=0
if [ "$FORCE_WEEKLY" = 1 ]; then DEEP=1
elif python3 -I -c "import datetime,sys; sys.exit(0 if datetime.datetime.now().weekday()==6 else 1)"; then DEEP=1; _log "Sunday: deep weekly run"; fi

# run_phase <name> <script> [args...] -> sets PHASE_STATUS (ok | exit:N | absent)
run_phase() {
  local name="$1" script="$2"; shift 2
  if [ ! -f "$_SCRIPT_DIR/$script" ]; then _info "  $name: $script not installed - absent"; PHASE_STATUS="absent"; return 0; fi
  local rc=0
  DRY_RUN="$DRY_RUN" bash "$_SCRIPT_DIR/$script" "$@" 2>&1 || rc=$?
  [ "$rc" != 0 ] && _log "WARN: $script exited $rc (continuing)"
  PHASE_STATUS="$([ "$rc" = 0 ] && echo ok || echo "exit:$rc")"
}

START_ISO=$(_now_iso)
_info ""; _info "Ebda AI OS - Dreaming Cycle ($([ "$DEEP" = 1 ] && echo weekly || echo daily))"
# a fresh cycle starts from a fresh findings file: the scan writes it, reflect extends it
[ "$DRY_RUN" = 1 ] || rm -f "$FINDINGS_FILE"

if [ "$ONLY_REFLECT" = 1 ]; then P1="skipped:reflect-only"; P2="$P1"; P3="$P1"; P35="$P1"
else
_sep; _info "  PHASE 1: LEARN"; run_phase learn dream-research.sh; P1="$PHASE_STATUS"
_sep; _info "  PHASE 2: SCAN"; if [ "$DEEP" = 1 ]; then run_phase scan dream-scan.sh --deep; else run_phase scan dream-scan.sh; fi; P2="$PHASE_STATUS"
fi
if [ "$DEEP" = 1 ]; then _sep; _info "  PHASE 2.5: REFLECT"; run_phase reflect dream-reflect.sh; P25="$PHASE_STATUS"; else P25="skipped:daily"; fi
if [ "$ONLY_REFLECT" != 1 ]; then
_sep; _info "  PHASE 3: ACT"; run_phase act dream-act.sh; P3="$PHASE_STATUS"
_sep; _info "  PHASE 3.5: STANDARD-DRIFT"; run_phase standard-drift dream-standard-drift.sh; P35="$PHASE_STATUS"
fi

# ---------- PHASE 4: LEARN-BACK ----------
END_ISO=$(_now_iso)
_sep; _info "  PHASE 4: LEARN-BACK"
SUMMARY="$(python3 -I - "$FINDINGS_FILE" "$START_ISO" "$END_ISO" "$([ "$DEEP" = 1 ] && echo weekly || echo daily)" "$P1" "$P2" "$P25" "$P3" "$P35" <<'PY'
import json, sys
ff, start, end, mode, p1, p2, p25, p3, p35 = sys.argv[1:10]
fs = []
try: fs = json.load(open(ff)).get("findings") or []
except Exception: pass
print(json.dumps({"type": "learn-back", "run_mode": mode, "started_at": start, "ended_at": end,
    "total_findings": len(fs), "autofixable": sum(1 for f in fs if f.get("autofixable")),
    "critical_count": sum(1 for f in fs if f.get("severity") == "critical"),
    "high_count": sum(1 for f in fs if f.get("severity") == "high"),
    "repos_affected": sorted({f.get("repo") for f in fs if f.get("repo")}),
    "phases_status": {"research": p1, "scan": p2, "reflect": p25, "act": p3, "standard_drift": p35}}))
PY
)"
if [ "$DRY_RUN" = 1 ]; then
  _info "DRY_RUN: would append learn-back note to $LEDGER_FILE: $SUMMARY"
else
  python3 -I - "$LEDGER_FILE" "$SUMMARY" <<'PY'
import json, os, sys, datetime
p, entry = sys.argv[1], json.loads(sys.argv[2])
try: led = json.load(open(p)) if os.path.isfile(p) else {"entries": [], "created_at": datetime.datetime.now().isoformat(timespec="seconds")}
except Exception: led = {"entries": []}
led.setdefault("entries", []).append(entry)
t = p + ".tmp.%d" % os.getpid()
json.dump(led, open(t, "w"), indent=2); os.replace(t, p)
print("[dream] learn-back note appended to " + p)
PY
fi

# ---------- PHASE 5: HAND-OFF to the brain (act, not ping) ----------
_sep; _info "  PHASE 5: HAND-OFF (findings -> brain job queue)"
if [ -f "$FINDINGS_FILE" ] && command -v brain_post_findings >/dev/null 2>&1; then
  _tmp="$(mktemp)"; brain_dream_to_findings "$FINDINGS_FILE" > "$_tmp"
  brain_post_findings "$_tmp"
  rm -f "$_tmp"
else
  _info "  no findings file, nothing to hand over"
fi
_info "  Findings: $(python3 -I -c 'import json,sys; print(json.loads(sys.argv[1])["total_findings"])' "$SUMMARY" 2>/dev/null || echo ?)  Ledger: $LEDGER_FILE"

# Exit non-zero only when every real phase failed (an absent phase is not a failure of the others).
fails=0; ran=0
for p in "$P1" "$P2" "$P3"; do case "$p" in absent|skipped*) continue ;; esac; ran=$((ran+1)); [ "$p" != ok ] && fails=$((fails+1)); done
[ "$ran" -gt 0 ] && [ "$fails" -eq "$ran" ] && exit 1
exit 0
