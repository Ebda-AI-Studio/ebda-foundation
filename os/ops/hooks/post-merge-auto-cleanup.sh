#!/usr/bin/env bash
# claude-hook: PostToolUse
# post-merge-auto-cleanup.sh — PostToolUse hook. After `gh pr merge`, sweep that repo's
# merged worktrees in the background.
#
# WHY: worktree cleanup after a merge used to happen only when the agent remembered, plus one
# daily launchd sweep — so merged trees (each with a full node_modules) piled up between sweeps.
# A rule only in CLAUDE.md is a preference, not a gate; this makes it automatic.
#
# What it does: parses the Bash command with shlex (same style as block-git-add-all.sh, so
# `git commit -m "gh pr merge"` is NOT a merge), and on a real `gh pr merge` launches
# workspace-hygiene.sh --repo <slug> --skip <this session's worktree> DETACHED. The hook itself
# does no network I/O and returns in milliseconds.
#   • `--auto` merges are skipped (nothing merged yet) — the hourly sweep catches them later.
#   • The calling session's own worktree is passed as --skip: removing the cwd of a live
#     session would break it. The hourly sweep removes it once the session has left.
#
# stdin: Claude Code PostToolUse payload. ALWAYS exits 0 — a cleanup hook must never fail a tool.
# Env: POST_MERGE_HYGIENE_BIN overrides the hygiene script path (tests).
# shellcheck source=lib/os-config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/os-config.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-config.sh" 2>/dev/null || true
command -v os_config_load >/dev/null 2>&1 && os_config_load
set -uo pipefail
payload="$(cat 2>/dev/null || true)"

parsed="$(printf '%s' "$payload" | python3 -I -c '
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

for seg in segments(tokens):
    i = 0
    while i < len(seg) and "=" in seg[i] and not seg[i].startswith("-"):
        i += 1
    seg = seg[i:]
    if len(seg) < 3 or seg[0].rsplit("/", 1)[-1] != "gh" or seg[1:3] != ["pr", "merge"]:
        continue
    rest = seg[3:]
    if "--auto" in rest or "--help" in rest or "-h" in rest:
        continue
    repo = ""
    for k, a in enumerate(rest):
        if a in ("-R", "--repo") and k + 1 < len(rest):
            repo = rest[k + 1]
        elif a.startswith("--repo="):
            repo = a[len("--repo="):]
    print(repo)
    print(d.get("cwd") or "")
    break
' 2>/dev/null)"
[ -n "$parsed" ] || exit 0
repo="$(printf '%s\n' "$parsed" | sed -n 1p)"
cwd="$(printf '%s\n' "$parsed" | sed -n 2p)"

# repo: explicit -R/--repo, else the cwd's origin remote (github.com ssh or https)
if [ -z "$repo" ] && [ -n "$cwd" ] && [ -d "$cwd" ]; then
  repo="$(git -C "$cwd" remote get-url origin 2>/dev/null \
    | sed -nE 's#^.*github\.com[:/]([^/]+/[^/]+)$#\1#p' | sed -E 's#\.git$##')"
fi
[ -n "$repo" ] || exit 0

skip=""
[ -n "$cwd" ] && [ -d "$cwd" ] && skip="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || true)"

HYGIENE="${POST_MERGE_HYGIENE_BIN:-$HOME/.claude/scripts/workspace-hygiene.sh}"
if [ ! -f "$HYGIENE" ]; then
  echo "[post-merge-auto-cleanup] $HYGIENE not found — skipping (run ops/install.sh)" >&2
  exit 0
fi

LOG="$HOME/Library/Logs/ebda-os-post-merge-cleanup.log"
mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
nohup bash "$HYGIENE" --repo "$repo" --skip "$skip" >> "$LOG" 2>&1 &
disown 2>/dev/null || true

REPO="$repo" SKIP="$skip" PROJ="$OS_PROJECTS_DIR" python3 -I -c '
import json, os
repo, skip = os.environ["REPO"], os.environ["SKIP"]
msg = ("post-merge cleanup started for " + repo +
       " (log: ~/Library/Logs/ebda-os-post-merge-cleanup.log).")
if skip and os.path.realpath(skip).startswith(os.path.realpath(os.path.join(os.environ["PROJ"], "_worktrees")) + "/"):
    msg += (" The worktree this session is in (" + skip + ") is kept; "
            "it is removed by the hourly sweep once you leave it.")
print(json.dumps({"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": msg}}))
'
exit 0
