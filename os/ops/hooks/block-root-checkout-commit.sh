#!/usr/bin/env bash
# claude-hook: PreToolUse
# block-root-checkout-commit.sh — PreToolUse guard. Deny `git commit` made from a
# repo's MAIN checkout while it is on main/master.
#
# WHY: "root checkouts stay on main, read-only; every task gets a worktree" is a
# standing rule. Parallel sessions committing in the root checkout is how work lands
# on the wrong branch. Allowed: linked worktrees (git-dir != common-dir) and any
# non-main branch.
#
# The commit's directory is the payload cwd, overridden by a leading `cd X &&`
# or `git -C X`. stdin: PreToolUse payload. exit 0 = allow, exit 2 = deny.
set -uo pipefail
payload="$(cat 2>/dev/null || true)"
out="$(printf '%s' "$payload" | python3 -I -c '
import json, os, shlex, subprocess, sys

try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if d.get("tool_name") != "Bash":
    sys.exit(0)
cmd = (d.get("tool_input") or {}).get("command") or ""
cwd = d.get("cwd") or os.getcwd()
try:
    tokens = shlex.split(cmd)
except ValueError:
    sys.exit(0)

SEPS = {";", "&&", "||", "|", "&"}
GLOBAL_VAL = {"-c", "--git-dir", "--work-tree", "--namespace"}

def segments(toks):
    cur = []
    for t in toks:
        if t in SEPS:
            if cur:
                yield cur
            cur = []
        else:
            cur.append(t)
    if cur:
        yield cur

def git(args, where):
    try:
        r = subprocess.run(["git", "-C", where] + args, capture_output=True, text=True, timeout=10)
    except Exception:
        return None
    return r.stdout.strip() if r.returncode == 0 else None

def resolve(base, p):
    p = os.path.expanduser(p)
    return p if os.path.isabs(p) else os.path.join(base, p)

for seg in segments(tokens):
    if seg[0] == "cd" and len(seg) > 1:
        cwd = resolve(cwd, seg[1])
        continue
    i = 0
    while i < len(seg) and "=" in seg[i] and not seg[i].startswith("-"):
        i += 1
    if i >= len(seg) or seg[i].rsplit("/", 1)[-1] != "git":
        continue
    args = seg[i + 1:]
    where = cwd
    j = 0
    while j < len(args) and args[j].startswith("-"):
        if args[j] == "-C" and j + 1 < len(args):
            where = resolve(where, args[j + 1])
            j += 2
        elif args[j] in GLOBAL_VAL:
            j += 2
        else:
            j += 1
    if j >= len(args) or args[j] != "commit":
        continue
    gd = git(["rev-parse", "--path-format=absolute", "--git-dir"], where)
    cd = git(["rev-parse", "--path-format=absolute", "--git-common-dir"], where)
    br = git(["rev-parse", "--abbrev-ref", "HEAD"], where)
    if not gd or not cd or not br:
        continue  # not a repo / unreadable: never block on what we cannot see
    if os.path.realpath(gd) == os.path.realpath(cd) and br in ("main", "master"):
        print("[block-root-checkout-commit] Denied: `" + cmd.strip()[:160] + "`\n"
              "  root checkouts stay on main read-only — use ~/.claude/scripts/new-task-worktree.sh\n"
              "  (" + where + " is a main checkout on " + br + ")")
        sys.exit(2)
sys.exit(0)
')"
rc=$?
[ -n "$out" ] && printf '%s\n' "$out" >&2
exit $rc
