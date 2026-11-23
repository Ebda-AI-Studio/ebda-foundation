#!/usr/bin/env bash
# --------------------------------------------------------------------
# claude-hook: PostToolUse
# --------------------------------------------------------------------
# post-worktree-deps.sh — PostToolUse hook. After Claude Code creates a git worktree - the EnterWorktree tool or a
# raw `git worktree add` in Bash - run wt-deps.sh on it so the worktree gets APFS-cloned deps (~0.2 GB) and no agent
# ever needs its own npm ci (~2.3 GB).
#
# WHY: the global git post-checkout hook (git-hooks/dispatch.sh) covers every plain repo, but a repo that sets its OWN
# core.hooksPath (husky v9 -> .husky/_) bypasses the global one. This hook closes that gap for Claude sessions and
# subagents, on the harness's own tool events. Agent isolation:"worktree" creates its tree via `git worktree add`,
# which the global hook sees; wt-deps skips a tree that is already populated, so the two never double-install.
#
# Runs wt-deps.sh in HOOK MODE (trusted repos only, --ignore-scripts on a miss).
# Guards: below WT_MIN_FREE_GB (30) it only clones from a cache hit. Never fails the tool (always exit 0).
# stdin: PostToolUse payload. Env: WT_DEPS_BIN overrides the wt-deps path (tests); WT_SKIP_DEPS=1 opts out.
set -uo pipefail
payload="$(cat 2>/dev/null || true)"
[ "${WT_SKIP_DEPS:-0}" = 1 ] && exit 0
cands="$(printf '%s' "$payload" | python3 -I -c '
import json, os, shlex, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
tn = d.get("tool_name"); cwd = d.get("cwd") or os.getcwd(); out = []
if tn == "Bash":
    cmd = (d.get("tool_input") or {}).get("command") or ""
    try: toks = shlex.split(cmd)
    except ValueError: sys.exit(0)
    SEPS = {";", "&&", "||", "|", "&"}; segs, cur = [], []
    for t in toks:
        if t in SEPS:
            if cur: segs.append(cur)
            cur = []
        else: cur.append(t)
    if cur: segs.append(cur)
    for seg in segs:
        i = 0
        while i < len(seg) and "=" in seg[i] and not seg[i].startswith("-"): i += 1
        seg = seg[i:]
        if not seg: continue
        if seg[0] == "cd" and len(seg) > 1:
            cwd = os.path.normpath(os.path.join(cwd, os.path.expanduser(seg[1]))); continue
        if os.path.basename(seg[0]) != "git": continue
        base = cwd; j = 1
        while j < len(seg) and seg[j].startswith("-"):
            if seg[j] == "-C" and j + 1 < len(seg): base = os.path.normpath(os.path.join(base, os.path.expanduser(seg[j+1]))); j += 2
            elif seg[j] == "-c": j += 2
            else: j += 1
        if seg[j:j+2] != ["worktree", "add"]: continue
        k = j + 2
        while k < len(seg):
            a = seg[k]
            if a in ("-b", "-B", "--reason"): k += 2; continue
            if a.startswith("-"): k += 1; continue
            out.append(os.path.normpath(os.path.join(base, os.path.expanduser(a)))); break
elif tn == "EnterWorktree":
    def walk(o):
        if isinstance(o, dict):
            for v in o.values(): yield from walk(v)
        elif isinstance(o, list):
            for v in o: yield from walk(v)
        elif isinstance(o, str):
            yield o
    for blob in (d.get("tool_response"), d.get("tool_input")):
        if isinstance(blob, str):
            try: blob = json.loads(blob)
            except Exception: pass
        for s in walk(blob):
            for w in s.replace("\n", " ").split():
                w = w.strip("\"\x27,;)(")
                if w.startswith("/") and os.path.exists(os.path.join(w, ".git")): out.append(w)
    if not out and os.path.isfile(os.path.join(cwd, ".git")): out.append(cwd)
seen = set()
for p in out:
    if p not in seen: seen.add(p); print(p)
' 2>/dev/null)"
[ -n "$cands" ] || exit 0
. "$(dirname "${BASH_SOURCE[0]}")/../lib/wt-roots.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/wt-roots.sh" 2>/dev/null || true
WTD="${WT_DEPS_BIN:-$HOME/.claude/scripts/wt-deps.sh}"
[ -f "$WTD" ] || exit 0
msgs=""
while IFS= read -r wt; do
  [ -f "$wt/.git" ] && [ -f "$wt/package.json" ] || continue         # linked worktree (.git is a FILE) with a package.json
  if command -v wt_free_kb >/dev/null 2>&1; then free_kb="$(wt_free_kb "$wt")"; else free_kb="$(df -k "$HOME" | awk 'NR==2{print $4}')"; fi
  if [ "${free_kb:-0}" -lt $(( ${WT_MIN_FREE_GB:-30} * 1024 * 1024 )) ] && ! bash "$WTD" --check "$wt" >/dev/null 2>&1; then
    msgs="$msgs wt-deps: host free < ${WT_MIN_FREE_GB:-30} GB and no cache hit - did NOT install deps in $wt (run workspace-hygiene.sh first)."; continue
  fi
  if out="$(WT_DEPS_HOOK=1 bash "$WTD" "$wt" 2>&1)"; then
    msgs="$msgs wt-deps ran for $wt: $(printf '%s' "$out" | tail -1)."
  else
    msgs="$msgs wt-deps FAILED for $wt: $(printf '%s' "$out" | tail -1)."
  fi
done <<< "$cands"
[ -n "$msgs" ] || exit 0
MSGS="$msgs Never run npm ci in a worktree; use wt-deps.sh." python3 -I -c '
import json, os
print(json.dumps({"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": os.environ["MSGS"].strip()}}))'
exit 0
