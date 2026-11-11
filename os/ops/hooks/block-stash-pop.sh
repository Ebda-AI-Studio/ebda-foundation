#!/usr/bin/env bash
# --------------------------------------------------------------------
# claude-hook declaration - read by ops/dead-gate-detect.sh (see block-no-verify.sh).
# claude-hook: PreToolUse
# --------------------------------------------------------------------
# block-stash-pop.sh — PreToolUse guard. Deny `git stash pop` and bare `git stash` / `git stash save`.
#
# WHY (Ahmad 2026-11-11): the stash stack is SHARED by every worktree of a repo. Three agents in one
# night ran `git stash pop` and applied ANOTHER session's stash (once into a different worktree).
# Allowed: `git stash push -m <tag>` (optionally -u), `list`, `show`, `apply <ref>`, `drop <ref>`, `branch`.
# Tokenised with shlex and compared for equality, so `git commit -m "git stash pop"` stays legal.
#
# stdin: Claude Code PreToolUse payload. exit 0 = allow, exit 2 = deny (stderr shown).
set -uo pipefail
payload="$(cat 2>/dev/null || true)"
printf '%s' "$payload" | python3 -I -c '
import json, shlex, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if d.get("tool_name") != "Bash":
    sys.exit(0)
cmd = (d.get("tool_input") or {}).get("command") or ""
try:
    tokens = shlex.split(cmd)
except ValueError:
    sys.exit(0)
SEPS = {";", "&&", "||", "|", "&"}
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
SAFE = {"list", "show", "apply", "drop", "branch"}
for seg in segments(tokens):
    # find "git ... stash" allowing git global options like -C <dir>
    if not seg or seg[0] != "git":
        continue
    i = 1
    while i < len(seg) and seg[i].startswith("-"):
        i += 2 if seg[i] in ("-C", "-c") else 1
    if i >= len(seg) or seg[i] != "stash":
        continue
    rest = seg[i + 1:]
    sub = rest[0] if rest else ""
    bad = False
    if sub in ("pop", "save", "clear"):
        bad = True
    elif sub == "" or sub.startswith("-"):
        bad = True  # bare `git stash` (= push without a tag)
    elif sub == "push":
        bad = not any(a in ("-m", "--message") or a.startswith("--message=") for a in rest[1:])
    elif sub not in SAFE:
        bad = False
    if bad:
        sys.stderr.write("BLOCKED: shared stash across worktrees. Use a WIP commit, or `git stash push -u -m <tag>` then `git stash apply <sha>`; never pop/bare stash/clear.\n")
        sys.exit(2)
sys.exit(0)
'
