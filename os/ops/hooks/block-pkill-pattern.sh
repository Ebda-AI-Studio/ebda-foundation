#!/usr/bin/env bash
# --------------------------------------------------------------------
# claude-hook declaration - read by ops/dead-gate-detect.sh (see block-no-verify.sh).
# claude-hook: PreToolUse
# --------------------------------------------------------------------
# block-pkill-pattern.sh - PreToolUse guard (register OS-F1, worktree-process-hygiene.md). Denies:
#   - `pkill ...` and `killall ...` : they kill by NAME/PATTERN, so one session ends other agents' processes (2026-10-24 incident).
#     Kill only PIDs you started: `kill <pid>`.
#   - `lockf ... git push` / `flock ... git push` : in a repo whose pre-push hook takes the same lock the push waits on its own
#     parent (the 2026-10-25 deadlock, 3600 s). Run a plain `git push`.
# Tokenised with shlex and compared segment by segment, so `git commit -m "pkill -f x"` stays legal.
# stdin: Claude Code PreToolUse payload. exit 0 = allow (also on anything unparseable), exit 2 = deny.
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
segs, cur = [], []
for t in tokens:
    if t in SEPS:
        if cur: segs.append(cur)
        cur = []
    else:
        cur.append(t)
if cur: segs.append(cur)
for seg in segs:
    while seg and (seg[0] in ("sudo", "env", "command", "nohup", "time") or ("=" in seg[0] and not seg[0].startswith("-"))):
        seg = seg[1:]
    if not seg:
        continue
    prog = seg[0].rsplit("/", 1)[-1]
    if prog in ("pkill", "killall"):
        sys.stderr.write("BLOCKED: %s kills by pattern and can end other sessions processes. Kill only PIDs you started: kill <pid>.\n" % prog)
        sys.exit(2)
    if prog in ("lockf", "flock") and "git" in seg and "push" in seg[seg.index("git"):]:
        sys.stderr.write("BLOCKED: wrapping git push in a lock deadlocks when the pre-push hook takes the same lock (3600 s). Run a plain git push.\n")
        sys.exit(2)
sys.exit(0)
'
