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
import re
def logical_lines(text):
    # split on newlines, but keep lines joined while a quote is still open
    out, buf = [], ""
    for line in text.split("\n"):
        buf = line if not buf else buf + "\n" + line
        try:
            shlex.split(buf); out.append(buf); buf = ""
        except ValueError:
            continue
    if buf: out.append(buf)
    return out
def segments(text, depth=0):
    if depth > 4: return []
    res = []
    # recurse into command substitutions: $( ... ) and backticks
    for inner in re.findall(r"\$\(([^()]*)\)", text) + re.findall(r"`([^`]*)`", text):
        res += segments(inner, depth + 1)
    for line in logical_lines(text):
        try:
            lx = shlex.shlex(line, posix=True, punctuation_chars=True); lx.whitespace_split = True
            tokens = list(lx)
        except ValueError:
            tokens = line.split()
        cur = []
        for t in tokens:
            if t and set(t) <= set(";&|()"):
                if cur: res.append(cur)
                cur = []
            else:
                cur.append(t)
        if cur: res.append(cur)
    return res
for seg in segments(cmd):
    while seg and (seg[0] in ("sudo", "env", "command", "nohup", "time", "exec", "{", "!") or ("=" in seg[0] and not seg[0].startswith("-"))):
        seg = seg[1:]
    if not seg:
        continue
    prog = seg[0].rsplit("/", 1)[-1]
    if prog in ("pkill", "killall"):
        sys.stderr.write("BLOCKED: %s kills by pattern and can end other sessions processes. Kill only PIDs you started: kill <pid>, or touch the loop stop file (Ahmad 2026-11-23).\n" % prog)
        sys.exit(2)
    if prog in ("lockf", "flock") and "git" in seg and "push" in seg[seg.index("git"):]:
        sys.stderr.write("BLOCKED: wrapping git push in a lock deadlocks when the pre-push hook takes the same lock (3600 s). Run a plain git push.\n")
        sys.exit(2)
sys.exit(0)
'
