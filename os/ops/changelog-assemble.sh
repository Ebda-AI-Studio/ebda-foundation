#!/usr/bin/env bash
# changelog-assemble.sh - unreleased changes live as ONE FILE EACH in changelog.d/<slug>.md; CHANGELOG.md's `## Unreleased` stays EMPTY between releases.
#
# WHY (2026-11-17, Ruling CHANGELOG-FRAGMENTS-1): every foundation PR appended a bullet to the same lines of CHANGELOG.md, so each merge re-conflicted
# every open PR (#104 -> #105 -> #108 -> #111 -> #112 -> #113 each needed a re-merge just for CHANGELOG). One file per change cannot conflict.
#
#   changelog-assemble.sh                 rewrite the Unreleased section from the fragments
#   changelog-assemble.sh --check         exit 1 unless CHANGELOG.md's Unreleased section equals what the fragments assemble to (CI: a hand edit fails)
#   changelog-assemble.sh --release vX.Y  fold the fragments into a `## vX.Y` section below an emptied Unreleased and delete them
# A fragment is changelog.d/<slug>.md ([A-Za-z0-9._-]+), exactly ONE line, starting with "- ". README.md in that folder is ignored.
# CHANGELOG_ROOT overrides the repo root (tests).
set -euo pipefail
ROOT="${CHANGELOG_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
MODE="write"; REL=""
case "${1:-}" in
  "") ;; --check) MODE="check" ;;
  --release) MODE="release"; REL="${2:?usage: changelog-assemble.sh --release vX.Y.Z}"; [[ "$REL" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "changelog-assemble: release must look like v1.2.3" >&2; exit 64; } ;;
  *) echo "usage: changelog-assemble.sh [--check | --release vX.Y.Z]" >&2; exit 64 ;;
esac
exec python3 -I - "$ROOT" "$MODE" "$REL" <<'PY'
import os, re, sys
root, mode, rel = sys.argv[1:4]
fdir = os.path.join(root, "changelog.d")
cl = os.path.join(root, "CHANGELOG.md")
bullets, bad = [], []
for f in sorted(os.listdir(fdir)) if os.path.isdir(fdir) else []:
    if f == "README.md" or f.startswith("."):
        continue
    if not re.fullmatch(r"[A-Za-z0-9._-]+\.md", f):
        bad.append(f"{f}: file name must be <slug>.md with [A-Za-z0-9._-]"); continue
    lines = open(os.path.join(fdir, f), encoding="utf-8").read().split("\n")
    body = [l for l in lines if l.strip()]
    if len(body) != 1 or not body[0].startswith("- "):
        bad.append(f"{f}: a fragment is exactly ONE line starting with '- '"); continue
    bullets.append((f, body[0].rstrip()))
if bad:
    print("changelog-assemble: bad fragments:\n  " + "\n  ".join(bad), file=sys.stderr); sys.exit(1)
text = open(cl, encoding="utf-8").read()
m = re.search(r"^## Unreleased[ \t]*\n(.*?)(?=^## |\Z)", text, re.S | re.M)
if not m:
    print("changelog-assemble: CHANGELOG.md has no '## Unreleased' section", file=sys.stderr); sys.exit(1)
block = "".join(b + "\n" for _, b in bullets)
if mode == "check":
    hand = [l for l in m.group(1).split("\n") if l.lstrip().startswith("- ")]
    if hand:
        print("changelog-assemble: CHANGELOG.md's Unreleased section must stay empty: it has " + str(len(hand)) + " hand-written bullet(s).\n"
              "  Add changelog.d/<slug>.md instead (one line '- ID (files): what changed'); the release folds the fragments in.", file=sys.stderr)
        sys.exit(1)
    print(f"changelog-assemble: ok ({len(bullets)} fragment(s))"); sys.exit(0)
if mode == "write":
    sys.stdout.write(block); sys.exit(0)
# release
if not bullets:
    print("changelog-assemble: no fragments to release", file=sys.stderr); sys.exit(1)
if any(l.lstrip().startswith("- ") for l in m.group(1).split("\n")):
    print("changelog-assemble: CHANGELOG.md's Unreleased has hand-written bullets; move them to changelog.d/ first (the release would drop them)", file=sys.stderr); sys.exit(1)
if re.search(rf"^## {re.escape(rel)}[ \t]*$", text, re.M):
    print(f"changelog-assemble: {rel} already exists in CHANGELOG.md", file=sys.stderr); sys.exit(1)
new = text[:m.start(1)] + "\n" + f"## {rel}\n" + block + "\n" + text[m.end(1):]
open(cl, "w", encoding="utf-8").write(new)
for f, _ in bullets:
    os.remove(os.path.join(fdir, f))
print(f"changelog-assemble: released {len(bullets)} fragment(s) as {rel}")
PY
