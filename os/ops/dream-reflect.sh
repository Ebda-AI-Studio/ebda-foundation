#!/usr/bin/env bash
# ============================================================
# Ebda AI OS — dream-reflect.sh   (Phase 2.5 REFLECT — deep/weekly only)
#
# PURPOSE: the dreaming loop LEARNs about *code* (CVEs, dead code, doc
# drift). It never LEARNs about *itself* — it never reads the memory
# corpus to ask "which recurring lesson is still not enforced by any
# hook/gate/rule?" REFLECT is that self-audit. It mechanizes
# `feedback-os-self-improving-audit-loop` step 10 ("LOOP — get smarter").
#
# DESIGN LAW (2026-07-17 hardening pass): detectors flag PATTERNS, not
# verified defects -> REFLECT PROPOSES, never auto-applies. Every finding
# is autofixable:false and routes through classify.sh (EXCLUDED — human
# only) to a Tier-B proposal. See ops/REFLECT-INTEGRATION-NOTES.md for
# the one-line classify.sh change this implies.
#
# ALGORITHM:
#   1. Corpus = ~/.claude/projects/-Users-ahmadsharaf/memory/feedback-*.md
#      + every <Ebda business folder>/{internal-projects,clients}/*/memory/feedback-*.md (scoped, and its
#      grouped _clients/_personal/_landing-pages siblings). TCC-guarded.
#   2. Cluster feedback files by theme: tokenize the filename (minus the
#      "feedback-" prefix), build bigrams (adjacent-token phrases) and
#      unigrams, union-find files that share a bigram (>=2 files) or a
#      RARE unigram (document frequency 2..8 — specific enough to be a
#      real theme, not English glue). This is a keyword/tag bucketer —
#      simpler and more robust than depending on graphify-out/ existing.
#   3. A cluster is RECURRING if it has >=3 files, OR >=2 files whose
#      mtime span exceeds 30 days (it didn't stick the first time).
#   4. Enforcement check: for the cluster's core theme tokens, search
#      ops/*.sh, ops/detectors/*.json, ~/.claude/settings.json, every
#      repo's .husky/* and .github/workflows/*.yml, and ~/.claude/CLAUDE.md
#      NON-POINTER lines (the memory-index bullet lines `- [x](y.md)` are
#      pointers to the lesson, not a mechanism, and are excluded) for a
#      line where >=2 of the theme's core tokens co-occur within a tight
#      character window (or the single core token as a whole word, for
#      single-token themes). A hit = enforced -> skip. No hit anywhere =
#      unenforced -> emit a finding.
#   5. Findings use the exact dream-findings 9-field schema, autofixable
#      ALWAYS false, repo="__memory__", class="reflect-unenforced-lesson".
#   6. Dedup against $OS_STATE_DIR/reflect-ledger.json (by a stable
#      hash of the theme's core tokens) so a cluster already proposed
#      isn't re-proposed every week. If a previously-proposed cluster is
#      now enforced, the ledger entry is marked resolved (the
#      self-strengthening property: mechanism built -> stops recurring).
#   7. LEARN-BACK: one summary line appended to the ledger (clusters seen
#      / recurring / enforced / newly proposed / deduped).
#
# Usage:
#   ops/dream-reflect.sh                # run, write findings + ledger
#   DRY_RUN=1 ops/dream-reflect.sh      # print findings as JSON; write nothing
#
# Output:
#   $OS_STATE_DIR/dream-findings.json  (findings ARRAY EXTENDED, not
#                                             replaced — dream-scan.sh's
#                                             findings from this same run
#                                             are preserved)
#   $OS_STATE_DIR/reflect-ledger.json  (cluster dedup + learn-back)
#
# Deps: bash 3.2+, python3 (stdlib only).
# ============================================================
set -uo pipefail
# shellcheck source=lib/os-config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/os-config.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-config.sh" 2>/dev/null || true
command -v os_config_load >/dev/null 2>&1 && os_config_load
. "$(dirname "$0")/lib/os-state.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-state.sh" 2>/dev/null || true

# TCC canary (2026-07-12 lesson): abort when the launchd context cannot see
# ~/Desktop — a blind scan must ABORT, never report phantom findings.
OS_JOB_NAME=dream-reflect
if command -v require_projects_access >/dev/null 2>&1; then require_projects_access || exit 0; fi

cd "$(dirname "$0")" || exit 1
OPS_DIR="$(pwd)"

# ---------- config ----------
DRY_RUN="${DRY_RUN:-0}"
STATE_DIR="$OS_STATE_DIR"; mkdir -p "$STATE_DIR"
FINDINGS_FILE="$STATE_DIR/dream-findings.json"
LEDGER_FILE="$STATE_DIR/reflect-ledger.json"
# global memory: <claude home>/projects/<home path with / -> ->/memory (override OS_MEMORY_DIR)
CORPUS_DIR="${OS_MEMORY_DIR:-$HOME/.claude/projects/$(printf %s "$HOME" | tr / -)/memory}"
# Ebda-only (Ahmad 2026-11-06): the scoped-memory and mechanism scan covers the Ebda business folder, never the predecessor products.
PROJECTS_DIR="$(dirname "$(dirname "$OS_HOME")")"
CLAUDE_MD="$HOME/.claude/CLAUDE.md"
SETTINGS_JSON="$HOME/.claude/settings.json"

# ---------- helpers ----------
_log()  { printf '[dream-reflect] %s\n' "$*" >&2; }
_info() { printf '%s\n' "$*"; }

# Second TCC-style guard: the memory corpus lives OUTSIDE ~/Desktop
# (~/.claude/projects/...), a separate TCC scope from the canary above.
# A blind read here would report "0 lessons" as if the corpus were empty
# — the exact Phase-9 TCC failure mode. Abort loudly instead.
if [ ! -r "$CORPUS_DIR" ] || [ -z "$(ls "$CORPUS_DIR"/feedback-*.md 2>/dev/null)" ]; then
  _log "BLIND: cannot read $CORPUS_DIR (or it has zero feedback-*.md files). Aborting — NOT reporting an empty corpus as a finding."
  command -v write_status >/dev/null 2>&1 && write_status "dream-reflect" "warn" "TCC-blind or empty corpus: $CORPUS_DIR unreadable — reflect aborted" '{"tcc":true}'
  exit 0
fi

_info ""
_info "Ebda AI OS — dream-reflect (Phase 2.5 REFLECT)"
_info "Corpus: $CORPUS_DIR"
[ "$DRY_RUN" = "1" ] && _info "(DRY_RUN=1 — findings printed as JSON, nothing written)"
_info ""

# ============================================================
# THE ENGINE — clustering, recurrence, enforcement-check, ledger.
# ============================================================
REFLECT_OUT=$(python3 - "$CORPUS_DIR" "$PROJECTS_DIR" "$OPS_DIR" "$CLAUDE_MD" "$SETTINGS_JSON" "$LEDGER_FILE" "$DRY_RUN" << 'PYEOF'
import json, os, re, sys, glob, hashlib, datetime, time
from collections import Counter, defaultdict

CORPUS_DIR, PROJECTS_DIR, OPS_DIR, CLAUDE_MD, SETTINGS_JSON, LEDGER_FILE, DRY_RUN_S = sys.argv[1:8]
DRY_RUN = (DRY_RUN_S == "1")

# ---------------- 1. load corpus ----------------
STOPWORDS = {
    "and","the","for","with","from","not","no","only","must","never","always",
    "before","after","when","without","via","per","across","over","under","into",
    "needs","need","should","both","each","every","all","any","some","more","most",
    "less","why","how","what","is","are","was","be","as","at","by","in","on","of",
    "to","or","an","a","this","that","its","it","again","new","old","own","yet",
    "vs","re","non","one","two","three","use","used","using","can","cant","dont",
    "doesnt","isnt","wasnt","were","been","being","than","then","so","but","if",
}
# Too generic to be a THEME even though they recur constantly across memory.
GENERIC_UNIGRAM = {
    "feedback","session","misc","general","notes","note","fix","fixes","fixed","trap",
    "traps","gap","gaps","issue","issues","bug","bugs","guard","guards","pattern",
    "patterns","rule","rules","check","checks","error","errors","race","state",
    "and","force","project","code","app","api","data","system","file","files",
    "mode","type","status","level","layer","flow","path","list","name","config",
    "setup","setting","settings","value","key","item","group","part","side","form",
    "field","view","page","info","claude","ai","os","whisky","reference","project",
    "problem","solution","lesson","memory","learning","learn","learned","result",
    "context","time","new","old","update","updates","change","changes","handling",
    "aware","window","store","free","single","block","scope","filter","loop",
}

# Tech/brand words that end in a bare 's' but are NOT a plural — naive
# de-pluralization mangles them (measured: "macos"->"maco", "status"->"statu",
# "postgres"->"postgre"). Kept as-is.
KEEP_AS_IS = {"macos", "ios", "status", "axios", "atlas", "nextjs", "aws",
              "gcs", "cors", "https", "postgres", "canvas", "js", "css", "ux"}

def normalize_token(t):
    t = t.lower()
    if t in KEEP_AS_IS:
        return t
    if len(t) > 4 and t.endswith('s') and not t.endswith('ss'):
        t = t[:-1]
    return t

# GENERIC_UNIGRAM/STOPWORDS are authored as natural-language words; tokens in
# the pipeline are post-normalize_token (stemmed). Normalize the blocklists
# too so e.g. "status" (blocklisted) actually matches the stemmed "statu" —
# otherwise the blocklist silently no-ops for any word ending in a bare 's'.
GENERIC_UNIGRAM = {normalize_token(w) for w in GENERIC_UNIGRAM}
STOPWORDS = {normalize_token(w) for w in STOPWORDS}

def tokenize_stem(stem):
    parts = stem.split('-')
    if parts and parts[0] == 'feedback':
        parts = parts[1:]
    toks = []
    for p in parts:
        if not p or not p.isalpha() or len(p) <= 2:
            continue
        nt = normalize_token(p)
        if nt in STOPWORDS:
            continue
        toks.append(nt)
    return toks

def bigrams(toks):
    return [toks[i] + '_' + toks[i + 1] for i in range(len(toks) - 1)]

files = sorted(glob.glob(os.path.join(CORPUS_DIR, "feedback-*.md")))
scoped = []
for base in [PROJECTS_DIR, os.path.join(PROJECTS_DIR, "internal-projects"), os.path.join(PROJECTS_DIR, "clients")]:
    scoped.extend(glob.glob(os.path.join(base, "*", "memory", "feedback-*.md")))
scoped = [f for f in scoped if "_worktrees" not in f]

# Dedup by BASENAME, not just full path — the same lesson can legitimately
# live in both the global corpus and a project-scoped memory/ dir (the
# routing table in CLAUDE.md: "Cross-project pattern -> Scoped canonical +
# vault MOC"). Counting both copies double-weights that one lesson toward
# recurrence. Prefer the global corpus copy as the canonical representative.
by_basename = {}
for fp in files + scoped:
    b = os.path.basename(fp)
    if b not in by_basename:
        by_basename[b] = fp
files = sorted(by_basename.values())

if not files:
    print(json.dumps({"error": "no corpus files found", "clusters": [], "findings": []}))
    sys.exit(0)

records = []
for fp in files:
    stem = os.path.splitext(os.path.basename(fp))[0]
    toks = tokenize_stem(stem)
    try:
        mtime = os.path.getmtime(fp)
    except Exception:
        mtime = time.time()
    records.append({"path": fp, "stem": stem, "tokens": toks, "bigrams": bigrams(toks), "mtime": mtime})

# ---------------- 2. cluster by theme (independent token/bigram buckets) ----------------
# NOT union-find (a transitive union chains file1<->file2 via key A,
# file2<->file3 via an unrelated key B, and transitively merges unrelated
# files — measured 324/385 files collapsing into one mega-cluster before this
# rewrite). NOT single-canonical-key-per-file either (tried next: forcing
# each file to pick its ONE rarest token systematically loses the real theme
# to an even-rarer incidental co-occurring word — e.g. all 3 "worktree"
# lessons lost their "worktree" membership to "parallel"/"isolation"/
# "cleanup" respectively, because each of those had a lower document
# frequency than "worktree" in the one file that happened to also use it).
#
# Instead: every sufficiently RARE bigram/unigram (df in RARE_MIN..RARE_MAX)
# independently defines its own bucket, and a file joins EVERY bucket its
# tokens qualify it for. Buckets never merge with each other (no shared
# structure to chain through), so this can't produce a mega-cluster; a file
# can legitimately appear in more than one theme (e.g. a "subagent worktree
# isolation" lesson is fair game for both a "worktree" theme and a
# "subagent" theme) — that's a feature, not noise, for a propose-only tool.
RARE_MIN, RARE_MAX = 2, 8

df_bigram = Counter()
df_unigram = Counter()
for r in records:
    for b in set(r["bigrams"]):
        df_bigram[b] += 1
    for t in set(r["tokens"]):
        if t in GENERIC_UNIGRAM:
            continue
        df_unigram[t] += 1

bigram_files = defaultdict(list)
unigram_files = defaultdict(list)
for i, r in enumerate(records):
    for b in set(r["bigrams"]):
        if RARE_MIN <= df_bigram[b] <= RARE_MAX:
            bigram_files[b].append(i)
    for t in set(r["tokens"]):
        if t in GENERIC_UNIGRAM:
            continue
        if RARE_MIN <= df_unigram[t] <= RARE_MAX:
            unigram_files[t].append(i)

clusters = []
seen_member_sets = {}  # frozenset(idxs) -> True, to drop exact-duplicate clusters

def add_cluster(kind, key, idxs):
    if len(idxs) < 2:
        return
    fset = frozenset(idxs)
    if fset in seen_member_sets:
        return  # identical membership already covered by another (usually a bigram) cluster
    seen_member_sets[fset] = True
    members = [records[i] for i in idxs]
    label_tokens = key.split('_') if kind == "bigram" else [key]
    core_tokens = sorted(set(label_tokens))
    theme = "-".join(label_tokens)
    mtimes = [m["mtime"] for m in members]
    span_days = (max(mtimes) - min(mtimes)) / 86400.0
    clusters.append({
        "theme": theme,
        "core_tokens": core_tokens,
        "members": members,
        "file_count": len(members),
        "span_days": round(span_days, 1),
    })

# Bigrams first (more specific phrases), so an identical-membership unigram
# bucket gets dropped as a duplicate in favor of the more descriptive label.
for b, idxs in sorted(bigram_files.items()):
    add_cluster("bigram", b, idxs)
for t, idxs in sorted(unigram_files.items()):
    add_cluster("unigram", t, idxs)

# ---------------- 3. recurrence filter ----------------
for c in clusters:
    c["recurring"] = (c["file_count"] >= 3) or (c["file_count"] >= 2 and c["span_days"] > 30)

# ---------------- 4. enforcement check ----------------
def claude_md_gate_lines(path):
    try:
        raw = open(path, errors="replace").read().split("\n")
    except Exception:
        return []
    # Exclude memory-index POINTER lines (`- [slug](file.md)` / `· [slug](file.md)`)
    # — those link to the lesson itself, not to an enforcement mechanism.
    return [l for l in raw if not re.search(r'\[.*?\]\(.*?\.md\)', l)]

def plain_lines(path):
    try:
        return open(path, errors="replace").read().split("\n")
    except Exception:
        return []

_line_cache = {}
def lines_of(path):
    if path not in _line_cache:
        if path == CLAUDE_MD:
            _line_cache[path] = claude_md_gate_lines(path)
        else:
            _line_cache[path] = plain_lines(path)
    return _line_cache[path]

mech_sources = []
# Exclude dream-reflect.sh itself — its own FIX_HINTS text literally contains
# phrases like "lockfile drift" and "deploy verification", which would
# otherwise self-match as "evidence" that the theme it's PROPOSING is
# already enforced (circular).
mech_sources += sorted(p for p in glob.glob(os.path.join(OPS_DIR, "*.sh"))
                       if os.path.basename(p) != "dream-reflect.sh")
mech_sources += sorted(glob.glob(os.path.join(OPS_DIR, "detectors", "*.json")))
if os.path.isfile(SETTINGS_JSON):
    mech_sources.append(SETTINGS_JSON)
if os.path.isfile(CLAUDE_MD):
    mech_sources.append(CLAUDE_MD)

for base in [PROJECTS_DIR, os.path.join(PROJECTS_DIR, "internal-projects"), os.path.join(PROJECTS_DIR, "clients")]:
    if not os.path.isdir(base):
        continue
    try:
        entries = os.listdir(base)
    except Exception:
        continue
    for entry in entries:
        if entry.startswith('_'):
            continue  # skip _worktrees / re-descending into grouping dirs
        repo_dir = os.path.join(base, entry)
        if not os.path.isdir(repo_dir):
            continue
        husky_dir = os.path.join(repo_dir, ".husky")
        if os.path.isdir(husky_dir):
            for fn in os.listdir(husky_dir):
                fp = os.path.join(husky_dir, fn)
                if os.path.isfile(fp):
                    mech_sources.append(fp)
        wf_dir = os.path.join(repo_dir, ".github", "workflows")
        if os.path.isdir(wf_dir):
            for fn in os.listdir(wf_dir):
                if fn.endswith((".yml", ".yaml")):
                    mech_sources.append(os.path.join(wf_dir, fn))

def word_re(t):
    return re.compile(r'\b' + re.escape(t) + r'\b', re.IGNORECASE)

WINDOW = 40  # chars — "same phrase", not "same file"

# ops/*.sh scripts are large, prose-heavy, and mention almost any common word
# SOMEWHERE incidentally (measured: "store" matched a health-check hostname
# list, "onesignal"/"managed-db" matched a Gmail-alert-sender domain allowlist —
# none of these are the theme's actual enforcement). A single-token theme is
# too weak a signal to trust a full-body grep of ops/*.sh; for those, only
# the script's OWN identity counts as evidence: its filename (a script
# literally named after the theme) or its purpose header (first 5 lines —
# where every ops/*.sh in this repo states what it does, per house style).
# Two-token (bigram/phrase) themes are specific enough that a tight-window
# same-line co-occurrence anywhere in the file is trustworthy evidence.
HEADER_LINES = 5

def ops_sh_restricted_lines(path):
    base = os.path.splitext(os.path.basename(path))[0]
    name_line = base.replace('-', ' ').replace('_', ' ')
    all_lines = lines_of(path)
    header = [l for l in all_lines[:HEADER_LINES] if l.strip()]
    return [name_line] + header

def mechanism_hit(core_tokens):
    """Return (source, lineno, snippet) on the first hit, else None."""
    single = len(core_tokens) <= 1
    pats = [word_re(t) for t in core_tokens]
    for src in mech_sources:
        is_ops_sh = src.endswith(".sh") and os.path.dirname(src) == OPS_DIR
        if single and src == SETTINGS_JSON:
            # settings.json permission entries are full repo PATHS
            # ("Edit(.../some-product/**)") — a single generic token
            # like "bulk" hits the path substring, not a real mechanism.
            # Bigram themes still search it (two-word co-occurrence in a
            # path is not a plausible coincidence).
            continue
        candidate_lines = ops_sh_restricted_lines(src) if (single and is_ops_sh) else lines_of(src)
        for i, line in enumerate(candidate_lines, 1):
            if single:
                m = pats[0].search(line) if pats else None
                if m:
                    lineno = 0 if (is_ops_sh and i == 1) else i  # 0 = filename match, not a line
                    return (src, lineno, line.strip()[:140])
                continue
            positions = [m.start() for m in (p.search(line) for p in pats) if m]
            if len(positions) >= 2:
                positions.sort()
                if positions[-1] - positions[0] <= WINDOW:
                    return (src, i, line.strip()[:140])
    return None

for c in clusters:
    if not c["recurring"]:
        c["enforced"] = None
        continue
    hit = mechanism_hit(c["core_tokens"])
    c["enforced"] = bool(hit)
    c["enforcement_evidence"] = (
        {"source": os.path.relpath(hit[0], os.path.expanduser("~")), "line": hit[1], "snippet": hit[2]}
        if hit else None
    )

# ---------------- 5/6. build findings + ledger dedup ----------------
def cluster_id(c):
    key = "|".join(sorted(c["core_tokens"]))
    return hashlib.sha256(key.encode()).hexdigest()[:16]

try:
    ledger = json.load(open(LEDGER_FILE)) if os.path.isfile(LEDGER_FILE) else {"entries": []}
except Exception:
    ledger = {"entries": []}
ledger.setdefault("entries", [])
proposed_ids = {e.get("cluster_id"): e for e in ledger["entries"] if e.get("status") == "proposed"}

now_iso = datetime.datetime.now().isoformat(timespec="seconds")
findings = []
newly_proposed = []
deduped = []
resolved_now = []

recurring = [c for c in clusters if c["recurring"]]
unenforced_recurring = [c for c in recurring if not c["enforced"]]
# Cap total proposals per run (house style: detector-run.py caps at 25,
# dream-scan.sh digest caps at 8/repo) — a weekly self-audit shouldn't dump
# 50+ issues on one run even if the corpus genuinely has that many gaps.
MAX_FINDINGS = 25
unenforced_recurring.sort(key=lambda c: (-c["file_count"], -c["span_days"]))
unenforced_recurring = unenforced_recurring[:MAX_FINDINGS]

FIX_HINTS = {
    ("deploy", "verification"): "a pre-push hook (or CI job) that simulates the deploy target's exact install+build+typecheck before pushing",
    ("deploy", "verify"): "a pre-push hook (or CI job) that simulates the deploy target's exact install+build+typecheck before pushing",
    ("lockfile", "drift"): "a pre-push `npm ci --dry-run` gate (or a dream-scan lockfile-staleness detector) failing the push on drift",
    ("merge", "squash"): "a post-merge CI job (or ops/*.sh check) diffing origin/<branch> against origin/main after every squash-merge and opening a parity PR if the branch had commits the squash-merge didn't capture",
}

for c in unenforced_recurring:
    cid = cluster_id(c)
    if cid in proposed_ids:
        deduped.append(c["theme"])
        continue
    rep = sorted(c["members"], key=lambda m: -m["mtime"])[0]
    hint = FIX_HINTS.get(tuple(sorted(c["core_tokens"])[:2]))
    if not hint:
        hint = ("add an enforcement mechanism (pre-push hook / CI gate / ops/detectors/*.json rule / "
                "CLAUDE.md gate line) for the recurring theme: " + c["theme"])
    if c["file_count"] >= 5:
        sev = "high"
    elif c["file_count"] >= 3:
        sev = "medium"
    else:
        sev = "low"
    detail = ("%d memory files (%s) span %.0f days with no enforcement mechanism found in "
               "ops/*.sh, ops/detectors/*.json, settings.json, .husky/, .github/workflows/, or "
               "a CLAUDE.md gate line — it recurred because it never got a mechanism, only more memory."
               ) % (c["file_count"], ", ".join(sorted(os.path.basename(m["path"]) for m in c["members"]))[:200], c["span_days"])
    findings.append({
        "repo": "__memory__",
        "class": "reflect-unenforced-lesson",
        "severity": sev,
        "file": os.path.basename(rep["path"]),
        "line": 0,
        "title": "recurring unenforced lesson: " + c["theme"],
        "detail": detail,
        "fix": hint,
        "autofixable": False,
    })
    newly_proposed.append(c["theme"])
    ledger["entries"].append({
        "cluster_id": cid,
        "theme": c["theme"],
        "core_tokens": c["core_tokens"],
        "file_count": c["file_count"],
        "status": "proposed",
        "proposed_at": now_iso,
    })

# Mark previously-proposed clusters that are now enforced as resolved
# (the self-strengthening property: a mechanism got built, stop flagging).
now_enforced_ids = {cluster_id(c) for c in recurring if c["enforced"]}
for e in ledger["entries"]:
    if e.get("status") == "proposed" and e.get("cluster_id") in now_enforced_ids:
        e["status"] = "resolved"
        e["resolved_at"] = now_iso
        resolved_now.append(e.get("theme"))

learn_back = {
    "type": "learn-back",
    "ts": now_iso,
    "clusters_seen": len(clusters),
    "clusters_recurring": len(recurring),
    "clusters_enforced": sum(1 for c in recurring if c["enforced"]),
    "clusters_unenforced": len(unenforced_recurring),
    "clusters_proposed_new": len(newly_proposed),
    "clusters_deduped": len(deduped),
    "clusters_resolved_now": len(resolved_now),
    "summary": ("REFLECT: %d clusters seen, %d recurring, %d enforced, %d unenforced "
                "(%d newly proposed, %d already-proposed/deduped, %d resolved this run)"
                ) % (len(clusters), len(recurring), sum(1 for c in recurring if c["enforced"]),
                     len(unenforced_recurring), len(newly_proposed), len(deduped), len(resolved_now)),
}

if not DRY_RUN:
    ledger.setdefault("entries", []).append(learn_back)
    try:
        # temp + rename — append-only ledger, a torn write loses history
        _t = LEDGER_FILE + ".tmp.%d" % os.getpid()
        with open(_t, "w") as f:
            json.dump(ledger, f, indent=2)
        os.replace(_t, LEDGER_FILE)
    except Exception as e:
        sys.stderr.write("[dream-reflect] ledger write error: %s\n" % e)

# ---------------- output ----------------
digest_clusters = []
for c in clusters:
    digest_clusters.append({
        "theme": c["theme"],
        "file_count": c["file_count"],
        "span_days": c["span_days"],
        "recurring": c["recurring"],
        "enforced": c.get("enforced"),
        "evidence": c.get("enforcement_evidence"),
        "files": sorted(os.path.basename(m["path"]) for m in c["members"]),
    })

result = {
    "generated_at": now_iso,
    "script": "dream-reflect.sh",
    "corpus_files": len(files),
    "clusters": digest_clusters,
    "findings": findings,
    "newly_proposed": newly_proposed,
    "deduped": deduped,
    "resolved_now": resolved_now,
    "learn_back": learn_back,
}
print(json.dumps(result))
PYEOF
)

PY_EXIT=$?
if [ "$PY_EXIT" != "0" ] || [ -z "$REFLECT_OUT" ]; then
  _log "engine failed (exit $PY_EXIT) — writing nothing, treating as no findings (fail-open)"
  exit 0
fi

# ---------------- human digest + JSON-to-stdout (DRY_RUN) ----------------
python3 - "$REFLECT_OUT" "$DRY_RUN" "$FINDINGS_FILE" << 'PYEOF'
import json, os, sys, datetime

result   = json.loads(sys.argv[1])
dry_run  = (sys.argv[2] == "1")
findings_file = sys.argv[3]

findings = result.get("findings", [])
clusters = result.get("clusters", [])

print()
print("=" * 62)
print("  DREAM-REFLECT — memory self-audit")
print("  " + result.get("generated_at", ""))
print("=" * 62)
print(f"  corpus files scanned: {result.get('corpus_files', 0)}")
print(f"  clusters found:       {len(clusters)}")
recurring = [c for c in clusters if c.get("recurring")]
print(f"  recurring clusters:   {len(recurring)}")
print()

for c in sorted(recurring, key=lambda c: (c["enforced"] is True, -c["file_count"])):
    tag = "ENFORCED" if c["enforced"] else "UNENFORCED"
    print(f"  [{tag:10}] {c['theme']}  ({c['file_count']} files, {c['span_days']:.0f}d span)")
    if c.get("evidence"):
        ev = c["evidence"]
        print(f"      mechanism: {ev['source']}:{ev['line']}  \"{ev['snippet']}\"")
    print(f"      files: {', '.join(c['files'][:6])}" + (" ..." if len(c["files"]) > 6 else ""))
print()

if findings:
    print(f"  {len(findings)} finding(s) this run (newly_proposed={len(result.get('newly_proposed', []))}, "
          f"deduped={len(result.get('deduped', []))}):")
    for f in findings:
        print(f"    [{f['severity'].upper():8}] {f['title']}")
        print(f"      fix: {f['fix']}")
else:
    print("  No new findings (all recurring clusters enforced, or already proposed).")

lb = result.get("learn_back", {})
print()
print("  " + lb.get("summary", ""))
print()

if dry_run:
    print("DRY_RUN=1 — nothing written. Findings JSON:")
    print(json.dumps(findings, indent=2))
else:
    # Extend (not replace) dream-findings.json with reflect's findings.
    try:
        if os.path.isfile(findings_file):
            existing = json.load(open(findings_file))
        else:
            existing = {"generated_at": result.get("generated_at"), "script": "dream-scan.sh", "count": 0, "findings": []}
    except Exception:
        existing = {"generated_at": result.get("generated_at"), "script": "dream-scan.sh", "count": 0, "findings": []}

    existing.setdefault("findings", [])
    existing["findings"].extend(findings)
    existing["count"] = len(existing["findings"])
    if findings:
        existing["script"] = (existing.get("script") or "")
        if "dream-reflect" not in (existing.get("script") or ""):
            existing["script"] = (existing.get("script", "") + "+dream-reflect.sh").lstrip("+")

    with open(findings_file, "w") as f:
        json.dump(existing, f, indent=2)
    print(f"[dream-reflect] appended {len(findings)} finding(s) to {findings_file} (total now {existing['count']})")
PYEOF
