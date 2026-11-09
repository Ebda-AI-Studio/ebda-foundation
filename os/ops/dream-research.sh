#!/usr/bin/env bash
# Ebda AI OS - dream-research.sh   (dream phase RESEARCH: turn the week's scan history into ranked improvement candidates)
#
# Reads $OS_STATE_DIR/dream-history.ndjson (one line per scan finding, written by dream-scan.sh), keeps the last DREAM_RESEARCH_DAYS
# (default 7), groups by product + check class, ranks by severity weight x occurrences, and appends the top DREAM_RESEARCH_TOP (default 3)
# per product to $OS_STATE_DIR/dream-findings.json as findings of kind `improvement` (key product:improvement:class, stable, so the
# brain dedupes it). The brain queues them as jobs; the hands do the work. Nothing is sent to a chat.
# Exit 0 always when the history is readable; no history = nothing to rank (exit 0, says so).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/os-config.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-config.sh" 2>/dev/null || true
command -v os_config_load >/dev/null 2>&1 && os_config_load
STATE="$OS_STATE_DIR"; mkdir -p "$STATE"
python3 -I - "$STATE/dream-history.ndjson" "$STATE/dream-findings.json" "${DREAM_RESEARCH_DAYS:-7}" "${DREAM_RESEARCH_TOP:-3}" "${DRY_RUN:-0}" <<'PY'
import json, sys, datetime, collections
hist, out, days, top, dry = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), sys.argv[5] == "1"
cut = datetime.datetime.now() - datetime.timedelta(days=days)
rows = []
try:
    for l in open(hist):
        try: r = json.loads(l)
        except Exception: continue
        if datetime.datetime.fromisoformat(r["at"]) >= cut: rows.append(r)
except FileNotFoundError:
    print("[dream-research] no scan history yet: nothing to rank"); sys.exit(0)
W = {"P1": 8, "P2": 4, "P3": 1}
g = collections.defaultdict(list)
for r in rows: g[(r["product"], r["class"])].append(r)
by_prod = collections.defaultdict(list)
for (p, c), rs in g.items():
    keys = sorted({r["key"] for r in rs})
    score = sum(W.get(r["severity"], 1) for r in rs)
    by_prod[p].append((score, c, len(rs), keys, rs[-1]))
new = []
for p, items in sorted(by_prod.items()):
    for score, c, n, keys, last in sorted(items, key=lambda x: (-x[0], x[1]))[:top]:
        new.append({"repo": last.get("repo", ""), "product": p, "class": "improvement", "severity": "P3", "key": "%s:improvement:%s" % (p, c),
                    "title": "[%s] improvement: %s (%d sighting(s) in %d day(s), score %d)" % (p, c, n, days, score),
                    "file": "", "line": 0, "evidence": "; ".join(keys[:5]) + " | latest: " + str(last.get("evidence", ""))[:200],
                    "detail": "", "fix": "address the recurring %s findings for %s" % (c, p), "autofixable": False})
print("[dream-research] %d improvement candidate(s) from %d sighting(s)" % (len(new), len(rows)))
if dry or not new: sys.exit(0)
try: d = json.load(open(out))
except Exception: d = {"generated_at": datetime.datetime.now().isoformat(timespec="seconds"), "script": "dream-research.sh", "findings": []}
d.setdefault("findings", []).extend(new); d["count"] = len(d["findings"])
json.dump(d, open(out, "w"), indent=2)
PY
exit 0
