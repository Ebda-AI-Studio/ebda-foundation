#!/usr/bin/env bash
# check-provenance.sh — gate a repo that carries code taken from another repo.
#
# WHY: Whisky 11's plan is clean-room clones of Ebda OS products with one-way sync
# and client-config scrubbing at the boundary. Both halves rot silently without a
# gate: provenance becomes "some commit last spring", and a scrubbed identifier
# creeps back in through a copied config. deepseek-harness's vendor/README.md is
# the worked example this enforces — manifest keyed on exact commits, exhaustive
# divergence log, and CI asserting the wiring.
#
# Checks:
#   1. VENDOR-PROVENANCE.md exists.
#   2. Every manifest row carries a 40-hex upstream commit (a tag or branch is not
#      provenance — both move).
#   3. No scrub-list pattern appears anywhere in the tracked tree.
#
# Usage: ops/check-provenance.sh --repo <dir> [--file VENDOR-PROVENANCE.md]
#                                [--scope <repo-relative subdir>]
#
# --scope limits the scrub scan to one subtree. Needed whenever the vendored code
# lives INSIDE a larger repo that legitimately contains the scrubbed terms: running
# the gate over all of ebda-foundation reports 52 "violations" because Force
# AI's own OS names Ebda OS's own clients. The scrub list guards a BOUNDARY, so it
# has to be pointed at the thing on the other side of it.
# Exit: 0 clean · 1 a violation · 2 the provenance file is missing
set -uo pipefail
REPO="."; FILE="VENDOR-PROVENANCE.md"; SCOPE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:?}"; shift 2 ;;
    --file) FILE="${2:?}"; shift 2 ;;
    --scope) SCOPE="${2:?--scope needs a repo-relative directory}"; shift 2 ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "check-provenance: unknown argument '$1'" >&2; exit 64 ;;
  esac
done

P="$REPO/$FILE"
if [ ! -f "$P" ]; then
  echo "check-provenance: $P is MISSING. A repo carrying code from elsewhere without a" >&2
  echo "  provenance manifest cannot be synced safely — nobody can say what it came from." >&2
  exit 2
fi

REPO="$REPO" P="$P" SCOPE="$SCOPE" python3 <<'PYPROV'
import os, re, subprocess, sys

repo, p = os.environ["REPO"], os.environ["P"]
scope = os.environ.get("SCOPE") or ""
text = open(p, encoding="utf-8").read()
problems = []

# ---- 2. manifest rows must carry a real commit -----------------------------
SHA = re.compile(r"\b[0-9a-f]{40}\b")
PLACEHOLDER = "0" * 40
rows, bad_rows = 0, []
in_manifest = False
for line in text.split("\n"):
    if line.strip().lower().startswith("## manifest"):
        in_manifest = True; continue
    if in_manifest and line.startswith("## "):
        in_manifest = False
    if not in_manifest or not line.strip().startswith("|"):
        continue
    cells = [c.strip() for c in line.strip().strip("|").split("|")]
    if len(cells) < 6 or cells[0].lower().startswith("directory") or set(cells[0]) <= set("-: "):
        continue
    rows += 1
    m = SHA.search(cells[-1])
    if not m:
        bad_rows.append(f"{cells[0]}: upstream commit is not a 40-hex SHA ({cells[-1]!r})")
    elif m.group(0) == PLACEHOLDER:
        bad_rows.append(f"{cells[0]}: upstream commit is still the all-zero template placeholder")
if rows == 0:
    problems.append("the manifest has no rows — either nothing is vendored (delete the file) "
                    "or the manifest was never filled in")
problems += bad_rows

# ---- 3. scrub list ---------------------------------------------------------
# Parsed out of the file's own scrub table, so the contract lives in one place
# and a repo can extend it without editing this script.
patterns = []
in_scrub = False
for line in text.split("\n"):
    if line.strip().lower().startswith("## scrub list"):
        in_scrub = True; continue
    if in_scrub and line.startswith("## "):
        in_scrub = False
    if in_scrub and line.strip().startswith("|"):
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) >= 2 and not cells[0].lower().startswith("class") and not set(cells[0]) <= set("-: "):
            for tok in re.findall(r"`([^`]+)`", cells[1]):
                tok = tok.strip()
                if tok and tok != "…":
                    patterns.append(tok)

tracked = subprocess.run(["git", "-C", repo, "ls-files"], capture_output=True, text=True).stdout.split("\n")
tracked = [f for f in tracked if f and os.path.basename(f) != os.path.basename(p)]
if scope:
    tracked = [f for f in tracked if f.startswith(scope.rstrip("/") + "/")]

hits = []
for f in tracked:
    full = os.path.join(repo, f)
    try:
        if os.path.getsize(full) > 2_000_000:
            continue
        body = open(full, encoding="utf-8", errors="replace").read()
    except OSError:
        continue
    low = body.lower()
    for pat in patterns:
        core = pat.replace("*", "")
        if core and core.lower() in low:
            hits.append((f, pat))

if not patterns:
    problems.append("the scrub list is empty — the boundary is ungated. Fill in the "
                    "'Scrub list' table before relying on this gate.")

print(f"check-provenance: {rows} manifest row(s), {len(patterns)} scrub pattern(s), "
      f"{len(tracked)} tracked file(s) scanned"
      + (f" (scope: {scope})" if scope else ""))
for f, pat in hits[:25]:
    print(f"  FAIL  scrub violation: '{pat}' appears in {f}")
if len(hits) > 25:
    print(f"  FAIL  ...and {len(hits)-25} more")
for b in bad_rows:
    print(f"  FAIL  {b}")
if hits:
    problems.append(f"{len(hits)} scrub violation(s)")

if problems:
    print("check-provenance: " + "; ".join(problems))
    sys.exit(1)
print("check-provenance: OK")
PYPROV
