#!/usr/bin/env bash
# claude-hook: PreToolUse
# block-git-add-all.sh — PreToolUse guard. Deny `git add -A | --all | .`.
#
# WHY: "git add specific paths, never -A/." is a standing rule (nested repos +
# untracked sensitive files). A rule only in CLAUDE.md is a preference, not a gate.
# Tokenised with shlex and compared for EQUALITY, so `git commit -m "no git add -A"`
# and `git add ./src/file.ts` stay legal.
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

# git global options that take a separate value argument
GLOBAL_VAL = {"-C", "-c", "--git-dir", "--work-tree", "--namespace"}

for seg in segments(tokens):
    i = 0
    while i < len(seg) and "=" in seg[i] and not seg[i].startswith("-"):
        i += 1
    if i >= len(seg) or seg[i].rsplit("/", 1)[-1] != "git":
        continue
    args = seg[i + 1:]
    j = 0
    while j < len(args) and args[j].startswith("-"):
        j += 2 if args[j] in GLOBAL_VAL else 1
    if j >= len(args) or args[j] != "add":
        continue
    rest = args[j + 1:]
    bad = None
    for a in rest:
        if a == "--":
            continue
        if a in ("--all", "-A", ".") or (a.startswith("-") and not a.startswith("--") and "A" in a[1:]):
            bad = a
            break
    if bad:
        print("[block-git-add-all] Denied: `" + cmd.strip()[:160] + "`\n"
              "  git add specific paths, never -A/. (nested repos + untracked sensitive files)",
              file=sys.stderr)
        sys.exit(2)
sys.exit(0)
'
