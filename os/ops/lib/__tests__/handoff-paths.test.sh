#!/usr/bin/env bash
# Test handoff path scoping: two sessions must never share a file, and a new
# session must still resume from the previous one.
set -uo pipefail
. "$(dirname "$0")/../handoff-paths.sh"
_pass=0; _fail=0
eq() { if [ "$2" = "$3" ]; then echo "PASS: $1"; _pass=$((_pass+1)); else echo "FAIL: $1 — got '$2' want '$3'"; _fail=$((_fail+1)); fi; }
ne() { if [ "$2" != "$3" ]; then echo "PASS: $1"; _pass=$((_pass+1)); else echo "FAIL: $1 — both were '$2'"; _fail=$((_fail+1)); fi; }

TMP=$(mktemp -d /tmp/handoff-XXXXXX); trap 'rm -rf "$TMP"' EXIT

# ── session id ───────────────────────────────────────────────────────────────
eq "uses CLAUDE_CODE_SESSION_ID" \
   "$(CLAUDE_CODE_SESSION_ID=abc123 handoff_session_id)" "abc123"
# THE BUG: two sessions must not resolve to the same id.
ne "two sessions differ" \
   "$(CLAUDE_CODE_SESSION_ID=sess_A handoff_session_id)" \
   "$(CLAUDE_CODE_SESSION_ID=sess_B handoff_session_id)"
eq "path-unsafe chars are neutralised" \
   "$(CLAUDE_CODE_SESSION_ID='a/../../b c' handoff_session_id)" "a-------b-c"
# No dots survive, so ".." can never appear inside a handoff filename.
eq "dots are stripped"   "$(CLAUDE_CODE_SESSION_ID='..' handoff_session_id)"       "session"
eq "slashes cannot escape" "$(CLAUDE_CODE_SESSION_ID='../../etc/passwd' handoff_session_id)" "------etc-passwd"
eq "all-punctuation falls back" "$(CLAUDE_CODE_SESSION_ID='///' handoff_session_id)" "session"
# Never empty — an empty id would collapse every session onto one path again,
# reintroducing the exact bug.
v=$(env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID bash -c '. '"$(dirname "$0")"'/../handoff-paths.sh; handoff_session_id')
if [ -n "$v" ]; then echo "PASS: never empty without env"; _pass=$((_pass+1)); else echo "FAIL: empty id"; _fail=$((_fail+1)); fi
if [ ${#v} -le 64 ]; then echo "PASS: id is bounded"; _pass=$((_pass+1)); else echo "FAIL: id too long"; _fail=$((_fail+1)); fi

# ── directories ──────────────────────────────────────────────────────────────
eq "repo dir"            "$(handoff_dir /r/proj)"           "/r/proj/.handoff"
eq "global dir"          "$(HOME=/h handoff_dir)"           "/h/.claude/handoff"
eq "repo legacy path"    "$(handoff_legacy_path /r/proj)"   "/r/proj/handoff.md"
eq "global legacy path"  "$(HOME=/h handoff_legacy_path)"   "/h/.claude/handoff.md"

# ── resume selection ─────────────────────────────────────────────────────────
D="$TMP/.handoff"; mkdir -p "$D"; L="$TMP/handoff.md"
mk() { printf '%s\n' "$2" > "$1"; touch -t "$3" "$1"; }

# Only a legacy file exists -> resume from it (nothing is stranded by the move).
mk "$L" "legacy" 202608260100
eq "legacy alone is the resume source" \
   "$(handoff_resume_src "$D" "$D/mine.md" "$L")" "$L"

# Another session's file, newer than legacy -> that wins.
mk "$D/other.md" "other" 202608260200
eq "newest other session wins over legacy" \
   "$(handoff_resume_src "$D" "$D/mine.md" "$L")" "$D/other.md"

# A session must NOT resume from its own file, however new it is — otherwise a
# restarted session echoes back its own stale template as "previous state".
mk "$D/mine.md" "mine" 202608260300
eq "own file is excluded" \
   "$(handoff_resume_src "$D" "$D/mine.md" "$L")" "$D/other.md"

# Most recent among several others.
mk "$D/third.md" "third" 202608260400
eq "most recent of many others" \
   "$(handoff_resume_src "$D" "$D/mine.md" "$L")" "$D/third.md"

# Nothing to resume from.
E="$TMP/empty"; mkdir -p "$E"
eq "no candidates -> empty" \
   "$(handoff_resume_src "$E" "$E/mine.md" "$E/nope.md")" ""

# ── the regression: two parallel sessions ────────────────────────────────────
# Both outside a repo. Before the fix both resolved to ~/.claude/handoff.md.
pA="$(HOME=$TMP handoff_dir)/$(CLAUDE_CODE_SESSION_ID=sess_A handoff_session_id).md"
pB="$(HOME=$TMP handoff_dir)/$(CLAUDE_CODE_SESSION_ID=sess_B handoff_session_id).md"
ne "parallel non-repo sessions get DIFFERENT files" "$pA" "$pB"
# ...and in the same repo, too.
rA="$(handoff_dir /r)/$(CLAUDE_CODE_SESSION_ID=sess_A handoff_session_id).md"
rB="$(handoff_dir /r)/$(CLAUDE_CODE_SESSION_ID=sess_B handoff_session_id).md"
ne "parallel same-repo sessions get DIFFERENT files" "$rA" "$rB"

# ── prune ────────────────────────────────────────────────────────────────────
P="$TMP/prune"; mkdir -p "$P"
mk "$P/old.md" "old" 202601010000
printf 'new\n' > "$P/new.md"
handoff_prune "$P" 14
[ ! -f "$P/old.md" ] && { echo "PASS: prune removes stale handoffs"; _pass=$((_pass+1)); } || { echo "FAIL: stale kept"; _fail=$((_fail+1)); }
[ -f "$P/new.md" ]  && { echo "PASS: prune keeps recent handoffs"; _pass=$((_pass+1)); } || { echo "FAIL: recent deleted"; _fail=$((_fail+1)); }
handoff_prune "$TMP/does-not-exist" 14 && { echo "PASS: prune on missing dir is a no-op"; _pass=$((_pass+1)); } || { echo "FAIL: prune errored"; _fail=$((_fail+1)); }
handoff_prune "$P" "garbage"; [ -f "$P/new.md" ] && { echo "PASS: garbage days falls back safely"; _pass=$((_pass+1)); } || { echo "FAIL: garbage days deleted a fresh file"; _fail=$((_fail+1)); }

# ── menu (2026-10-08: offer, never inject) ───────────────────────────────────
M="$TMP/menu"; mkdir -p "$M"
filled() { printf '# Handoff — x\n\n## Goal\n<!-- c -->\n%s\n\n## Done\n' "$2" > "$1"; touch -t "$3" "$1"; }
filled "$M/a.md" "Ebda pricing" 202610070100
filled "$M/b.md" "OS audit" 202610080100
printf '# Handoff\n\n## Goal\n<!-- what this thread is ultimately trying to achieve -->\n\n## Done\n' > "$M/blank.md"
filled "$M/mine.md" "my own" 202610090100
out="$(handoff_menu "$M" "$M/mine.md" "$M/none.md" 8)"
eq "menu lists filled handoffs only" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "2"
eq "menu newest first" "$(printf '%s\n' "$out" | head -1 | cut -f3)" "OS audit"
eq "menu excludes own file" "$(printf '%s\n' "$out" | grep -c mine.md)" "0"
eq "menu excludes blank template" "$(printf '%s\n' "$out" | grep -c blank.md)" "0"
eq "menu respects max" "$(handoff_menu "$M" "$M/mine.md" "" 1 | wc -l | tr -d ' ')" "1"
eq "goal of blank template is empty" "$(handoff_goal "$M/blank.md")" ""

echo; echo "$_pass passed, $_fail failed"; [ "$_fail" -eq 0 ]
