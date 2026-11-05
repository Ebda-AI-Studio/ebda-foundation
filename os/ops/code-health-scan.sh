#!/usr/bin/env bash
# ============================================================
# Whisky AI OS — code-health-scan.sh   (standalone code-health audit)
#
# Finds DEAD CODE, DUPLICATION, UNUSED modules/exports/deps, and
# OVERCOMPLEXITY across ALL layers of every Force repo.
#
# DETECTION (engine: ops/lib/code-health.py): tools-first (knip, jscpd)
# + native stdlib fallbacks + an optional `claude -p --model sonnet`
# judgment pass (--llm, ON by default here — this is the heavy weekly run).
#
# The same engine is called tools-only (no --llm) by dream-scan.sh --deep
# for the cheap nightly signal; THIS script is where the LLM pass fires.
#
# Output:
#   ~/.whisky-os-state/code-health-findings.json   (normalized + raw)
#   ~/.whisky-os-state/code-health-status.json      (subsystem health)
#   events.ndjson / zero-inbox.ndjson               (bus; inbox only on high+)
#   stdout                                          (human digest)
#
# Usage:
#   ops/code-health-scan.sh                 # full tools+LLM audit, all repos
#   ops/code-health-scan.sh --no-llm        # tools + native only (free)
#   ops/code-health-scan.sh --repo=mypovonai
#   ops/code-health-scan.sh --notify        # also Telegram a one-line digest
#   DRY_RUN=1 ops/code-health-scan.sh       # scan but don't write state
#
# Deps: bash 3.2+, python3 (stdlib). knip/jscpd/claude optional (fail-open).
# ============================================================
# shellcheck source=lib/os-config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/os-config.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-config.sh" 2>/dev/null || true
command -v os_config_load >/dev/null 2>&1 && os_config_load
set -uo pipefail
cd "$(dirname "$0")" || exit 1

. ./lib/os-state.sh 2>/dev/null || true

# TCC canary (2026-07-12): abort when the launchd context cannot see ~/Desktop
OS_JOB_NAME=code-health-scan
if command -v require_projects_access >/dev/null 2>&1; then require_projects_access || exit 0; fi


DRY_RUN="${DRY_RUN:-0}"
NOTIFY=0
LLM=1
ONE_REPO=""
CAP="${CODE_HEALTH_CAP:-25}"
for a in "$@"; do
  case "$a" in
    --notify)  NOTIFY=1 ;;
    --no-llm)  LLM=0 ;;
    --llm)     LLM=1 ;;
    --repo=*)  ONE_REPO="${a#--repo=}" ;;
  esac
done

STATE_DIR="$HOME/.whisky-os-state"; mkdir -p "$STATE_DIR"
FINDINGS_FILE="$STATE_DIR/code-health-findings.json"
PROJECTS="$OS_PROJECTS_DIR"
ENGINE="./lib/code-health.py"
NORMALIZE_LIB="./lib"

# repo list — keep in sync with dream-scan.sh get_repos()
get_repos() {
  printf '%s\n' \
    "ebda-store" \
    "ebda-whatsapp" \
    "ebda-studio" \
    "mypovonai" \
    "digital-card" \
    "gcc-horse-market"
}
repos_iter() { if [ -n "$ONE_REPO" ]; then printf '%s\n' "$ONE_REPO"; else get_repos; fi; }

_info() { printf '%s\n' "$*"; }
_now_iso() { python3 -c "import datetime;print(datetime.datetime.now().isoformat(timespec='seconds'))"; }

_info ""
_info "Whisky AI OS — code-health-scan"
_info "Started: $(_now_iso)"
_info "Mode: $([ "$LLM" = "1" ] && echo "tools + native + LLM" || echo "tools + native (no LLM)")"
[ "$DRY_RUN" = "1" ] && _info "(DRY_RUN=1 — no state write)"
_info ""

WORK_DIR=$(mktemp -d /tmp/code-health-XXXXXX)
trap 'rm -rf "$WORK_DIR"' EXIT

llm_flag=""; [ "$LLM" = "1" ] && llm_flag="--llm"

while IFS= read -r repo; do
  dir=$(resolve_repo_dir "$repo" 2>/dev/null || echo "$PROJECTS/$repo")
  if [ ! -d "$dir" ]; then echo "[]" > "$WORK_DIR/${repo}.json"; continue; fi
  _behind=$(repo_commits_behind "$dir" 2>/dev/null || echo 0)
  if [ "${_behind:-0}" -gt 0 ] 2>/dev/null; then
    _info "  ! $repo: checkout is $_behind commit(s) behind origin — findings describe a STALE tree"
  fi
  _info "  scanning $repo ..."
  # shellcheck disable=SC2086
  python3 "$ENGINE" --repo "$repo" --dir "$dir" --cap "$CAP" $llm_flag \
    > "$WORK_DIR/${repo}.json" 2>/dev/null || echo "[]" > "$WORK_DIR/${repo}.json"
done < <(repos_iter)

# ---- merge → normalize → write state → human digest → bus ----
NOTIFY_FILE="$WORK_DIR/notify.txt"
LIB="$NORMALIZE_LIB" python3 - "$WORK_DIR" "$FINDINGS_FILE" "$NOTIFY_FILE" "$DRY_RUN" << 'PYEOF'
import json, os, sys, glob, datetime, importlib.util

work_dir, findings_file, notify_file, dry = sys.argv[1], sys.argv[2], sys.argv[3], (sys.argv[4] == "1")

raw = []
for path in sorted(glob.glob(os.path.join(work_dir, "*.json"))):
    if os.path.basename(path) == "notify.txt":
        continue
    try:
        chunk = json.load(open(path))
        if isinstance(chunk, list):
            raw.extend(chunk)
    except Exception:
        pass

# normalize (dedup + group by root cause + drop unknown severity) via the shared lib
grouped, counts = [], {"raw": len(raw), "grouped": 0}
try:
    spec = importlib.util.spec_from_file_location("fn", os.path.join(os.environ["LIB"], "findings-normalize.py"))
    mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
    # Two sources, unioned: the version-controlled BASELINE that ships with the OS
    # (deliberate, reviewed, each entry carrying its evidence) and the mutable state
    # file acceptance-feedback.sh writes from wontfix issues. Either may be absent.
    supp = mod.load_suppressions([
        os.path.join(os.environ["LIB"], "findings-suppressions.base.json"),
        os.path.join(os.path.expanduser("~"), ".whisky-os-state", "findings-suppressions.json"),
    ])
    res = mod.normalize(raw, supp)
    grouped, counts = res["grouped"], res["counts"]
except Exception:
    counts = {"raw": len(raw), "grouped": len(raw), "by_severity": {}}

now = datetime.datetime.now().isoformat(timespec="seconds")
output = {
    "generated_at": now, "script": "code-health-scan.sh",
    "counts": counts, "grouped": grouped, "findings": raw,
}
if not dry:
    with open(findings_file, "w") as f:
        json.dump(output, f, indent=2)
    print("[code-health] wrote %s (%d grouped / %d raw)" % (findings_file, len(grouped), len(raw)))
else:
    print("[code-health] DRY_RUN: would write %d grouped / %d raw" % (len(grouped), len(raw)))

# human digest
print(); print("=" * 62); print("  CODE-HEALTH FINDINGS"); print("  " + now); print("=" * 62); print()
by_repo = {}
for g in grouped:
    by_repo.setdefault(g.get("repo", "?"), []).append(g)
if grouped:
    for repo, gs in sorted(by_repo.items()):
        print("  %s (%d):" % (repo, len(gs)))
        for g in gs[:8]:
            sev = (g.get("severity", "?")).upper()[:8]
            cls = (g.get("class", "?"))[:14]
            ttl = (g.get("title", ""))[:50]
            mult = " (x%d)" % g.get("count", 1) if g.get("count", 1) > 1 else ""
            print("    [%s] [%s] %s%s" % (sev, cls, ttl, mult))
        if len(gs) > 8:
            print("    ... +%d more" % (len(gs) - 8))
        print()
else:
    print("  No code-health findings. All repos clean."); print()

bysev = counts.get("by_severity", {})
high = bysev.get("critical", 0) + bysev.get("high", 0)
nl = []
if grouped:
    nl.append("code-health: %d issue(s) across %d repo(s)" % (len(grouped), len(by_repo)))
    nl.append("by-severity: %s" % json.dumps(bysev))
    nl.append("classes: dead-code/duplication/unused/overcomplexity (all propose-only)")
else:
    nl.append("code-health: all repos clean — no findings.")
with open(notify_file, "w") as f:
    f.write("\n".join(nl))
PYEOF

# ---- emit status/bus/notify (recompute counts from the written file) ----
if [ "$DRY_RUN" != "1" ] && [ -f "$FINDINGS_FILE" ]; then
  read -r GROUPED HIGH REPOS <<EOF
$(python3 -c "
import json
d=json.load(open('$FINDINGS_FILE'))
bs=(d.get('counts') or {}).get('by_severity') or {}
g=len(d.get('grouped') or [])
high=int(bs.get('critical',0))+int(bs.get('high',0))
repos=len({x.get('repo') for x in (d.get('grouped') or [])})
print(g, high, repos)
" 2>/dev/null || echo "0 0 0")
EOF
  GROUPED="${GROUPED:-0}"; HIGH="${HIGH:-0}"; REPOS="${REPOS:-0}"

  # ---- notify on NEW high+ findings, not on their existence ----
  # `grouped > 0` is true for any real codebase, so the old gate fired every
  # run. Six runs on 2026-08-25 sent six digests reading 89/85/94/96/86/96
  # grouped and 18/15/14/13/16/19 high — with no commits between them. The
  # counts move because the scan ends in a `claude -p --model sonnet` pass, so
  # each run resamples the same distribution. Status and bus events below still
  # carry the full picture every run; only the interrupt is gated.
  SEEN_FILE="$STATE_DIR/code-health-seen.json"
  read -r NEW_HIGH NEW_TOTAL RESOLVED SHOULD_NOTIFY <<EOF
$(LIB="$NORMALIZE_LIB" python3 -c "
import importlib.util, json, os, sys, datetime
try:
    spec = importlib.util.spec_from_file_location('fd', os.path.join(os.environ['LIB'], 'findings-delta.py'))
    fd = importlib.util.module_from_spec(spec); spec.loader.exec_module(fd)
    d = json.load(open('$FINDINGS_FILE'))
    g = d.get('grouped') or []
    r = fd.delta(g, fd.load_seen('$SEEN_FILE'))
    fd.save_seen('$SEEN_FILE', g, datetime.datetime.now().isoformat(timespec='seconds'))
    print(r['new_high'], r['new_total'], r['resolved'], 1 if r['notify'] else 0)
except Exception:
    # Fail LOUD-but-safe: on any delta error notify, so a broken differ
    # silences nothing. Silence must never be the failure mode of an alerter.
    print(0, 0, 0, 1)
" 2>/dev/null || echo "0 0 0 1")
EOF
  NEW_HIGH="${NEW_HIGH:-0}"; NEW_TOTAL="${NEW_TOTAL:-0}"
  RESOLVED="${RESOLVED:-0}"; SHOULD_NOTIFY="${SHOULD_NOTIFY:-1}"

  if command -v write_status >/dev/null 2>&1; then
    if [ "$GROUPED" -gt 0 ]; then
      ok=$([ "$HIGH" -gt 0 ] && echo "warn" || echo "true")
      write_status "code-health" "$ok" \
        "$GROUPED code-health issue(s) across $REPOS repo(s), $HIGH high+" \
        "{\"grouped\":$GROUPED,\"high\":$HIGH,\"repos\":$REPOS,\"new_high\":$NEW_HIGH,\"new_total\":$NEW_TOTAL,\"resolved\":$RESOLVED}"
    else
      write_status "code-health" "true" "all repos clean — no code-health findings" '{"grouped":0}'
    fi
  fi
  if command -v emit_event >/dev/null 2>&1 && [ "$GROUPED" -gt 0 ]; then
    sev=$([ "$HIGH" -gt 0 ] && echo "medium" || echo "low")
    emit_event "code-health" "$sev" \
      "code-health: $GROUPED issue(s), $HIGH high+ across $REPOS repo(s)" \
      "{\"grouped\":$GROUPED,\"high\":$HIGH}"
  fi
  # only escalate to Zero's mouth for a high+ finding we have NOT seen before
  if command -v emit_inbox >/dev/null 2>&1 && [ "$NEW_HIGH" -gt 0 ]; then
    emit_inbox "Code-health found $NEW_HIGH NEW high-severity issue(s) — dead code / overcomplexity to review." \
      "{\"new_high\":$NEW_HIGH,\"high\":$HIGH,\"grouped\":$GROUPED}"
  fi

  if [ "$NOTIFY" = "1" ] && [ "$SHOULD_NOTIFY" = "1" ] && [ -x ./notify.sh ]; then
    _resolved_note=""
    [ "$RESOLVED" -gt 0 ] && _resolved_note=", $RESOLVED resolved"
    ./notify.sh "🧹 code-health: $NEW_HIGH NEW high+ issue(s)$_resolved_note ($GROUPED total across $REPOS repo(s)). See code-health-findings.json / dashboard." 2>/dev/null || true
  elif [ "$NOTIFY" = "1" ]; then
    _info "notify: suppressed — no NEW high+ findings ($GROUPED total, $HIGH high+, $NEW_TOTAL new, $RESOLVED resolved)"
  fi
fi

exit 0
