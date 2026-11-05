#!/usr/bin/env bash
# pin-actions.sh — every GitHub Action reference must be a commit SHA.
#
# WHY: a mutable tag (`actions/checkout@v4`) is a pointer the action's owner can
# repoint at any time. When they do, their new code runs inside our CI with our
# secrets, with no diff on our side and no review. That is the class that hit
# tj-actions/changed-files. A 40-hex SHA cannot be repointed.
#
# Measured 2026-09-04 across ~/Desktop/projects: 223 of 229 action references in
# 20 repos were mutable tags. Only 13 distinct refs existed, so the whole estate
# is 11 SHA lookups — the sweep is cheap; not doing it was the expensive part.
#
# Two things this deliberately does NOT do:
#   • It never "leaves it as-is and exits 0" when a ref cannot be resolved. An
#     unresolvable ref exits 2 and names the ref. A pinning tool that silently
#     skips is worse than none: it reports success over the thing it missed.
#   • --check rewrites nothing. It is the CI gate; a gate that mutates the tree
#     it is judging cannot be trusted to have judged the committed state.
#
# Usage:
#   ops/pin-actions.sh --repo .            # rewrite in place
#   ops/pin-actions.sh --check --repo .    # gate: exit 1 if any ref is mutable
# Exit: 0 ok · 1 --check found mutable refs · 2 a ref could not be resolved
set -uo pipefail

CHECK=0
REPO="."
NESTED=0
while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK=1; shift ;;
    --repo)  REPO="${2:?--repo needs a path}"; shift 2 ;;
    --include-nested) NESTED=1; shift ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *) echo "pin-actions: unknown argument '$1'" >&2; exit 64 ;;
  esac
done

[ -d "$REPO" ] || { echo "pin-actions: no such directory: $REPO" >&2; exit 64; }

# --include-nested also sweeps `<repo>/**/.github/workflows`. The blast-radius sweep
# for this script's own landing found 5 mutable refs in `template/.github/workflows`
# — the scaffold every new project is born from — which a root-only scan cannot see.
# A defect in the template reproduces itself in every future repo, so the gate has
# to reach it. Paths listed in `.pin-actions-ignore` (one glob per line) are skipped:
# audit FIXTURES are deliberately-imperfect inputs and must stay unpinned.
CHECK="$CHECK" NESTED="$NESTED" python3 - "$REPO" <<'PY'
import os, re, subprocess, sys

import fnmatch
repo = sys.argv[1]
check = os.environ.get("CHECK") == "1"
nested = os.environ.get("NESTED") == "1"

ignore = []
ig_path = os.path.join(repo, ".pin-actions-ignore")
if os.path.isfile(ig_path):
    with open(ig_path, encoding="utf-8") as fh:
        ignore = [ln.strip() for ln in fh if ln.strip() and not ln.startswith("#")]

def ignored(rel):
    return any(fnmatch.fnmatch(rel, pat) for pat in ignore)

wf_dirs = []
root_wf = os.path.join(repo, ".github", "workflows")
if os.path.isdir(root_wf):
    wf_dirs.append(root_wf)
if nested:
    for dirpath, dirnames, _ in os.walk(repo):
        if ".git" in dirnames:
            dirnames.remove(".git")
        if os.path.basename(dirpath) == "workflows" and os.path.basename(os.path.dirname(dirpath)) == ".github":
            if os.path.abspath(dirpath) != os.path.abspath(root_wf):
                wf_dirs.append(dirpath)
    wf_dirs = [d for d in wf_dirs if not ignored(os.path.relpath(d, repo))]

if not wf_dirs:
    # Not a finding: plenty of repos have no CI. Say so rather than printing nothing,
    # so a vanished workflows/ dir is visible in the log instead of reading as clean.
    print(f"pin-actions: no .github/workflows under {repo} — nothing to check", file=sys.stderr)
    sys.exit(0)

# `uses:` value, optionally already carrying a trailing comment.
USES = re.compile(r'^(?P<pre>\s*-?\s*uses:\s*)(?P<ref>[^\s#]+)(?P<post>\s*(?:#.*)?)$')
SHA = re.compile(r'^[0-9a-f]{40}$')

files = []
for d in sorted(wf_dirs):
    for f in sorted(os.listdir(d)):
        if f.endswith((".yml", ".yaml")) and not ignored(os.path.relpath(os.path.join(d, f), repo)):
            files.append(os.path.join(d, f))
if not files:
    print(f"pin-actions: workflow dir(s) exist under {repo} but hold no workflow files", file=sys.stderr)
    sys.exit(0)

cache = {}
def resolve(owner_repo, ref):
    """owner/repo@ref -> commit sha. Raises on failure; never returns a guess."""
    key = f"{owner_repo}@{ref}"
    if key in cache:
        return cache[key]
    out = subprocess.run(
        ["gh", "api", f"repos/{owner_repo}/commits/{ref}", "--jq", ".sha"],
        capture_output=True, text=True,
    )
    sha = out.stdout.strip()
    if out.returncode != 0 or not SHA.match(sha):
        raise RuntimeError(f"{key}: {(out.stderr or 'no sha returned').strip().splitlines()[0][:120]}")
    cache[key] = sha
    return sha

mutable = []      # (file, lineno, ref) — for --check
unresolved = []   # (ref, why)
rewritten = 0

for path in files:
    with open(path, encoding="utf-8") as fh:
        lines = fh.read().split("\n")
    changed = False
    for i, line in enumerate(lines):
        m = USES.match(line)
        if not m:
            continue
        spec = m.group("ref").strip('"\'')
        # A local action (./…) or a container ref has no upstream commit to pin.
        if spec.startswith("./") or spec.startswith("docker://") or "@" not in spec:
            continue
        target, _, ref = spec.rpartition("@")
        if SHA.match(ref):
            continue  # already pinned
        rel = os.path.relpath(path, repo)
        if check:
            mutable.append((rel, i + 1, spec))
            continue
        # For owner/repo/path/to/wf.yml@ref the commit lives on owner/repo.
        parts = target.split("/")
        if len(parts) < 2:
            unresolved.append((spec, "not an owner/repo reference"))
            continue
        try:
            sha = resolve("/".join(parts[:2]), ref)
        except RuntimeError as e:
            unresolved.append((spec, str(e)))
            continue
        lines[i] = f'{m.group("pre")}{target}@{sha} # {ref}'
        changed = True
        rewritten += 1
    if changed:
        # Same-directory temp + rename: a half-written workflow file is a broken repo.
        tmp = os.path.join(os.path.dirname(path), f".{os.path.basename(path)}.pin.tmp")
        with open(tmp, "w", encoding="utf-8") as fh:
            fh.write("\n".join(lines))
        os.replace(tmp, path)

if check:
    if mutable:
        print(f"pin-actions: {len(mutable)} mutable action reference(s) — every `uses:` must be a commit SHA:")
        for f, ln, ref in mutable:
            print(f"  {f}:{ln}: {ref}")
        print("  fix: ops/pin-actions.sh --repo <repo>")
        sys.exit(1)
    print(f"pin-actions: all action references pinned across {len(files)} workflow file(s)")
    sys.exit(0)

if unresolved:
    print(f"pin-actions: {len(unresolved)} reference(s) could NOT be resolved — nothing was assumed:")
    for ref, why in unresolved:
        print(f"  {ref}  ({why})")
    sys.exit(2)

print(f"pin-actions: pinned {rewritten} reference(s) across {len(files)} workflow file(s)")
PY
