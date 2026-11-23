#!/usr/bin/env bash
# --------------------------------------------------------------------
# claude-hook: PreToolUse
# --------------------------------------------------------------------
# block-worktree-install.sh — PreToolUse guard. Deny a bare `npm ci` / `npm install` / `pnpm install` /
# `yarn install` run at the root of a linked git WORKTREE when wt-deps.sh already holds a COMPLETE cache entry
# for that lockfile, and tell the agent to run `wt-deps.sh` (APFS clone) instead.
#
# WHY (2026-10-25): every per-worktree install is ~2.3 GB; a clone is ~0.2 GB. 6 parallel agent worktrees filled
# the Mac disk, and a full host disk fails CI runner jobs.
# A rule only in CLAUDE.md is a preference; this is the gate.
#
# What it must NOT do (false positives get a guard switched off):
#   • block on a cache MISS (lockfile changed / first install) - that install is what fills the cache;
#   • block `npm install <pkg>` (adding a dependency IS a genuine lockfile change);
#   • block in the repo's main checkout, or in a subdir that has its own lockfile;
#   • block when the command carries WT_ALLOW_INSTALL=1 (deliberate escape hatch).
# stdin: PreToolUse payload. exit 0 = allow, exit 2 = deny (stderr shown to the agent). Fails OPEN on anything odd.
set -uo pipefail
payload="$(cat 2>/dev/null || true)"
dir="$(printf '%s' "$payload" | python3 -I -c '
import json, os, shlex, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if d.get("tool_name") != "Bash":
    sys.exit(0)
cmd = (d.get("tool_input") or {}).get("command") or ""
try:
    toks = shlex.split(cmd)
except ValueError:
    sys.exit(0)
SEPS = {";", "&&", "||", "|", "&"}
segs, cur = [], []
for t in toks:
    if t in SEPS:
        if cur: segs.append(cur)
        cur = []
    else:
        cur.append(t)
if cur: segs.append(cur)
cwd = d.get("cwd") or os.getcwd()
for seg in segs:
    env = {}
    i = 0
    while i < len(seg) and "=" in seg[i] and not seg[i].startswith("-"):
        k, _, v = seg[i].partition("="); env[k] = v; i += 1
    seg = seg[i:]
    if not seg: continue
    if seg[0] == "cd" and len(seg) > 1:
        cwd = os.path.normpath(os.path.join(cwd, os.path.expanduser(seg[1]))); continue
    if env.get("WT_ALLOW_INSTALL") == "1" or os.environ.get("WT_ALLOW_INSTALL") == "1":
        continue
    prog = os.path.basename(seg[0]); args = seg[1:]
    pos = [a for a in args if not a.startswith("-")]
    hit = False
    if prog == "npm" and pos[:1] and pos[0] in ("ci", "install", "i") and len(pos) == 1: hit = True
    elif prog == "pnpm" and (not pos or (pos[0] in ("install", "i") and len(pos) == 1)): hit = True
    elif prog == "yarn" and (not pos or (pos[0] == "install" and len(pos) == 1)): hit = True
    if hit and not any(a in ("--prefix", "-C", "--cwd", "--dir", "-g", "--global") or a.startswith(("--prefix=", "--cwd=")) for a in args):
        print(cwd); break
' 2>/dev/null)"
[ -n "$dir" ] && [ -d "$dir" ] || exit 0

top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || exit 0
gd="$(git -C "$dir" rev-parse --absolute-git-dir 2>/dev/null)"; cd_="$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
[ -n "$gd" ] && [ "$gd" != "$cd_" ] || exit 0                      # not a linked worktree
dreal="$(cd "$dir" && pwd -P)"; treal="$(cd "$top" && pwd -P)"
if [ "$dreal" != "$treal" ]; then                                   # subdir: only if it has no lockfile of its own
  for l in package-lock.json pnpm-lock.yaml yarn.lock; do [ -f "$dreal/$l" ] && exit 0; done
fi
WTD="${WT_DEPS_BIN:-$HOME/.claude/scripts/wt-deps.sh}"
[ -x "$WTD" ] || [ -f "$WTD" ] || exit 0
bash "$WTD" --check "$treal" >/dev/null 2>&1 || exit 0              # cache MISS -> a genuine install is allowed

cat >&2 <<MSG
BLOCKED: do not run a per-worktree install here - a complete dependency cache already exists for this lockfile.
Run instead (wt-deps.sh):   bash $WTD $treal
That APFS-clones the cached node_modules (~0.2 GB, seconds) instead of ~2.3 GB and minutes. A full host disk fails CI runner jobs.
If node_modules is already populated and you really need to replace it: WT_DEPS_FORCE=1 bash $WTD $treal
Only a genuine lockfile change (adding/removing a dependency) justifies a fresh install; for a deliberate one prefix the command with WT_ALLOW_INSTALL=1.
MSG
exit 2
