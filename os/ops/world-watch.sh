#!/usr/bin/env bash
# ============================================================
# Whisky AI OS — world-watch.sh   (external-world watcher)
#
# PURPOSE: weekly scan for time-bombs BEYOND npm CVEs (which
# dream-research.sh already covers). Three lenses:
#   1. FRAMEWORK EOL  — endoflife.date public JSON API
#      Checks nextjs, nodejs, react, prisma, express installed
#      majors against EOL/sunset dates. class "framework-eol".
#   2. META/WHATSAPP API version drift — grep WBS source for
#      hardcoded graph API versions lagging the known-current.
#      class "api-version-drift".
#   3. NPM DEPRECATION — samples direct deps per repo, queries
#      `npm view <pkg> deprecated`. class "dep-deprecated".
#
# All lenses are fail-open: network absent → skip, not crash.
#
# Output:
#   ~/.whisky-os-state/world-extras.json   (findings + counts)
#   events.ndjson / zero-inbox.ndjson      (bus; inbox only on high+)
#   stdout                                 (human digest)
#
# Usage:
#   ops/world-watch.sh                    # run all lenses
#   ops/world-watch.sh --notify           # + Telegram on findings
#   DRY_RUN=1 ops/world-watch.sh          # no writes, no network
#
# Env overrides (for testing without network):
#   WW_EOL_DATA_DIR=<dir>   — dir of <product>.json EOL fixture files
#   WW_SKIP_EOL=1           — skip EOL lens entirely
#   WW_SKIP_API=1           — skip API-version lens
#   WW_SKIP_NPM_DEP=1       — skip npm-deprecation lens
#   WW_NPM_DEP_CAP=15       — max deps to check per repo (default 15)
#   WW_GRAPH_API_CURRENT=vNN.0 — override known-current Graph API ver
#
# Deps: bash 3.2+, python3 (stdlib). curl, npm optional (fail-open).
# ============================================================
# shellcheck source=lib/os-config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/os-config.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-config.sh" 2>/dev/null || true
command -v os_config_load >/dev/null 2>&1 && os_config_load
set -uo pipefail
# S0 (2026-10-26): --help runs nothing; one run at a time (lib/single-instance.sh)
. "$(dirname "${BASH_SOURCE[0]}")/lib/args.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/args.sh" || exit 2
. "$(dirname "${BASH_SOURCE[0]}")/lib/single-instance.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/single-instance.sh" || exit 2
args_help "${BASH_SOURCE[0]}" "$@"
single_instance world-watch
cd "$(dirname "$0")" || exit 1

. ./lib/os-state.sh 2>/dev/null || true

# TCC canary (2026-07-12): abort when the launchd context cannot see ~/Desktop
OS_JOB_NAME=world-watch
if command -v require_projects_access >/dev/null 2>&1; then require_projects_access || exit 0; fi


# ---------- config ----------
SVC_ENV="${WHISKY_SERVICES_ENV:-$OS_SERVICES_ENV}"
[ -f "$SVC_ENV" ] && { set -a; . "$SVC_ENV"; set +a; } || true

DRY_RUN="${DRY_RUN:-0}"
NOTIFY=0
for _arg in "$@"; do
  case "$_arg" in --notify) NOTIFY=1 ;; esac
done

STATE_DIR="$HOME/.whisky-os-state"; mkdir -p "$STATE_DIR"
EXTRAS_FILE="$STATE_DIR/world-extras.json"
NORMALIZE_LIB="./lib"
PROJECTS="$OS_PROJECTS_DIR"

# Lens control (can be overridden by tests)
WW_SKIP_EOL="${WW_SKIP_EOL:-0}"
WW_SKIP_API="${WW_SKIP_API:-0}"
WW_SKIP_NPM_DEP="${WW_SKIP_NPM_DEP:-0}"
WW_NPM_DEP_CAP="${WW_NPM_DEP_CAP:-15}"

# Known-current Meta/WhatsApp Graph API version (bump when Meta releases a new version)
WW_GRAPH_API_CURRENT="${WW_GRAPH_API_CURRENT:-v22.0}"

# Optional fixture dir for offline EOL testing
WW_EOL_DATA_DIR="${WW_EOL_DATA_DIR:-}"

# ---------- helpers ----------
_log()  { printf '[world-watch] %s\n' "$*" >&2; }
_info() { printf '%s\n' "$*"; }
_now_iso() { python3 -c "import datetime; print(datetime.datetime.now().isoformat(timespec='seconds'))"; }

# repo list — keep in sync with dream-research.sh
get_repos() {
  printf '%s\n' \
    "ebda-store" \
    "ebda-whatsapp" \
    "ebda-studio" \
    "mypovonai" \
    "digital-card" \
    "gcc-horse-market"
}

# ---------- read installed version from package.json ----------
# Returns major.minor.patch of first matching dep (handles ^, ~, ranges).
# Outputs empty string if not found.
_installed_version() {
  local pkg="$1" pkgjson="$2"
  python3 - "$pkg" "$pkgjson" << 'PYEOF'
import json, re, sys
pkg, path = sys.argv[1], sys.argv[2]
try:
    data = json.load(open(path))
except Exception:
    print(""); sys.exit(0)
all_deps = {}
all_deps.update(data.get("dependencies") or {})
all_deps.update(data.get("devDependencies") or {})
raw = all_deps.get(pkg, "")
# strip semver range operators and take first token
ver = re.sub(r"[^0-9.].*", "", re.sub(r"^[^0-9]*", "", raw.split(" ")[0]))
print(ver if re.match(r"^\d", ver) else "")
PYEOF
}

# ---------- LENS 1: Framework EOL ----------
# Uses endoflife.date API or WW_EOL_DATA_DIR fixture files.
# Products to check: name → endoflife.date product slug + dep name(s) in package.json
# Format: "product:dep1,dep2"
EOL_PRODUCTS="nextjs:next nodejs:node react:react prisma:prisma,@prisma/client express:express"

_fetch_eol_json() {
  local product="$1"
  if [ -n "$WW_EOL_DATA_DIR" ] && [ -f "$WW_EOL_DATA_DIR/${product}.json" ]; then
    cat "$WW_EOL_DATA_DIR/${product}.json"
    return 0
  fi
  if [ "$DRY_RUN" = "1" ]; then
    _log "DRY_RUN: skip EOL fetch for $product"
    echo "[]"; return 0
  fi
  command -v curl >/dev/null 2>&1 || { echo "[]"; return 0; }
  curl -sS -m 15 \
    -H "Accept: application/json" \
    "https://endoflife.date/api/${product}.json" 2>/dev/null || echo "[]"
}

# Compare installed version against EOL data.
# Returns JSON array of findings.
_check_eol_for_repo() {
  local repo="$1" repo_dir="$2"
  local pkgjson="$repo_dir/package.json"
  [ -f "$pkgjson" ] || { echo "[]"; return; }

  local all_findings="[]"

  for entry in $EOL_PRODUCTS; do
    local product="${entry%%:*}"
    local deps_str="${entry#*:}"

    # Find installed version — try each dep name in order
    local installed_ver=""
    local installed_dep=""
    IFS=',' read -ra dep_names <<< "$deps_str"
    for dep in "${dep_names[@]}"; do
      installed_ver=$(_installed_version "$dep" "$pkgjson")
      if [ -n "$installed_ver" ]; then
        installed_dep="$dep"
        break
      fi
    done
    [ -n "$installed_ver" ] || continue

    # Fetch EOL data (fail-open)
    local eol_json
    eol_json=$(_fetch_eol_json "$product" 2>/dev/null) || eol_json="[]"
    [ "$eol_json" = "[]" ] || [ -z "$eol_json" ] && {
      # still try to parse — might be valid
      true
    }

    # Compare installed major against cycle data
    local finding
    finding=$(python3 - "$repo" "$product" "$installed_dep" "$installed_ver" "$eol_json" << 'PYEOF'
import json, sys, re
from datetime import date, datetime

repo, product, dep, installed, eol_raw = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]

def parse_date(s):
    if not s: return None
    for fmt in ("%Y-%m-%d", "%Y-%m", "%Y"):
        try: return datetime.strptime(s, fmt).date()
        except: pass
    return None

try:
    cycles = json.loads(eol_raw)
except Exception:
    print("[]"); sys.exit(0)
if not isinstance(cycles, list) or not cycles:
    print("[]"); sys.exit(0)

# Extract installed major
m = re.match(r"^(\d+)", installed)
if not m:
    print("[]"); sys.exit(0)
installed_major = int(m.group(1))

today = date.today()
findings = []

# Build list of cycles with EOL/support info
active_majors = []
for cycle in cycles:
    c = str(cycle.get("cycle", ""))
    cm = re.match(r"^(\d+)", c)
    if not cm: continue
    cmaj = int(cm.group(1))
    eol = parse_date(str(cycle.get("eol", "") or ""))
    support_end = parse_date(str(cycle.get("support", "") or ""))
    is_eol = False
    eol_date_str = ""
    if eol is True or (isinstance(cycle.get("eol"), bool) and cycle["eol"]):
        is_eol = True
    elif eol and eol <= today:
        is_eol = True
        eol_date_str = str(eol)
    if not is_eol:
        active_majors.append(cmaj)

# Determine if installed major is EOL
installed_cycle_eol = False
installed_eol_date = ""
for cycle in cycles:
    c = str(cycle.get("cycle", ""))
    cm = re.match(r"^(\d+)", c)
    if not cm: continue
    cmaj = int(cm.group(1))
    if cmaj != installed_major: continue
    eol = parse_date(str(cycle.get("eol", "") or ""))
    if eol is True or (isinstance(cycle.get("eol"), bool) and cycle["eol"]):
        installed_cycle_eol = True
    elif eol and eol <= today:
        installed_cycle_eol = True
        installed_eol_date = str(eol)
    break

if not installed_cycle_eol and not active_majors:
    print("[]"); sys.exit(0)

# Find latest active major
latest_active = max(active_majors) if active_majors else installed_major
cycles_behind = latest_active - installed_major

# Only report if: EOL OR ≥2 cycles behind
if not installed_cycle_eol and cycles_behind < 2:
    print("[]"); sys.exit(0)

if installed_cycle_eol:
    severity = "high"
    title = "%s v%d is EOL" % (dep, installed_major)
    detail = "%s installed major v%d has reached end-of-life%s. Latest active: v%d." % (
        dep, installed_major,
        (" (since %s)" % installed_eol_date if installed_eol_date else ""),
        latest_active
    )
    fix = "Upgrade %s to v%d+ (latest active cycle)." % (dep, latest_active)
else:
    severity = "medium"
    title = "%s v%d is %d cycle(s) behind current (v%d)" % (dep, installed_major, cycles_behind, latest_active)
    detail = "%s installed major v%d is %d major version(s) behind latest active v%d." % (
        dep, installed_major, cycles_behind, latest_active
    )
    fix = "Plan upgrade of %s from v%d to v%d." % (dep, installed_major, latest_active)

findings.append({
    "repo": repo,
    "class": "framework-eol",
    "severity": severity,
    "file": "package.json",
    "line": 0,
    "title": title,
    "detail": detail,
    "fix": fix,
    "autofixable": False,
})
print(json.dumps(findings))
PYEOF
    )
    all_findings=$(python3 -c "
import json,sys
a=json.loads(sys.argv[1])
b=json.loads(sys.argv[2])
print(json.dumps(a+b))
" "$all_findings" "$finding" 2>/dev/null || echo "$all_findings")
  done

  echo "$all_findings"
}

# ---------- LENS 2: Meta/WhatsApp Graph API version drift ----------
# Grep WBS source for hardcoded `v<NN>.0` graph API versions.
# Compare against WW_GRAPH_API_CURRENT.

_check_api_version_drift() {
  local wbs_dir="$PROJECTS/$OS_ORG/internal-projects/ebda-whatsapp"
  [ -d "$wbs_dir" ] || { echo "[]"; return; }

  python3 - "$wbs_dir" "$WW_GRAPH_API_CURRENT" << 'PYEOF'
import json, os, re, sys

wbs_dir = sys.argv[1]
current_raw = sys.argv[2]   # e.g. "v22.0"

# Parse current major
m = re.match(r"v?(\d+)", current_raw)
if not m:
    print("[]"); sys.exit(0)
current_major = int(m.group(1))

findings = []
seen = set()

# Walk source files (ts, js, env, json but not node_modules or lockfiles)
# `.husky` holds husky's own generated shim, which ships the line
# "They WILL FAIL in v10.0.0" — husky's version, not a Graph API version. It
# was reported as a HIGH "12 versions behind" finding. Vendored tool output is
# not the repo's source.
skip_dirs = {"node_modules", ".git", ".next", "dist", "build", ".husky", "vendor", "coverage"}

# A bare `vNN.0` is not evidence of a Graph API pin — it matches semvers,
# changelog prose and tool output. A real pin always names the thing it is a
# version OF, on the same line: a Meta host, a Graph path, or an API-version
# identifier. Every true positive in WBS satisfies this
# (`WHATSAPP_API_VERSION=v20.0`, `api_version = 'v18.0'`,
# `https://www.facebook.com/v18.0/dialog/oauth`); the husky shim does not.
GRAPH_CONTEXT = re.compile(
    r"graph\.facebook|facebook\.com|fbcdn|whatsapp|meta[_-]?api"
    r"|api[_-]?version|graph[_-]?api|GRAPH_API|API_VERSION",
    re.IGNORECASE,
)
for root, dirs, files in os.walk(wbs_dir):
    # prune in-place
    dirs[:] = [d for d in dirs if d not in skip_dirs]
    for fname in files:
        if not re.search(r"\.(ts|tsx|js|jsx|mjs|cjs|env.*|json|sh|yaml|yml)$", fname):
            continue
        if fname in ("package-lock.json", "yarn.lock", "pnpm-lock.yaml"):
            continue
        fpath = os.path.join(root, fname)
        rel_path = os.path.relpath(fpath, wbs_dir)
        try:
            text = open(fpath, encoding="utf-8", errors="replace").read()
        except Exception:
            continue
        # Find hardcoded graph API versions: v<digits>.0
        for lineno, line in enumerate(text.splitlines(), 1):
            # Require the line to say WHAT this is a version of. Without it the
            # scanner reports any `vNN.0` in any file — the husky shim's own
            # deprecation notice came through as a HIGH finding.
            if not GRAPH_CONTEXT.search(line):
                continue
            # `(?!\.?\d)` rejects a semver: `v10.0.0` is a package version,
            # not a Graph API version. A real pin is `v18.0` followed by a
            # quote, a slash, or end-of-line.
            for match in re.finditer(r"v(\d{2,3})\.0(?!\.?\d)", line):
                found_major = int(match.group(1))
                if found_major >= current_major:
                    continue  # up-to-date or newer
                lag = current_major - found_major
                key = (rel_path, lineno, found_major)
                if key in seen:
                    continue
                seen.add(key)
                sev = "high" if lag >= 4 else "medium"
                findings.append({
                    "repo": "ebda-whatsapp",
                    "class": "api-version-drift",
                    "severity": sev,
                    "file": rel_path,
                    "line": lineno,
                    "title": "Hardcoded Graph API v%d.0 is %d version(s) behind current v%d.0" % (
                        found_major, lag, current_major),
                    "detail": ("Found 'v%d.0' at %s:%d. Meta Graph API current is %s. "
                               "Old API versions are deprecated on a rolling schedule "
                               "and may be sunset without notice.") % (
                               found_major, rel_path, lineno, "v%d.0" % current_major),
                    "fix": ("Replace 'v%d.0' with '%s' (or use an env/config constant). "
                            "Test against the WBS sandbox before rolling to prod.") % (
                            found_major, "v%d.0" % current_major),
                    "autofixable": False,
                })

print(json.dumps(findings))
PYEOF
}

# ---------- LENS 3: npm deprecation ----------
# Samples direct deps from package.json, queries `npm view <pkg> deprecated`.
# Cap at WW_NPM_DEP_CAP per repo to stay fast.

_check_npm_deprecated_for_repo() {
  local repo="$1" repo_dir="$2"
  local pkgjson="$repo_dir/package.json"
  [ -f "$pkgjson" ] || { echo "[]"; return; }

  command -v npm >/dev/null 2>&1 || { echo "[]"; return; }
  [ "$DRY_RUN" = "1" ] && { echo "[]"; return; }

  # Extract direct dep names (prod + dev), capped
  local dep_names
  dep_names=$(python3 - "$pkgjson" "$WW_NPM_DEP_CAP" << 'PYEOF'
import json, sys
path, cap = sys.argv[1], int(sys.argv[2])
try:
    data = json.load(open(path))
except Exception:
    print(""); sys.exit(0)
deps = list((data.get("dependencies") or {}).keys())
devdeps = list((data.get("devDependencies") or {}).keys())
combined = deps + devdeps
print(" ".join(combined[:cap]))
PYEOF
  )
  [ -n "$dep_names" ] || { echo "[]"; return; }

  local findings="[]"
  for pkg in $dep_names; do
    # npm view with tight timeout; fail-open
    local deprecated_msg
    deprecated_msg=$(timeout 10 npm view "$pkg" deprecated 2>/dev/null || true)
    if [ -n "$deprecated_msg" ] && [ "$deprecated_msg" != "undefined" ]; then
      # truncate long messages
      local short_msg
      short_msg=$(python3 -c "s='''${deprecated_msg//\'/}'''; print(s[:120])" 2>/dev/null || echo "$deprecated_msg")
      local new_finding
      new_finding=$(python3 - "$repo" "$pkg" "$short_msg" << 'PYEOF'
import json, sys
repo, pkg, msg = sys.argv[1], sys.argv[2], sys.argv[3]
print(json.dumps([{
    "repo": repo,
    "class": "dep-deprecated",
    "severity": "medium",
    "file": "package.json",
    "line": 0,
    "title": "npm package '%s' is deprecated" % pkg,
    "detail": "npm deprecation notice: %s" % msg,
    "fix": "Replace '%s' with its recommended successor or remove if unused. Check the npm page for migration guidance." % pkg,
    "autofixable": False,
}]))
PYEOF
      )
      findings=$(python3 -c "
import json,sys
a=json.loads(sys.argv[1])
b=json.loads(sys.argv[2])
print(json.dumps(a+b))
" "$findings" "$new_finding" 2>/dev/null || echo "$findings")
    fi
  done

  echo "$findings"
}

# ============================================================
# MAIN
# ============================================================
_info ""
_info "Whisky AI OS — world-watch (external-world watcher)"
_info "Started: $(_now_iso)"
[ "$DRY_RUN" = "1" ] && _info "(DRY_RUN=1 — no writes, no network calls)"
_info ""

WORK_DIR=$(mktemp -d /tmp/world-watch-XXXXXX)
trap 'rm -rf "$WORK_DIR"; si_release world-watch' EXIT

# ---------- run all lenses, accumulate findings ----------
ALL_FINDINGS="[]"

_append_findings() {
  local new_json="$1"
  ALL_FINDINGS=$(python3 -c "
import json,sys
a=json.loads(sys.argv[1])
b=json.loads(sys.argv[2])
print(json.dumps(a+b))
" "$ALL_FINDINGS" "$new_json" 2>/dev/null || echo "$ALL_FINDINGS")
}

# --- Lens 1: Framework EOL ---
if [ "$WW_SKIP_EOL" != "1" ]; then
  _info "Lens 1: framework EOL check ..."
  while IFS= read -r repo; do
    dir="$PROJECTS/$repo"
    [ -d "$dir" ] || continue
    _log "  EOL check: $repo"
    result=$(_check_eol_for_repo "$repo" "$dir" 2>/dev/null) || result="[]"
    _append_findings "$result"
  done < <(get_repos)
else
  _log "WW_SKIP_EOL=1 — skipping EOL lens"
fi

# --- Lens 2: Meta/WhatsApp API version drift ---
if [ "$WW_SKIP_API" != "1" ]; then
  _info "Lens 2: Meta/WhatsApp Graph API version-drift check ..."
  result=$(_check_api_version_drift 2>/dev/null) || result="[]"
  _append_findings "$result"
else
  _log "WW_SKIP_API=1 — skipping API-version lens"
fi

# --- Lens 3: npm deprecation ---
if [ "$WW_SKIP_NPM_DEP" != "1" ]; then
  _info "Lens 3: npm deprecation check (cap=$WW_NPM_DEP_CAP per repo) ..."
  while IFS= read -r repo; do
    dir="$PROJECTS/$repo"
    [ -d "$dir" ] || continue
    _log "  npm-dep check: $repo"
    result=$(_check_npm_deprecated_for_repo "$repo" "$dir" 2>/dev/null) || result="[]"
    _append_findings "$result"
  done < <(get_repos)
else
  _log "WW_SKIP_NPM_DEP=1 — skipping npm-deprecation lens"
fi

# ---------- normalize + write state ----------
NOTIFY_FILE="$WORK_DIR/notify.txt"
LIB="$NORMALIZE_LIB" python3 - "$ALL_FINDINGS" "$EXTRAS_FILE" "$NOTIFY_FILE" "$DRY_RUN" << 'PYEOF'
import json, os, sys, datetime, importlib.util

raw_json, extras_file, notify_file, dry = sys.argv[1], sys.argv[2], sys.argv[3], (sys.argv[4] == "1")

try:
    raw = json.loads(raw_json)
except Exception:
    raw = []

# normalize via shared lib (dedup + group + severity filter)
grouped, counts = [], {"raw": len(raw), "grouped": 0}
try:
    lib_dir = os.environ.get("LIB", "./lib")
    spec = importlib.util.spec_from_file_location(
        "fn", os.path.join(lib_dir, "findings-normalize.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    supp = mod.load_suppressions(
        os.path.join(os.path.expanduser("~"), ".whisky-os-state",
                     "findings-suppressions.json"))
    res = mod.normalize(raw, supp)
    grouped, counts = res["grouped"], res["counts"]
except Exception as e:
    counts = {"raw": len(raw), "grouped": len(raw), "by_severity": {}}

now = datetime.datetime.now().isoformat(timespec="seconds")

# Group by class for the output
by_class = {}
for g in grouped:
    by_class.setdefault(g.get("class", "other"), []).append(g)

output = {
    "generated_at": now,
    "script": "world-watch.sh",
    "counts": counts,
    "grouped": grouped,
    "findings": raw,
}

if not dry:
    with open(extras_file, "w") as f:
        json.dump(output, f, indent=2)
    print("[world-watch] wrote %s (%d grouped / %d raw)" % (extras_file, len(grouped), len(raw)))
else:
    print("[world-watch] DRY_RUN: would write %d grouped / %d raw" % (len(grouped), len(raw)))

# human digest
print()
print("=" * 62)
print("  WORLD-WATCH FINDINGS")
print("  " + now)
print("=" * 62)
print()

if grouped:
    for cls, gs in sorted(by_class.items()):
        print("  [%s] (%d):" % (cls, len(gs)))
        for g in gs[:6]:
            sev = (g.get("severity", "?")).upper()[:8]
            repo = (g.get("repo", "?"))[:18]
            ttl = (g.get("title", ""))[:52]
            cnt = " (x%d)" % g.get("count", 1) if g.get("count", 1) > 1 else ""
            print("    [%s] %s — %s%s" % (sev, repo, ttl, cnt))
        if len(gs) > 6:
            print("    ... +%d more" % (len(gs) - 6))
        print()
else:
    print("  No external-world findings. All lenses clean.")
    print()

bysev = counts.get("by_severity", {})
high = int(bysev.get("critical", 0)) + int(bysev.get("high", 0))
nl = []
if grouped:
    nl.append("world-watch: %d issue(s) across %d class(es)" % (len(grouped), len(by_class)))
    nl.append("by-severity: %s" % json.dumps(bysev))
    nl.append("classes: framework-eol / api-version-drift / dep-deprecated")
    if high:
        nl.append("HIGH+ findings need attention — see world-extras.json")
else:
    nl.append("world-watch: all lenses clean — no external-world findings.")
with open(notify_file, "w") as f:
    f.write("\n".join(nl))
with open(notify_file + ".high", "w") as f:
    f.write("YES" if high > 0 else "NO")
PYEOF

HAS_HIGH=$(cat "$WORK_DIR/notify.txt.high" 2>/dev/null || echo "NO")

# ---------- bus + status ----------
if [ "$DRY_RUN" != "1" ] && [ -f "$EXTRAS_FILE" ]; then
  read -r GROUPED HIGH_COUNT CLASSES <<EOF
$(python3 -c "
import json
d=json.load(open('$EXTRAS_FILE'))
bs=(d.get('counts') or {}).get('by_severity') or {}
g=len(d.get('grouped') or [])
high=int(bs.get('critical',0))+int(bs.get('high',0))
classes=len({x.get('class') for x in (d.get('grouped') or [])})
print(g, high, classes)
" 2>/dev/null || echo "0 0 0")
EOF
  GROUPED="${GROUPED:-0}"; HIGH_COUNT="${HIGH_COUNT:-0}"; CLASSES="${CLASSES:-0}"

  if command -v write_status >/dev/null 2>&1; then
    if [ "$GROUPED" -gt 0 ]; then
      ok_val=$([ "$HIGH_COUNT" -gt 0 ] && echo "warn" || echo "true")
      write_status "world-watch" "$ok_val" \
        "$GROUPED external-world finding(s) across $CLASSES class(es), $HIGH_COUNT high+" \
        "{\"grouped\":$GROUPED,\"high\":$HIGH_COUNT,\"classes\":$CLASSES}"
    else
      write_status "world-watch" "true" "all world-watch lenses clean" '{"grouped":0}'
    fi
  fi

  if command -v emit_event >/dev/null 2>&1 && [ "$GROUPED" -gt 0 ]; then
    sev_val=$([ "$HIGH_COUNT" -gt 0 ] && echo "high" || echo "medium")
    emit_event "world-watch" "$sev_val" \
      "world-watch: $GROUPED finding(s), $HIGH_COUNT high+" \
      "{\"grouped\":$GROUPED,\"high\":$HIGH_COUNT}"
  fi

  if command -v emit_inbox >/dev/null 2>&1 && [ "$HIGH_COUNT" -gt 0 ]; then
    emit_inbox \
      "World-watch found $HIGH_COUNT high-severity external finding(s) — framework EOL or API drift needs attention." \
      "{\"high\":$HIGH_COUNT,\"grouped\":$GROUPED}"
  fi

  if [ "$NOTIFY" = "1" ] && [ "$GROUPED" -gt 0 ] && [ -x ./notify.sh ]; then
    ./notify.sh \
      "world-watch: $GROUPED finding(s) ($HIGH_COUNT high+). Classes: framework-eol/api-drift/dep-deprecated. See world-extras.json." \
      2>/dev/null || true
  fi
fi

_info ""
_info "world-watch complete — $(_now_iso)"
exit 0
