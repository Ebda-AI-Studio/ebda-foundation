#!/usr/bin/env bash
# ============================================================
# Whisky AI OS -- postmortem.sh   (auto-postmortem, feature #4)
#
# On a P0 / CI-regression event: capture context (bus timeline,
# recent deploys, recent git log) and draft a postmortem document
# plus a candidate detector JSON for the compounding loop (#1).
#
# Usage:
#   ops/postmortem.sh --slug <kebab> --repo <repo> --summary "<what happened>" [--severity P0]
#   DRY_RUN=1 ops/postmortem.sh ...      # gather + print, don't write files
#
# Outputs (unless DRY_RUN=1):
#   audit/postmortems/<YYYY-MM-DD>-<slug>.md
#   ops/detectors/_candidates/<slug>.json
#   events.ndjson + zero-inbox.ndjson (bus)
#
# Deps: bash 3.2+, python3 (stdlib). claude + gh optional (fail-open).
# ============================================================
# shellcheck source=lib/os-config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/os-config.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-config.sh" 2>/dev/null || true
command -v os_config_load >/dev/null 2>&1 && os_config_load
set -uo pipefail
# CLAUDE_BIN lets a test point this at a stub. Without it the model call is
# untestable offline, which is why none of the OS's 17 model-calling scripts
# had a single behavioural test. Defaults to the real CLI.
CLAUDE_BIN="${CLAUDE_BIN:-claude}"
cd "$(dirname "$0")" || exit 1

. ./lib/os-state.sh 2>/dev/null || true

# TCC canary (2026-07-12): abort when the launchd context cannot see ~/Desktop
OS_JOB_NAME=postmortem
if command -v require_projects_access >/dev/null 2>&1; then require_projects_access || exit 0; fi


# ---- parse args ----
SLUG=""
REPO=""
SUMMARY=""
SEVERITY="P0"
DRY_RUN="${DRY_RUN:-0}"

while [ $# -gt 0 ]; do
  case "$1" in
    --slug)      SLUG="$2";     shift 2 ;;
    --repo)      REPO="$2";     shift 2 ;;
    --summary)   SUMMARY="$2";  shift 2 ;;
    --severity)  SEVERITY="$2"; shift 2 ;;
    --slug=*)    SLUG="${1#--slug=}";      shift ;;
    --repo=*)    REPO="${1#--repo=}";      shift ;;
    --summary=*) SUMMARY="${1#--summary=}"; shift ;;
    --severity=*)SEVERITY="${1#--severity=}"; shift ;;
    *) shift ;;
  esac
done

if [ -z "$SLUG" ] || [ -z "$REPO" ] || [ -z "$SUMMARY" ]; then
  echo "Usage: ops/postmortem.sh --slug <kebab> --repo <repo> --summary \"<what happened>\" [--severity P0]" >&2
  exit 0
fi

_now_iso() { python3 -c "import datetime;print(datetime.datetime.now().isoformat(timespec='seconds'))"; }
_today()   { python3 -c "import datetime;print(datetime.date.today().isoformat())"; }

STATE_DIR="$HOME/.whisky-os-state"
mkdir -p "$STATE_DIR"

PROJECTS="$OS_PROJECTS_DIR"
REPO_DIR="$PROJECTS/$REPO"

TODAY="$(_today)"
NOW="$(_now_iso)"

echo ""
echo "Whisky AI OS -- postmortem.sh"
echo "Started: $NOW"
echo "Incident: [$SEVERITY] $REPO - $SUMMARY"
echo "Slug: $SLUG"
[ "$DRY_RUN" = "1" ] && echo "(DRY_RUN=1 -- gather + print only)"
echo ""

# ---- work dir for Python helper scripts (bash 3.2: can't <<'HEREDOC' inside $()) ----
WORK_DIR=$(mktemp -d /tmp/postmortem-XXXXXX)
trap 'rm -rf "$WORK_DIR"' EXIT

# ---- write Python helper scripts to work dir ----

cat > "$WORK_DIR/gather_bus.py" << 'PYEOF'
import sys, json, os, datetime
state_dir = sys.argv[1]
hours = int(sys.argv[2])
cutoff = datetime.datetime.utcnow() - datetime.timedelta(hours=hours)

def parse_ts(s):
    try:
        s = s.rstrip("Z")
        return datetime.datetime.fromisoformat(s)
    except Exception:
        return None

lines = []
today_str = datetime.date.today().isoformat()
candidates = [
    os.path.join(state_dir, "events-%s.ndjson" % today_str),
    os.path.join(state_dir, "events.ndjson"),
]
for path in candidates:
    if not os.path.exists(path):
        continue
    try:
        with open(path) as f:
            for raw in f:
                raw = raw.strip()
                if not raw:
                    continue
                try:
                    obj = json.loads(raw)
                except Exception:
                    continue
                ts = parse_ts(obj.get("ts", ""))
                if ts and ts >= cutoff:
                    lines.append("  [%s] [%s] %s - %s" % (
                        obj.get("ts", "?")[:19],
                        obj.get("severity", "?").upper()[:8],
                        obj.get("name", "?"),
                        obj.get("summary", "?"),
                    ))
    except Exception:
        pass

if lines:
    print("\n".join(sorted(set(lines))))
else:
    print("  (no bus events in last %dh)" % hours)
PYEOF

cat > "$WORK_DIR/parse_runs.py" << 'PYEOF'
import sys, json
try:
    runs = json.load(sys.stdin)
except Exception:
    runs = []
for r in runs:
    sha = (r.get("headSha") or "")[:8]
    title = (r.get("displayTitle") or "")[:60]
    status = r.get("conclusion") or r.get("status") or "?"
    ts = (r.get("createdAt") or "")[:16]
    print("  [%s] %s %s - %s" % (status.upper()[:10], sha, ts, title))
PYEOF

cat > "$WORK_DIR/parse_prs.py" << 'PYEOF'
import sys, json
try:
    prs = json.load(sys.stdin)
except Exception:
    prs = []
for p in prs:
    ts = (p.get("mergedAt") or "")[:16]
    print("  PR#%s [%s] %s" % (p.get("number", "?"), ts, (p.get("title") or "")[:70]))
PYEOF

cat > "$WORK_DIR/extract_pm.py" << 'PYEOF'
import sys
lines = sys.stdin.read().splitlines()
pm = []
for l in lines:
    if l.startswith("DETECTOR_JSON:"):
        break
    pm.append(l)
print("\n".join(pm))
PYEOF

cat > "$WORK_DIR/extract_detector.py" << 'PYEOF'
import sys, json, re
text = sys.stdin.read()
for line in text.splitlines():
    if line.startswith("DETECTOR_JSON:"):
        raw = line[len("DETECTOR_JSON:"):].strip()
        try:
            obj = json.loads(raw)
            print(json.dumps(obj, indent=2, ensure_ascii=True))
            sys.exit(0)
        except Exception:
            pass
m = re.search(r'\{[^{}]{30,}\}', text, re.DOTALL)
if m:
    try:
        obj = json.loads(m.group())
        print(json.dumps(obj, indent=2, ensure_ascii=True))
    except Exception:
        pass
PYEOF

cat > "$WORK_DIR/build_detector.py" << 'PYEOF'
import json, os, sys
obj = {
    "name": os.environ["SLUG"],
    "class": "unknown",
    "severity": "high",
    "grep_pattern": "",
    "description": "Candidate detector for: " + os.environ["SUMMARY"],
    "repos": [os.environ["REPO"]],
    "rationale": "Auto-generated skeleton - fill in the specific pattern to detect.",
}
print(json.dumps(obj, indent=2, ensure_ascii=True))
PYEOF

cat > "$WORK_DIR/build_bus_detail.py" << 'PYEOF'
import json, os
print(json.dumps({
    "slug": os.environ["SLUG"],
    "repo": os.environ["REPO"],
    "severity": os.environ["SEV"],
    "file": os.environ["FILE"],
}, ensure_ascii=True))
PYEOF

cat > "$WORK_DIR/write_pm.py" << 'PYEOF'
import sys, os, json
outfile = os.environ["PM_OUTFILE"]
slug    = os.environ["PM_SLUG"]
sev     = os.environ["PM_SEVERITY"]
repo    = os.environ["PM_REPO"]
today   = os.environ["PM_TODAY"]
now     = os.environ["PM_NOW"]
pm_body = os.environ["PM_BODY"]
bus_ctx    = os.environ["PM_BUS"]
deploy_ctx = os.environ["PM_DEPLOY"]
git_ctx    = os.environ["PM_GIT"]

content = (
    "# Postmortem: " + slug + "\n\n"
    "**Date:** " + today + "\n"
    "**Severity:** " + sev + "\n"
    "**Repo:** " + repo + "\n"
    "**Generated:** " + now + "\n"
    "**Status:** Draft -- review and complete\n\n"
    "---\n\n"
    + pm_body + "\n\n"
    "---\n\n"
    "## Raw Context\n\n"
    "### Bus Timeline (last 6h)\n\n"
    "```\n" + bus_ctx + "\n```\n\n"
    "### Recent Deploys / PRs\n\n"
    "```\n" + deploy_ctx + "\n```\n\n"
    "### Recent Git Log\n\n"
    "```\n" + git_ctx + "\n```\n"
)

with open(outfile, "w") as f:
    f.write(content)
print("[postmortem] wrote: " + outfile)
PYEOF

# ---- (a) gather bus timeline (~6h) ----
BUS_CONTEXT="$(python3 "$WORK_DIR/gather_bus.py" "$STATE_DIR" 6 2>/dev/null || echo '  (bus read failed)')"

echo "--- Bus timeline (last 6h) ---"
echo "$BUS_CONTEXT"
echo ""

# ---- (b) recent deploys via gh (skip gracefully if absent) ----
DEPLOYS_CONTEXT=""
if command -v gh >/dev/null 2>&1; then
  RUN_LINES="$(gh run list --repo "$OS_ORG/$REPO" --branch main --limit 8 \
    --json displayTitle,conclusion,status,headSha,createdAt \
    2>/dev/null | python3 "$WORK_DIR/parse_runs.py" 2>/dev/null || true)"
  PR_LINES="$(gh pr list --repo "$OS_ORG/$REPO" --state merged --limit 5 \
    --json number,title,mergedAt 2>/dev/null | python3 "$WORK_DIR/parse_prs.py" 2>/dev/null || true)"

  if [ -n "$RUN_LINES" ] || [ -n "$PR_LINES" ]; then
    DEPLOYS_CONTEXT=""
    [ -n "$RUN_LINES" ] && DEPLOYS_CONTEXT="Recent CI runs:
$RUN_LINES"
    [ -n "$PR_LINES" ] && DEPLOYS_CONTEXT="$DEPLOYS_CONTEXT
Recently merged PRs:
$PR_LINES"
  else
    DEPLOYS_CONTEXT="  (gh present but no deploy data returned)"
  fi
else
  DEPLOYS_CONTEXT="  (gh not available -- deploy context skipped)"
fi

echo "--- Recent deploys/PRs ---"
echo "$DEPLOYS_CONTEXT"
echo ""

# ---- (c) recent git log ----
GIT_LOG_CONTEXT=""
if [ -d "$REPO_DIR/.git" ]; then
  GIT_LOG_CONTEXT="$(git -C "$REPO_DIR" log --oneline --no-decorate -15 2>/dev/null | \
    sed 's/^/  /' || true)"
  [ -z "$GIT_LOG_CONTEXT" ] && GIT_LOG_CONTEXT="  (git log returned empty)"
else
  GIT_LOG_CONTEXT="  (repo dir not found: $REPO_DIR)"
fi

echo "--- Recent git log ($REPO, last 15 commits) ---"
echo "$GIT_LOG_CONTEXT"
echo ""

if [ "$DRY_RUN" = "1" ]; then
  echo "[DRY_RUN] Would write:"
  echo "  audit/postmortems/${TODAY}-${SLUG}.md"
  echo "  ops/detectors/_candidates/${SLUG}.json"
  echo "  bus events (postmortem / zero-inbox)"
  exit 0
fi

# ---- determine output paths ----
# ops/ is our cwd (we cd'd into it above). The worktree root is one level up.
SCRIPT_DIR="$(pwd)"
TREE_ROOT="$(dirname "$SCRIPT_DIR")"

POSTMORTEM_DIR="$TREE_ROOT/audit/postmortems"
CANDIDATES_DIR="$SCRIPT_DIR/detectors/_candidates"
mkdir -p "$POSTMORTEM_DIR" "$CANDIDATES_DIR"

POSTMORTEM_FILE="$POSTMORTEM_DIR/${TODAY}-${SLUG}.md"
CANDIDATE_FILE="$CANDIDATES_DIR/${SLUG}.json"

# ---- build the prompt context (ASCII-safe for claude pipe) ----
PROMPT_CTX="Incident: [$SEVERITY] $REPO - $SUMMARY
Date: $TODAY

## Bus timeline (last 6h)
$BUS_CONTEXT

## Recent deploys / merged PRs
$DEPLOYS_CONTEXT

## Recent git log ($REPO, last 15 commits)
$GIT_LOG_CONTEXT"

# ---- try claude -p for AI-drafted postmortem + candidate detector ----
AI_OUTPUT=""
if command -v claude >/dev/null 2>&1; then
  # Build prompt via python3 to avoid bash parsing issues with special chars
  CLAUDE_PROMPT="$(REPO="$REPO" PROMPT_CTX="$PROMPT_CTX" python3 -c "
import os
repo = os.environ['REPO']
ctx  = os.environ['PROMPT_CTX']
lines = [
    'You are the Whisky AI OS postmortem agent. Given this incident context, write:',
    '',
    '1. A postmortem in Markdown with these sections:',
    '   ## Summary',
    '   ## Timeline',
    '   ## Root Cause',
    '   ## Blast Radius',
    '   ## Prevention / Action Items',
    '',
    '2. A candidate detector JSON object on its own line after the postmortem,',
    '   prefixed with DETECTOR_JSON: with these fields:',
    '   {\"name\": \"<kebab-slug>\", \"class\": \"<class>\", \"severity\": \"<critical|high|medium|low>\",',
    '    \"grep_pattern\": \"<regex or empty>\", \"description\": \"<what to detect>\",',
    '    \"repos\": [\"' + repo + '\"], \"rationale\": \"<why this would have caught it earlier>\"}',
    '',
    'CONTEXT:',
    ctx,
    '',
    'Be concise. The postmortem should be actionable. The detector should be specific.',
]
print('\n'.join(lines))
" 2>/dev/null || true)"

  [ -n "$CLAUDE_PROMPT" ] && \
    AI_OUTPUT="$(printf '%s' "$CLAUDE_PROMPT" | "$CLAUDE_BIN" -p --model sonnet 2>/dev/null || true)"
fi

# ---- parse AI output (validate: must contain at least one ## header) ----
PM_CONTENT=""
DETECTOR_JSON=""
if [ -n "$AI_OUTPUT" ]; then
  _PM_RAW="$(printf '%s' "$AI_OUTPUT" | python3 "$WORK_DIR/extract_pm.py" 2>/dev/null || true)"
  # Only accept AI content that looks like a real postmortem (has ## headers)
  if grep -q "^##" < <(printf '%s' "$_PM_RAW"); then
    PM_CONTENT="$_PM_RAW"
    DETECTOR_JSON="$(printf '%s' "$AI_OUTPUT" | python3 "$WORK_DIR/extract_detector.py" 2>/dev/null || true)"
  fi
fi

# ---- fallback skeleton if AI absent or parse failed ----
if [ -z "$PM_CONTENT" ]; then
  PM_CONTENT="## Summary

$SUMMARY

## Timeline

(Auto-gathered context below -- fill in the human timeline)

## Root Cause

(To be determined)

## Blast Radius

(Document what was affected)

## Prevention / Action Items

- [ ] Identify root cause
- [ ] Add a detector to ops/detectors/ to catch this class of issue earlier
- [ ] Update runbooks if needed"
fi

# ---- write postmortem .md ----
PM_OUTFILE="$POSTMORTEM_FILE" PM_SLUG="$SLUG" PM_SEVERITY="$SEVERITY" \
  PM_REPO="$REPO" PM_TODAY="$TODAY" PM_NOW="$NOW" PM_BODY="$PM_CONTENT" \
  PM_BUS="$BUS_CONTEXT" PM_DEPLOY="$DEPLOYS_CONTEXT" PM_GIT="$GIT_LOG_CONTEXT" \
  python3 "$WORK_DIR/write_pm.py" 2>/dev/null || \
  echo "[postmortem] WARN: failed to write postmortem file" >&2

# ---- write candidate detector JSON ----
if [ -z "$DETECTOR_JSON" ]; then
  DETECTOR_JSON="$(SLUG="$SLUG" REPO="$REPO" SUMMARY="$SUMMARY" \
    python3 "$WORK_DIR/build_detector.py" 2>/dev/null || echo '{}')"
fi

printf '%s\n' "$DETECTOR_JSON" > "$CANDIDATE_FILE"
echo "[postmortem] wrote candidate detector: $CANDIDATE_FILE"

# ---- emit bus events ----
BUS_DETAIL="$(SLUG="$SLUG" REPO="$REPO" SEV="$SEVERITY" FILE="$POSTMORTEM_FILE" \
  python3 "$WORK_DIR/build_bus_detail.py" 2>/dev/null || echo '{}')"

if command -v emit_event >/dev/null 2>&1; then
  emit_event "postmortem" "high" \
    "Postmortem drafted: [$SEVERITY] $REPO - $SUMMARY" \
    "$BUS_DETAIL"
fi

if command -v emit_inbox >/dev/null 2>&1; then
  emit_inbox \
    "Postmortem ready: ${TODAY}-${SLUG}.md - review + fill in root cause / action items" \
    "$BUS_DETAIL"
fi

echo ""
echo "Done."
echo "  Postmortem : $POSTMORTEM_FILE"
echo "  Detector   : $CANDIDATE_FILE"
echo ""

write_status "postmortem" "warn" "$SLUG drafted at $POSTMORTEM_FILE" "{}"

exit 0
