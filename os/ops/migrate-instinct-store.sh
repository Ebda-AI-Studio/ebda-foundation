#!/usr/bin/env bash
# migrate-instinct-store.sh — one-off migration for the instinct store, 2026-09-04.
#
# WHY: until today the store had no project field at all, and `scope` came straight
# from the model's own JSON. The result, measured on the live store: 156 rows, of
# which 110 were scope=global while only 5 had ever been seen more than once. Those
# 105 rows were never gated by anything — the model wrote "global" and was believed.
#
# There is no way to retroactively justify them: nothing recorded where they came
# from. So they are DEMOTED to project scope and marked with their provenance,
# rather than grandfathered. An instinct that earns global will earn it again the
# next time it shows up in a second repo; one that does not, should not be global.
#
# Rows with count>=2 keep global: they were at least observed more than once, which
# is weak evidence but is not nothing, and demoting them would discard the only
# repeat-evidence the store holds.
#
# DRY RUN BY DEFAULT. Pass --apply to write.
set -uo pipefail
STORE="${INSTINCT_STORE:-$HOME/.claude/instincts/store.jsonl}"
APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1

[ -f "$STORE" ] || { echo "migrate-instinct-store: no store at $STORE — nothing to do"; exit 0; }

STORE="$STORE" APPLY="$APPLY" python3 <<'PYMIG'
import json, os, shutil, sys
from datetime import datetime

store_p = os.environ["STORE"]
apply_it = os.environ["APPLY"] == "1"

rows = []
with open(store_p, encoding="utf-8") as fh:
    for line in fh:
        line = line.strip()
        if line:
            rows.append(json.loads(line))

before_global = sum(1 for r in rows if r.get("scope") == "global")
before_project = len(rows) - before_global
demoted = kept = tagged = 0

for r in rows:
    if "projects" not in r:
        r["projects"] = []
        tagged += 1
    r.setdefault("provenance", "pre-2026-09-04, ungated: scope was taken from the model, not earned")
    if r.get("scope") == "global":
        if r.get("count", 1) >= 2:
            kept += 1
        else:
            r["scope"] = "project"
            r["demoted_at"] = datetime.now().strftime("%Y-%m-%dT%H:%M:%S")
            r["demoted_reason"] = "global on first sight, never gated"
            demoted += 1

print(f"store:            {store_p}")
print(f"rows:             {len(rows)}")
print(f"before:           global={before_global}  project={before_project}")
print(f"gained projects[]:{tagged}")
print(f"kept global:      {kept}   (count>=2, weak but real repeat evidence)")
print(f"DEMOTED:          {demoted}   (global on first sight, never gated)")
print(f"after:            global={sum(1 for r in rows if r.get('scope')=='global')}  "
      f"project={sum(1 for r in rows if r.get('scope')!='global')}")

if not apply_it:
    print("\nDRY RUN — nothing written. Re-run with --apply to commit these changes.")
    sys.exit(0)

backup = store_p + ".pre-promotion-fix-" + datetime.now().strftime("%Y%m%d-%H%M%S")
shutil.copy2(store_p, backup)
tmp = store_p + ".tmp.%d" % os.getpid()
with open(tmp, "w", encoding="utf-8") as fh:
    for r in rows:
        fh.write(json.dumps(r) + "\n")
os.replace(tmp, store_p)
print(f"\napplied. backup: {backup}")
PYMIG
