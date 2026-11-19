#!/usr/bin/env bash
# ============================================================
# Ebda AI OS - dream-standard-drift.sh
#   The "memory -> OS standard" authoring bridge (PROPOSE-ONLY).
#
# PURPOSE: the memory pipeline already keeps the foundation's MECHANICAL
# artifacts in sync (sync-foundation.sh). But turning a cross-cutting memory
# LESSON into a standard/ rubric or ops/ behavior needs reasoning — that was the
# one manual step. This lens closes it autonomously, conservatively:
#
#   DETECT (deterministic, ~free): find cross-cutting memory lessons (the ones
#     marked "indexed in global MEMORY.md") changed in the last window that are
#     NOT yet referenced anywhere in standard/ — i.e. a standard GAP.
#     Scans BOTH `feedback-*.md` AND `reference-*.md` in the global memory root.
#     (2026-08-16: it scanned feedback-* only. But the memory routing table sends
#     every cross-project TOOL/API reference to `reference-*.md`, so that whole
#     category — tools, API recipes, setup traps — was structurally invisible to
#     this bridge and could never reach standard/. The sentinel below is what
#     gates cross-cutting-ness; the filename prefix should not also gate it.)
#   PROPOSE (LLM, capped, propose-only): for up to N gaps, dispatch claude -p to
#     DRAFT a foundation PR that folds the lesson into the right standard doc.
#     It NEVER merges (always a draft PR, human reviews). If the edit is too big
#     or claude is unavailable, it falls back to opening an ISSUE so the signal
#     is never lost.
#
# Safety invariants:
#   1. NEVER merges. Output is always a *draft* PR or an issue. (Standard content
#      is reasoning-authored => always human-reviewed; unlike dream-fix there is
#      no auto-merge path here, by design.)
#   2. Size-capped: a draft touching > DRIFT_MAX_FILES files or > DRIFT_MAX_LINES
#      lines is discarded and downgraded to an issue.
#   3. Dedup ledger: a lesson proposed once is not re-proposed.
#   4. DRY_RUN=1 stops before any worktree/LLM/PR/issue — detection + report only.
#
# Usage:
#   ops/dream-standard-drift.sh            # detect + propose (capped)
#   ops/dream-standard-drift.sh --reseed   # re-propose lessons that were proposed to the previous repo (once each)
#   DRY_RUN=1 ops/dream-standard-drift.sh  # detect + report only
#   DRIFT_NO_LLM=1 ops/dream-standard-drift.sh   # detect + open ISSUES only (no drafting)
#
# Env:
#   DRIFT_WINDOW_DAYS (default 7)  — how far back a memory file counts as "recent"
#   DRIFT_MAX_DRAFTS  (default 1)  — max LLM drafts per run (cost cap)
#   DRIFT_MAX_FILES   (default 2)  — a draft touching more files -> downgrade to issue
#   DRIFT_MAX_LINES   (default 80) — a draft changing more lines -> downgrade to issue
#   DRIFT_NO_LLM      (default 0)  — skip drafting; open issues for gaps instead
#
# Deps: bash 3.2+, python3, git, gh CLI; claude CLI (optional — falls back to issues).
# ============================================================
set -uo pipefail
# CLAUDE_BIN lets a test point this at a stub. Without it the model call is
# untestable offline, which is why none of the OS's 17 model-calling scripts
# had a single behavioural test. Defaults to the real CLI.
CLAUDE_BIN="${CLAUDE_BIN:-claude}"
# shellcheck source=lib/os-config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/os-config.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-config.sh" 2>/dev/null || true
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/wt-roots.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/wt-roots.sh" 2>/dev/null || true
command -v os_config_load >/dev/null 2>&1 && os_config_load
. "$(dirname "$0")/lib/os-state.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-state.sh" 2>/dev/null || true

# TCC canary (2026-07-12): abort when the launchd context cannot see ~/Desktop
OS_JOB_NAME=dream-standard-drift
if command -v require_projects_access >/dev/null 2>&1; then require_projects_access || exit 0; fi

_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

SVC_ENV="${WHISKY_SERVICES_ENV:-$OS_SERVICES_ENV}"
[ -f "$SVC_ENV" ] && { set -a; . "$SVC_ENV"; set +a; }

DRY_RUN="${DRY_RUN:-0}"
BASELINE=0
RESEED=0
for a in "$@"; do case "$a" in
  --notify)   ;;               # accepted and ignored: the OS opens PRs/issues, it does not message
  --reseed)   RESEED=1 ;;      # treat ledger entries proposed to the previous repo as not yet proposed (window ignored)
  --baseline) BASELINE=1 ;;   # acknowledge ALL current gaps without proposing (one-time seed)
esac; done

WINDOW_DAYS="${DRIFT_WINDOW_DAYS:-7}"
MAX_DRAFTS="${DRIFT_MAX_DRAFTS:-1}"
MAX_FILES="${DRIFT_MAX_FILES:-2}"
MAX_LINES="${DRIFT_MAX_LINES:-80}"
NO_LLM="${DRIFT_NO_LLM:-0}"

GLOBAL_MEM="${OS_MEMORY_DIR:-$HOME/.claude/projects/$(printf %s "$HOME" | tr / -)/memory}"
FND="$OS_HOME"
SLUG_REPO="$OS_REPO_SLUG"
STD_REL="os/standard"
BASE_BRANCH="$(git -C "$FND" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')"; BASE_BRANCH="${BASE_BRANCH:-main}"
STATE_DIR="$OS_STATE_DIR"; mkdir -p "$STATE_DIR"
LEDGER="$STATE_DIR/standard-drift-proposed.json"   # {slug: {"at": iso-ts, "repo": slug} | legacy iso-ts string = proposed to the previous repo}
SENTINEL="indexed in global MEMORY.md"             # marks a cross-cutting lesson

_log()  { printf '[std-drift] %s\n' "$*" >&2; }
_info() { printf '%s\n' "$*"; }

command -v git >/dev/null 2>&1 || { _log "git missing"; exit 1; }
[ -d "$GLOBAL_MEM" ] || { _log "global memory not found: $GLOBAL_MEM"; exit 0; }
[ -e "$FND/.git" ]   || { _log "foundation repo not found: $FND"; exit 0; }

# already proposed to THIS repo? (legacy string entries = proposed to the previous repo: still "proposed" unless --reseed)
_proposed() {
  [ -f "$LEDGER" ] || return 1
  python3 -I -c "
import json,sys
d=json.load(open(sys.argv[1])); e=d.get(sys.argv[2])
if e is None: sys.exit(1)
legacy = not isinstance(e, dict) or e.get('repo') != sys.argv[3]
sys.exit(1 if (legacy and sys.argv[4]=='1') else 0)" "$LEDGER" "$1" "$SLUG_REPO" "$RESEED" 2>/dev/null
}
# record a slug as proposed to this repo
_record() {
  python3 -I -c "
import json,os,sys
p=sys.argv[1]; slug=sys.argv[2]; ts=sys.argv[3]; repo=sys.argv[4]
d=json.load(open(p)) if os.path.exists(p) else {}
d[slug]={'at':ts,'repo':repo}
t=p+'.tmp.%d'%os.getpid()
json.dump(d, open(t,'w'), indent=2); os.replace(t,p)
" "$LEDGER" "$1" "$2" "$SLUG_REPO" 2>/dev/null || true
}
_now_iso() { python3 -I -c "import datetime;print(datetime.datetime.now().isoformat(timespec='seconds'))"; }
_fm() {  # extract a frontmatter field value from a file
  python3 -c "
import sys,re
t=open(sys.argv[1],encoding='utf-8',errors='ignore').read()
m=re.search(r'^'+sys.argv[2]+r':\s*(.+)$', t, re.M)
print((m.group(1).strip().strip('\"') if m else ''))
" "$1" "$2" 2>/dev/null
}

_info ""
_info "Ebda AI OS - dream-standard-drift (memory -> standard, propose-only)"
_info "  window: ${WINDOW_DAYS}d · max drafts: ${MAX_DRAFTS} · dry: ${DRY_RUN} · no-llm: ${NO_LLM}"
_info ""

# ── DETECT ──────────────────────────────────────────────────────────────────
candidates=""   # newline list of "slug<TAB>path"
n_cand=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  grep -qF "$SENTINEL" "$f" 2>/dev/null || continue        # cross-cutting only
  slug="$(_fm "$f" name)"; [ -n "$slug" ] || slug="$(basename "$f" .md)"
  # The OS's own state/roadmap docs are cross-cutting and carry the sentinel, but
  # they describe what IS, not a rule that SHOULD hold — they are not rubric
  # material, so a draft folding them into standard/ is always wrong. Skip them.
  case "$slug" in
    reference-whisky-ai-os-state|reference-whisky-ai-os-roadmap) continue ;;
  esac
  # already reflected in the standard? (slug referenced anywhere under standard/)
  if grep -rqF "$slug" "$FND/$STD_REL" 2>/dev/null; then continue; fi
  # already proposed in a prior run?
  if _proposed "$slug"; then continue; fi
  candidates="${candidates}${slug}	${f}"$'\n'
  n_cand=$((n_cand+1))
done < <(if [ "$RESEED" = 1 ]; then
           find "$GLOBAL_MEM" -maxdepth 1 \( -name 'feedback-*.md' -o -name 'reference-*.md' \) 2>/dev/null
         else
           find "$GLOBAL_MEM" -maxdepth 1 \( -name 'feedback-*.md' -o -name 'reference-*.md' \) -mtime "-${WINDOW_DAYS}" 2>/dev/null
         fi)

if [ "$n_cand" = "0" ]; then
  _info "  ✓ no un-reflected cross-cutting lessons in the last ${WINDOW_DAYS}d — standard is current."
  exit 0
fi

_info "  found $n_cand standard-gap candidate(s):"
printf '%s' "$candidates" | while IFS=$'\t' read -r s p; do [ -n "$s" ] && _info "    • $s"; done

# ── BASELINE: acknowledge the current backlog so the lens is FORWARD-LOOKING ──
# Historical lessons may be reflected in the standard's CONTENT without citing
# the slug (so they look like gaps). Seeding them as "acknowledged" makes the
# lens fire only on lessons that appear AFTER the baseline. A full historical
# audit is a separate, explicit run (clear the ledger + raise DRIFT_MAX_DRAFTS).
if [ "$BASELINE" = "1" ]; then
  printf '%s' "$candidates" | while IFS=$'\t' read -r s p; do
    [ -n "$s" ] && _record "$s" "$(_now_iso)"
  done
  _info ""
  _info "  ✓ baseline recorded $n_cand lesson(s) as acknowledged — lens is now forward-looking."
  exit 0
fi

if [ "$DRY_RUN" = "1" ]; then
  _info ""
  _info "  DRY_RUN: would draft up to ${MAX_DRAFTS} propose-only PR(s) (or issues if --no-llm / claude missing)."
  _plan=0
  printf '%s' "$candidates" | while IFS=$'\t' read -r s p; do
    [ -n "$s" ] || continue
    _plan=$((_plan+1)); [ "$_plan" -gt "$MAX_DRAFTS" ] && break
    _info "    plan: draft PR on $SLUG_REPO for '$s' (base $BASE_BRANCH, touching $STD_REL/)"
  done
  exit 0
fi

# ── PROPOSE (capped, propose-only) ──────────────────────────────────────────
drafted=0; opened_summary=""
have_claude=0; command -v claude >/dev/null 2>&1 && have_claude=1
[ "$NO_LLM" = "1" ] && have_claude=0

# open a fallback issue for a gap (signal-preserving)
_open_issue() {
  local slug="$1" path="$2" desc; desc="$(_fm "$path" description)"
  local url
  url=$(gh issue create --repo "$SLUG_REPO" \
    --title "standard-drift: reflect '$slug' in the standard" \
    --label "dream-standard" \
    --body "A cross-cutting memory lesson is not yet reflected in \`standard/\`.

**Lesson:** \`$slug\`
**Summary:** $desc
**Source:** \`$path\`

Fold this into the most relevant \`standard/<id>.md\` (criterion row + short prose) or a cross-cutting doc, then index it in \`standard/00-index.md\`. Detected by \`dream-standard-drift.sh\` (propose-only)." 2>/dev/null || echo "")
  [ -n "$url" ] && { _info "    issue: $url"; opened_summary="${opened_summary}issue $slug -> $url"$'\n'; }
  _record "$slug" "$(_now_iso)"
}

printf '%s' "$candidates" | while IFS=$'\t' read -r slug path; do
  [ -n "$slug" ] || continue
  [ "$drafted" -ge "$MAX_DRAFTS" ] && break

  if [ "$have_claude" = "0" ]; then
    _info "  • $slug — claude unavailable / --no-llm => opening issue"
    _open_issue "$slug" "$path"
    drafted=$((drafted+1)); continue
  fi

  _info "  • $slug — drafting propose-only PR…"
  branch="proposal/standard-${slug}"; branch="${branch:0:60}"
  mkdir -p "$(command -v wt_worktree_root >/dev/null 2>&1 && wt_worktree_root || echo "$OS_PROJECTS_DIR/_worktrees")" 2>/dev/null
  wt="$(command -v wt_worktree_root >/dev/null 2>&1 && wt_worktree_root || echo "$OS_PROJECTS_DIR/_worktrees")/$(basename "$FND")__$(printf '%s' "$branch" | tr '/' '-')"
  git -C "$FND" worktree add -b "$branch" "$wt" "origin/$BASE_BRANCH" >/dev/null 2>&1 || {
    _info "    worktree create failed — falling back to issue"; _open_issue "$slug" "$path"; drafted=$((drafted+1)); continue; }

  prompt="You are folding ONE established cross-cutting lesson into the Ebda AI OS standard. Be conservative and minimal.

LESSON FILE (read it): $path

TASK: reflect this lesson in the standard at $wt/$STD_REL/.
1. Read $wt/$STD_REL/00-index.md to see the 20 concern docs + the cross-cutting docs.
2. Pick the SINGLE most relevant existing standard/<id>.md and add a concise criterion row (and at most a short prose paragraph) capturing the lesson's RULE — gradeable, with a gap-detection hint, matching the file's existing table format. Only create a new cross-cutting doc if nothing fits, and if so add one line to 00-index.md.
3. Touch at most ${MAX_FILES} files. Keep the diff under ${MAX_LINES} changed lines. Do NOT restate the whole lesson — link the rule to the memory file by name.
4. Do NOT edit anything else. Do NOT run git. Do NOT commit.

Output nothing but the edits."

  ( cd "$wt" && "$CLAUDE_BIN" -p --model sonnet --allowedTools "Read,Edit,Grep" "$prompt" >/dev/null 2>&1 ) || true

  changed=$(git -C "$wt" status --porcelain | wc -l | tr -d ' ')
  files=$(git -C "$wt" status --porcelain | wc -l | tr -d ' ')
  lines=$(git -C "$wt" diff --stat | tail -1 | grep -oE '[0-9]+ insertion|[0-9]+ deletion' | grep -oE '[0-9]+' | paste -sd+ - | bc 2>/dev/null || echo 0)

  if [ "$changed" = "0" ]; then
    _info "    no edits produced — falling back to issue"
    git -C "$FND" worktree remove --force "$wt" 2>/dev/null; git -C "$FND" branch -D "$branch" 2>/dev/null
    _open_issue "$slug" "$path"; drafted=$((drafted+1)); continue
  fi
  if [ "$files" -gt "$MAX_FILES" ] || { [ -n "$lines" ] && [ "$lines" -gt "$MAX_LINES" ]; }; then
    _info "    draft too large (files=$files lines=${lines:-?}) — discarding, opening issue instead"
    git -C "$FND" worktree remove --force "$wt" 2>/dev/null; git -C "$FND" branch -D "$branch" 2>/dev/null
    _open_issue "$slug" "$path"; drafted=$((drafted+1)); continue
  fi

  desc="$(_fm "$path" description)"
  git -C "$wt" add -- "$STD_REL"
  git -C "$wt" commit -q -m "proposal(standard): reflect '$slug' in the standard

Auto-drafted (propose-only) by Ebda AI OS dream-standard-drift.sh from the
cross-cutting memory lesson $slug. Human review required — this is a DRAFT.

Co-Authored-By: Claude <noreply@anthropic.com>" || true
  git -C "$wt" push -u origin "$branch" >/dev/null 2>&1 || { _info "    push failed"; }
  url=$(gh pr create --repo "$SLUG_REPO" --head "$branch" --base "$BASE_BRANCH" --draft \
    --title "proposal(standard): reflect '$slug' in the standard" \
    --label "dream-standard" \
    --body "**Propose-only** draft from a cross-cutting memory lesson not yet in the standard.

**Lesson:** \`$slug\`
**Summary:** $desc
**Source:** \`$path\`

Auto-drafted by \`dream-standard-drift.sh\` (Ebda AI OS). This is a **draft** — review, refine, and merge by hand. It never auto-merges (standard content is reasoning-authored). If the draft is off, close it and the lesson stays flagged in the dedup ledger only if merged/closed-as-done." 2>/dev/null || echo "")
  if [ -n "$url" ]; then _info "    draft PR: $url"; opened_summary="${opened_summary}draft $slug -> $url"$'\n'; fi
  _record "$slug" "$(_now_iso)"
  drafted=$((drafted+1))
done

# Note: the while-loop runs in a subshell (pipe), so $drafted/$opened_summary do
# not survive it; the per-item lines above are the authoritative log.
_info ""
_info "  ✓ dream-standard-drift complete (propose-only; nothing merged)."

exit 0
