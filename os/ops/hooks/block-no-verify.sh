#!/usr/bin/env bash
# --------------------------------------------------------------------
# claude-hook declaration — read by ops/dead-gate-detect.sh, which fails the
# OS self-check if a declared hook is not actually registered in
# ~/.claude/settings.json. A shipped-but-unwired hook never fires and reads
# as coverage; ops/self-eval-gate.sh sat that way until 2026-09-04.
# claude-hook: PreToolUse
# --------------------------------------------------------------------
# block-no-verify.sh — PreToolUse guard. Deny git invocations that route around
# the commit/push hooks.
#
# WHY: CLAUDE.md has said "never --no-verify" for a long time and nothing enforced
# it. A stated rule with no enforcing code is a preference, not a gate — and the
# session most likely to bypass a hook is an unattended one, where there is nobody
# to notice. Four of the five harnesses reviewed on 2026-09-04 shipped a guard like
# this; this OS shipped the sentence.
#
# The design constraint that matters is FALSE POSITIVES. A guard that trips on
# `git commit -m "don't use --no-verify"` gets switched off within a day, and a
# switched-off guard is worse than none. So the command is tokenised with shlex
# (quote-aware) and tokens are compared for EQUALITY, never substring-matched.
#
# stdin: Claude Code PreToolUse payload. exit 0 = allow, exit 2 = deny (stderr shown).
set -uo pipefail
payload="$(cat 2>/dev/null || true)"
printf '%s' "$payload" | python3 -I -c '
import json, shlex, sys

try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)  # not our payload shape — never block on something we cannot read

if d.get("tool_name") != "Bash":
    sys.exit(0)
cmd = (d.get("tool_input") or {}).get("command") or ""
try:
    tokens = shlex.split(cmd)
except ValueError:
    sys.exit(0)  # unbalanced quotes: the shell will reject it anyway

SEPS = {";", "&&", "||", "|", "&"}
# Subcommands where -n means --no-verify. `git log -n 5` must stay legal.
NO_VERIFY_SUBCMDS = {"commit", "push", "merge", "rebase", "am", "cherry-pick", "revert"}

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

for seg in segments(tokens):
    # skip leading VAR=value environment assignments
    i = 0
    while i < len(seg) and "=" in seg[i] and not seg[i].startswith("-"):
        i += 1
    if i >= len(seg):
        continue
    if seg[i].rsplit("/", 1)[-1] != "git":
        continue
    args = seg[i + 1:]

    subcmd = next((a for a in args if not a.startswith("-")), "")

    for j, a in enumerate(args):
        if a == "--no-verify" or a.startswith("--no-verify="):
            print(f"[block-no-verify] Denied: `{cmd.strip()[:160]}`\n"
                  "  --no-verify skips the pre-commit/pre-push hooks. Those hooks are the gate;\n"
                  "  bypassing them makes the next green run meaningless. Fix what the hook is\n"
                  "  reporting. If the bypass is genuinely necessary, ask Ahmad — do not route\n"
                  "  around it silently. (standard/agent-containment.md)", file=sys.stderr)
            sys.exit(2)
        if a == "-n" and subcmd in NO_VERIFY_SUBCMDS:
            print(f"[block-no-verify] Denied: `{cmd.strip()[:160]}`\n"
                  f"  -n is --no-verify for `git {subcmd}`. Same rule as above.", file=sys.stderr)
            sys.exit(2)
        if a.startswith("core.hooksPath=") or (a == "-c" and j + 1 < len(args) and args[j + 1].startswith("core.hooksPath=")):
            print(f"[block-no-verify] Denied: `{cmd.strip()[:160]}`\n"
                  "  Repointing core.hooksPath disables every git hook for this invocation.\n"
                  "  That is the same bypass as --no-verify wearing a different hat.", file=sys.stderr)
            sys.exit(2)
sys.exit(0)
'
