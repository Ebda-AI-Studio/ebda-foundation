#!/usr/bin/env bash
# instinct-extract.sh — the continuous-learning engine (daily launchd job).
# Reads accumulated tool-call traces, runs ONE cheap Haiku pass to distill atomic
# "instincts" (confidence-scored), merges them into a store (dedup + count),
# promotes a project instinct to global once it has been seen in 2+ DISTINCT
# projects, and surfaces high-confidence ones as memory candidates for review.
# ECC continuous-learning, adapted to Ahmad's cost discipline (1 Haiku call/day).
#
# THAT PROMOTION SENTENCE WAS FALSE UNTIL 2026-09-04, in three compounding ways:
#   1. `proj` was computed from $(pwd) and never passed into the merge step, so
#      no store record ever carried a project. Measured: 0 of 156 rows had one.
#   2. The gate was `count>=2`, i.e. two OBSERVATIONS — twice in the same repo on
#      the same afternoon promoted an instinct to global.
#   3. It did not matter anyway, because `scope` was taken straight from the
#      model's own JSON, so an instinct could be born global on first sight and
#      skip the gate entirely. Measured: 110 of 156 rows were global while only
#      5 had count>=2.
# The traces always carried the data (instinct-log.sh writes cwd in field 2);
# the digest threw the grouping away. Now: project identity is derived from the
# cwd's git remote, `scope` from the model is DISCARDED, promotion needs two
# distinct project ids, and a same-project repeat no longer inflates confidence.
set -uo pipefail
# claude CLI crashes under Homebrew node 25 (google-auth-library TypeError, see
# extract.log). Prefer nvm's node 24 (verified working 2026-07-11) when present.
NODE24_BIN=$(ls -d "$HOME/.nvm/versions/node/v24"*/bin 2>/dev/null | tail -1)
export PATH="${NODE24_BIN:+$NODE24_BIN:}/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
BASE="$HOME/.claude/instincts"
TDIR="$BASE/traces"; ADIR="$BASE/traces/_archived"; STORE="$BASE/store.jsonl"
CAND="$BASE/candidates.md"; LOG="$BASE/extract.log"
mkdir -p "$TDIR" "$ADIR" "$(dirname "$STORE")"; touch "$STORE"
ts=$(date +%Y-%m-%dT%H:%M:%S 2>/dev/null || echo now)

# 1. gather un-processed traces (skip tiny ones)
traces=$(find "$TDIR" -maxdepth 1 -name '*.trace' -type f 2>/dev/null)
[ -z "$traces" ] && { echo "$ts no traces" >> "$LOG"; exit 0; }
total_lines=$(cat $traces 2>/dev/null | wc -l | tr -d ' ')
[ "${total_lines:-0}" -lt 15 ] && { echo "$ts only $total_lines trace lines — skip (threshold 15)" >> "$LOG"; exit 0; }

# 2. build a compact trace digest, GROUPED BY PROJECT (cap size to keep the call cheap).
# Field 2 of each trace line is the session cwd. Grouping is what makes an instinct
# attributable to a project at all; the previous digest flattened every project's
# lines into one blob, which is why nothing could be scoped.
projects_json=$(printf '%s\n' $traces | PROJ_TRACES=1 python3 -c '
import hashlib, os, subprocess, sys, json

def git_root(path):
    try:
        r = subprocess.run(["git","-C",path,"rev-parse","--show-toplevel"],
                           capture_output=True, text=True, timeout=5)
        return r.stdout.strip() or None
    except Exception:
        return None

def project_id(cwd):
    """Stable id for a repo. Remote URL first: two worktrees of one repo must
    hash the same, and two different repos with the same directory name must
    not collide. basename($PWD) satisfied neither."""
    root = git_root(cwd) if os.path.isdir(cwd) else None
    key, how = None, "cwd"
    if root:
        try:
            r = subprocess.run(["git","-C",root,"config","--get","remote.origin.url"],
                               capture_output=True, text=True, timeout=5)
            url = r.stdout.strip()
        except Exception:
            url = ""
        if url:
            key, how = url.rstrip("/").removesuffix(".git"), "remote"
        else:
            key, how = os.path.realpath(root), "gitroot"
    if not key:
        key = os.path.realpath(cwd) if cwd and cwd != "?" else "unknown"
    return hashlib.sha1(key.encode()).hexdigest()[:12], how, (os.path.basename(root or cwd or "unknown") or "unknown")

groups = {}
for line in sys.stdin.read().split():
    try:
        rows = open(line, encoding="utf-8", errors="replace").read().splitlines()
    except OSError:
        continue
    for row in rows:
        f = row.split("\t")
        if len(f) < 4:
            continue
        cwd = f[1]
        pid, how, label = project_id(cwd)
        g = groups.setdefault(pid, {"id": pid, "label": label, "how": how, "lines": []})
        g["lines"].append(f"{f[2]} {f[3]}")
print(json.dumps({k: {**v, "lines": v["lines"][:200]} for k, v in groups.items()}))
' 2>/dev/null || echo "{}")

digest=$(PROJECTS_JSON="$projects_json" python3 -c '
import json, os
g = json.loads(os.environ.get("PROJECTS_JSON") or "{}")
out, budget = [], 400
for pid, v in g.items():
    label = v["label"]
    out.append("### project " + pid + " (" + label + ")")
    take = v["lines"][: max(1, budget // max(1, len(g)))]
    out.extend(take)
print("\n".join(out)[:24000])
' 2>/dev/null)

# how many distinct projects contributed to THIS batch — decides whether
# attribution can be deterministic or has to be asked for
project_count=$(PROJECTS_JSON="$projects_json" python3 -c '
import json, os; print(len(json.loads(os.environ.get("PROJECTS_JSON") or "{}")))' 2>/dev/null || echo 0)
single_project=$(PROJECTS_JSON="$projects_json" python3 -c '
import json, os
g = json.loads(os.environ.get("PROJECTS_JSON") or "{}")
print(next(iter(g)) if len(g) == 1 else "")' 2>/dev/null || echo "")

# guard: if the traces carried no real content (broken logger wrote blank fields),
# skip the LLM call entirely — reviewing 400 blank lines burns a round-trip on nothing.
if ! printf '%s' "$digest" | tr -d ' |\n\t' | grep -q .; then
  echo "$ts traces present but digest is blank (logger fields empty) — skip LLM, archiving traces" >> "$LOG"
  for t in $traces; do mv "$t" "$ADIR/" 2>/dev/null; done
  exit 0
fi

PROMPT="You are analyzing a developer's coding-agent tool-call traces to extract reusable INSTINCTS.
An instinct is a SMALL, atomic, learned behavior worth repeating — a trigger + an action. Examples:
{\"trigger\":\"before claiming a change done\",\"action\":\"grep every ref to changed identifiers across code+CI+ops\",\"confidence\":0.8}
Extract 0-4 HIGH-SIGNAL instincts from repeated or notable patterns below. Skip trivia. Output ONLY a JSON array (empty [] if nothing worthwhile). Each item: {trigger, action, confidence (0.3-0.9), project (the exact 12-char id from the '### project <id>' header whose lines the instinct came from)}.
Do NOT output a 'scope' field; scope is decided by how many distinct projects an instinct is later seen in, not by you.

TRACES:
$digest"

# 3. one cheap Haiku pass (guarded; never let a failure break the job)
# CLAUDE_BIN lets a caller point this at a specific binary. Without it the PATH
# this script exports above (homebrew first) shadows anything a test puts on PATH,
# so the extractor could only ever be tested against the real CLI — i.e. not at all
# offline. Auto-Company's loop takes the same override for the same reason.
CLAUDE_BIN="${CLAUDE_BIN:-claude}"
out=$("$CLAUDE_BIN" -p "$PROMPT" --model claude-haiku-4-5-20251001 2>>"$LOG" </dev/null || echo "")

# guard: if the claude call failed/crashed (empty output), keep the traces for the
# next run instead of consuming them for zero extraction (the pre-fix behavior
# silently archived every trace even when the CLI crashed).
if [ -z "$(printf '%s' "$out" | tr -d '[:space:]')" ]; then
  echo "$ts claude call returned empty output — keeping traces for next run" >> "$LOG"
  exit 0
fi
json=$(printf '%s' "$out" | python3 -c "import sys,re,json
t=sys.stdin.read()
m=re.search(r'\[.*\]', t, re.S)
try: print(json.dumps(json.loads(m.group(0)) if m else []))
except Exception: print('[]')" 2>/dev/null || echo "[]")

# 4. merge into the store (dedup by normalized trigger+action; promote at 2 DISTINCT projects)
STORE="$STORE" JSONIN="$json" CAND="$CAND" TSNOW="$ts" \
PROJECTS_JSON="$projects_json" SINGLE_PROJECT="$single_project" python3 <<'PYMERGE'
import hashlib, json, os, re
from datetime import datetime, timedelta

store_p = os.environ["STORE"]
cand_p  = os.environ["CAND"]
ts      = os.environ["TSNOW"]
groups  = json.loads(os.environ.get("PROJECTS_JSON") or "{}")
single  = os.environ.get("SINGLE_PROJECT") or ""
known   = set(groups)

PENDING_TTL_DAYS = 30      # an instinct seen once, in one project, never again, expires
PROMOTE_MIN_PROJECTS = 2   # DISTINCT projects, not observations

def norm(x): return re.sub(r"\s+", " ", (x or "").lower()).strip()
def key(i):  return hashlib.sha1((norm(i.get("trigger")) + "|" + norm(i.get("action"))).encode()).hexdigest()[:12]

store = {}
try:
    with open(store_p, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line:
                o = json.loads(line)
                store[o["id"]] = o
except Exception:
    pass

try:
    new_items = json.loads(os.environ.get("JSONIN") or "[]")
except Exception:
    new_items = []

def attribute(item):
    """Deterministic where possible. With one project in the batch there is nothing
    to guess. With several, the model's tag is accepted only if it names a project
    actually present in this batch; anything else is unattributable and must not
    count toward promotion."""
    if single:
        return single
    tag = str(item.get("project") or "").strip()
    return tag if tag in known else ""

promoted, unattributed = [], 0
for i in new_items:
    if not isinstance(i, dict) or not i.get("trigger") or not i.get("action"):
        continue
    pid = attribute(i)
    if not pid:
        unattributed += 1
    k = key(i)
    conf_in = float(i.get("confidence", 0.5) or 0.5)
    if k in store:
        o = store[k]
        o["count"] = o.get("count", 1) + 1
        o["last"] = ts
        projs = set(o.get("projects") or [])
        is_new_project = bool(pid) and pid not in projs
        if pid:
            projs.add(pid)
        o["projects"] = sorted(projs)
        # Confidence rises only on evidence from a NEW project. A repeat in the same
        # repo is the same evidence twice; inflating on it is how 121 of 156 rows
        # reached >=0.8 without ever crossing a project boundary.
        if is_new_project:
            o["confidence"] = round(min(0.95, max(o.get("confidence", 0.5), conf_in) + 0.05), 2)
        else:
            o["confidence"] = round(max(o.get("confidence", 0.5), conf_in), 2)
        if o.get("scope") != "global" and len(o["projects"]) >= PROMOTE_MIN_PROJECTS:
            o["scope"] = "global"
            o["promoted_at"] = ts
            o.pop("expires_at", None)
            promoted.append(o)
    else:
        # scope from the model is DISCARDED. Everything starts local and earns global.
        store[k] = {
            "id": k, "trigger": i["trigger"], "action": i["action"],
            "confidence": round(conf_in, 2),
            "scope": "project",
            "projects": [pid] if pid else [],
            "count": 1, "first": ts, "last": ts,
            "expires_at": (datetime.now() + timedelta(days=PENDING_TTL_DAYS)).strftime("%Y-%m-%dT%H:%M:%S"),
        }

# expire pending instincts that never recurred — a wrong instinct must be able to die
expired = []
for k, o in list(store.items()):
    exp = o.get("expires_at")
    if o.get("scope") == "project" and exp:
        try:
            if datetime.strptime(exp, "%Y-%m-%dT%H:%M:%S") < datetime.now():
                expired.append(o)
                del store[k]
        except Exception:
            pass

# atomic write — the store was rewritten in place, so a crash mid-write lost every row
tmp = store_p + ".tmp.%d" % os.getpid()
with open(tmp, "w", encoding="utf-8") as fh:
    for o in store.values():
        fh.write(json.dumps(o) + "\n")
os.replace(tmp, store_p)

# candidates: only genuinely cross-project, high-confidence instincts earn a memory file
hot = [o for o in store.values()
       if o.get("confidence", 0) >= 0.8 and len(o.get("projects") or []) >= PROMOTE_MIN_PROJECTS]
# A stale candidates.md is worse than none: it lists instincts that may since have
# been demoted or expired, and reads as current. Always rewrite, even when empty.
if True:
    ctmp = cand_p + ".tmp.%d" % os.getpid()
    with open(ctmp, "w", encoding="utf-8") as fh:
        fh.write("# Instinct candidates\n\n")
        fh.write("High-confidence instincts seen in 2+ DISTINCT projects. Confirm -> fold into a feedback-*.md; reject -> note.\n\n")
        if not hot:
            fh.write(f"_None yet. {len(store)} instinct(s) stored; none has been observed in 2 "
                     "distinct projects at confidence >= 0.8. This file is rewritten every run, so "
                     "an empty list here means empty, not stale._\n")
        for o in sorted(hot, key=lambda x: -x["confidence"]):
            fh.write("- **[%s] (%s, %d projects, x%d)** when *%s* -> %s\n"
                     % (o["confidence"], o["scope"], len(o["projects"]), o.get("count", 1),
                        o["trigger"], o["action"]))
    os.replace(ctmp, cand_p)

print("%s extracted=%d unattributed=%d projects_in_batch=%d store=%d hot=%d promoted=%d expired=%d"
      % (ts, len(new_items), unattributed, len(known), len(store), len(hot), len(promoted), len(expired)))
PYMERGE

# 5. archive processed traces (keep the store, not the raw traces)
for t in $traces; do mv "$t" "$ADIR/" 2>/dev/null; done
# prune archive >14d
find "$ADIR" -name '*.trace' -mtime +14 -delete 2>/dev/null
tail -1 "$LOG" 2>/dev/null
