#!/usr/bin/env bash
# Where a session's handoff lives, and which handoff a NEW session resumes from.
#
# 2026-08-26: two Claude sessions were running in parallel, both started outside
# a git repo, so handoff_path() returned the same global ~/.claude/handoff.md
# for both. The second session's write silently destroyed the first's — an
# entire session's working state, gone, with no error and no trace.
#
# handoff.sh does NOT write handoff content; the model does, with Write/Edit.
# So the fix cannot be "detect and refuse to clobber" inside the writer — there
# is no writer to guard. It has to be that two sessions never resolve to the
# SAME PATH in the first place.
#
# Per-session files alone would break the whole point of a handoff (a new
# session must resume from the PREVIOUS one), so resume reads the most recently
# modified handoff belonging to some OTHER session.

# handoff_session_id  -> a stable id for this session, never empty.
#
# CLAUDE_CODE_SESSION_ID is set for hooks. Falling back to the PID keeps two
# concurrent shells apart even without it; "default" is the last resort, and is
# still correct for a single session — it only loses isolation, never data.
handoff_session_id() {
  local sid="${CLAUDE_CODE_SESSION_ID:-}"
  [ -n "$sid" ] || sid="${CLAUDE_SESSION_ID:-}"
  [ -n "$sid" ] || sid="pid-${PPID:-$$}"
  # Filesystem-safe: ids are UUIDs today, but never trust that for a path.
  # "." is NOT in the allow-list: keeping it let "a/../../b" become "a-..-..-b",
  # which still carries ".." into a filename. UUIDs contain no dots, so nothing
  # legitimate is lost. A result that sanitises away to nothing falls back.
  local safe
  safe=$(printf '%s' "$sid" | tr -c 'A-Za-z0-9_-' '-' | cut -c1-64)
  case "$safe" in
    ''|-*[!-]*) : ;;                       # non-empty and not all dashes
  esac
  printf '%s' "$safe" | grep -q '[A-Za-z0-9_]' || safe="session"
  printf '%s' "$safe"
}

# handoff_dir <repo_root>  -> directory holding this project's session handoffs
handoff_dir() {
  local root="${1-}"
  if [ -n "$root" ]; then printf '%s/.handoff' "$root"
  else printf '%s/.claude/handoff' "$HOME"; fi
}

# handoff_legacy_path <repo_root>  -> the pre-2026-08-26 single-file location.
# Still READ for resume so no existing handoff is stranded by this change.
handoff_legacy_path() {
  local root="${1-}"
  if [ -n "$root" ]; then printf '%s/handoff.md' "$root"
  else printf '%s/.claude/handoff.md' "$HOME"; fi
}

# handoff_resume_src <dir> <own_path> <legacy_path>
#   -> path of the handoff a NEW session should resume from, or "" if none.
#
# Most recently MODIFIED among the legacy file and every other session's file,
# excluding this session's own. Own is excluded so a session started twice does
# not "resume from itself" and echo a stale copy of its own template.
handoff_resume_src() {
  local dir="${1-}" own="${2-}" legacy="${3-}"
  local best="" best_mt=0 f mt
  for f in "$legacy" "$dir"/*.md; do
    [ -f "$f" ] || continue
    [ "$f" = "$own" ] && continue
    mt=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0)
    case "$mt" in ''|*[!0-9]*) mt=0 ;; esac
    # -ge, not -gt: on an mtime TIE (two handoffs written in the same second)
    # the LAST candidate wins, so the choice is deterministic instead of
    # depending on glob order. Ties only occur in tests; real sessions differ.
    if [ "$mt" -ge "$best_mt" ]; then best_mt="$mt"; best="$f"; fi
  done
  printf '%s' "$best"
}

# handoff_goal <file>  -> first non-comment line of the "## Goal" section, or ""
# when the section is empty (a never-filled template).
handoff_goal() {
  awk '/^## Goal/{g=1;next} /^## /{g=0} g && !/^<!--/ && NF {print; exit}' "${1-}" 2>/dev/null | cut -c1-140
}

# handoff_menu <dir> <own_path> <legacy_path> [max]
#   -> up to <max> (default 8) lines "path<TAB>YYYY-MM-DD HH:MM<TAB>goal",
#      newest first, excluding this session's own file and blank templates.
#
# 2026-10-08 (Ahmad): resume used to INJECT the newest other session's handoff
# whole — 71 KB of an unrelated Ebda session landed in an OS-audit session.
# Sessions in one dir do different things, so newest != relevant. A new session
# now gets this menu only, and asks which (if any) to read.
handoff_menu() {
  local dir="${1-}" own="${2-}" legacy="${3-}" max="${4:-8}" f mt goal
  case "$max" in ''|*[!0-9]*) max=8 ;; esac
  for f in "$legacy" "$dir"/*.md; do
    [ -f "$f" ] || continue
    [ "$f" = "$own" ] && continue
    goal="$(handoff_goal "$f")"
    [ -n "$goal" ] || continue
    # GNU first: on Linux `stat -f` is filesystem status and does NOT fail, so a
    # BSD-first chain prints garbage there (caught by CI on ubuntu, 2026-10-08).
    mt=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0)
    case "$mt" in ''|*[!0-9]*) mt=0 ;; esac
    printf '%s\t%s\t%s\n' "$mt" "$f" "$goal"
  done | sort -rn | head -n "$max" | while IFS="$(printf '\t')" read -r mt f goal; do
    printf '%s\t%s\t%s\n' "$f" "$(date -r "$mt" '+%Y-%m-%d %H:%M' 2>/dev/null || date -d "@$mt" '+%Y-%m-%d %H:%M' 2>/dev/null)" "$goal"
  done
}

# handoff_prune <dir> [days]  — drop other sessions' handoffs older than N days
# so the directory cannot grow without bound. Never touches the legacy file and
# never touches a file newer than the cutoff.
handoff_prune() {
  local dir="${1-}" days="${2:-14}"
  [ -d "$dir" ] || return 0
  case "$days" in ''|*[!0-9]*) days=14 ;; esac
  find "$dir" -maxdepth 1 -name '*.md' -type f -mtime "+$days" -delete 2>/dev/null || true
}
