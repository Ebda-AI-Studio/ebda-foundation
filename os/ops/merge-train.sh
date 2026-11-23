#!/usr/bin/env bash
# Ebda AI OS - merge-train.sh (register OS-M1): token-free ordering of the PR queue so CI only runs for the PR that merges next.
#
#   merge-train.sh --repo OWNER/NAME add <pr> [wave]     queue a PR (lower wave merges first)
#   merge-train.sh --repo OWNER/NAME after <pr> <dep>    <pr> waits for <dep> to merge
#   merge-train.sh --repo OWNER/NAME prio <pr> <n>       higher n first within a wave
#   merge-train.sh --repo OWNER/NAME remove <pr>
#   merge-train.sh --repo OWNER/NAME show                the queue in train order
#   merge-train.sh --repo OWNER/NAME run [--dir CHECKOUT] [--dry-run] [--merge [--gate PATH]]
#
# State: $OS_STATE_DIR/merge-train/<repo-name>.json (an unreadable file is refused, never treated as empty).
# `run`, one pass, bounded gh calls, per queued PR in train order:
#   1. closed/merged PRs leave the queue (merged ones are remembered so `after` dependencies resolve).
#   2. CONFLICTING (GitHub `mergeable`) -> labelled `rebase-needed`, announced once via notify.sh, never the head, spends no CI.
#      UNKNOWN waits one pass. Draft PRs wait.
#   3. HEAD = the first PR that is not blocked by an unmerged dependency and not conflicting. Every OTHER mergeable PR has its
#      queued/in-progress runs on its head sha cancelled (frees hosted concurrency: Free plan ~20 jobs); each cancel is recorded in
#      <name>.cancelled as train-cancelled, so a cancel is never read as a failure.
#   4. The head's run that the train itself cancelled earlier is re-run once (gh run rerun), never all runs.
#   5. MIGRATION REGISTRY: migration numbers (migrations/<n>_*) in queued PR diffs must be unique among queued PRs and absent from
#      origin/main (needs --dir for the main side); a collision refuses the whole pass (exit 1) and merges nothing.
#   6. With --merge the head goes through the merge gate (head sha pinned) - the train never calls `gh pr merge` itself.
# Output: lines `HEAD <pr> <sha>`, `REBASE-NEEDED <pr>`, `CANCELLED <pr> run <id>`, `RERUN <pr> run <id>`, `WAIT <pr> <why>`, `COLLISION ...`.
# Exit: 0 pass ok, 1 migration collision, 2 usage, 3 unreadable state.
# Test seams: `gh` from PATH, OS_STATE_DIR, MERGE_TRAIN_NOTIFY (default ops/notify.sh).
# shellcheck source=lib/os-config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/os-config.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-config.sh" 2>/dev/null || true
command -v os_config_load >/dev/null 2>&1 && os_config_load
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/args.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/args.sh" 2>/dev/null || true
. "$HERE/lib/os-state.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-state.sh" 2>/dev/null || true
command -v _ut >/dev/null 2>&1 || _ut() { shift; "$@"; }
command -v args_help >/dev/null 2>&1 && args_help "$0" "$@"
LIB="$HERE/lib"; [ -f "$LIB/merge_train.py" ] || LIB="$HOME/.claude/scripts/lib"
GH_TIMEOUT="${GH_TIMEOUT:-45}"
repo=""; dir=""; dry=0; do_merge=0; gate="${HOME}/.claude/scripts/merge-gate.sh"; cmd=""; cargs=()
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) repo="${2:?--repo needs OWNER/NAME}"; shift 2 ;;
    --dir) dir="${2:?}"; shift 2 ;;
    --dry-run) dry=1; shift ;;
    --merge) do_merge=1; shift ;;
    --gate) gate="${2:?}"; shift 2 ;;
    -*) echo "merge-train.sh: unknown argument '$1' (try --help)" >&2; exit 2 ;;
    *) if [ -z "$cmd" ]; then cmd="$1"; else cargs+=("$1"); fi; shift ;;
  esac
done
[ -n "$repo" ] && [ -n "$cmd" ] || { echo "merge-train.sh: need --repo OWNER/NAME and a command (try --help)" >&2; exit 2; }
case "$repo" in */*) ;; *) echo "merge-train.sh: --repo must be OWNER/NAME" >&2; exit 2 ;; esac
name="${repo##*/}"
SD="${OS_STATE_DIR:-$HOME/.whisky-os-state}/merge-train"; mkdir -p "$SD" || exit 2
STATE="$SD/$name.json"; CANCELLED="$SD/$name.cancelled"; NOTIFIED="$SD/$name.notified"
mt() { python3 -I "$LIB/merge_train.py" "$@"; }
ghx() { _ut "$GH_TIMEOUT" gh "$@"; }
isnum() { case "${1:-}" in ""|*[!0-9]*) return 1 ;; esac; }

case "$cmd" in
  add)    isnum "${cargs[0]:-}" || { echo "usage: add <pr> [wave]" >&2; exit 2; }; mt state "$STATE" add ${cargs[@]+"${cargs[@]}"}; exit $? ;;
  after)  isnum "${cargs[0]:-}" && isnum "${cargs[1]:-}" || { echo "usage: after <pr> <dep>" >&2; exit 2; }; mt state "$STATE" after "${cargs[0]}" "${cargs[1]}"; exit $? ;;
  prio)   isnum "${cargs[0]:-}" && isnum "${cargs[1]:-}" || { echo "usage: prio <pr> <n>" >&2; exit 2; }; mt state "$STATE" prio "${cargs[0]}" "${cargs[1]}"; exit $? ;;
  remove) isnum "${cargs[0]:-}" || { echo "usage: remove <pr>" >&2; exit 2; }; mt state "$STATE" remove "${cargs[0]}"; exit $? ;;
  show)   mt state "$STATE" show; exit $? ;;
  run) ;;
  *) echo "merge-train.sh: unknown command '$cmd' (try --help)" >&2; exit 2 ;;
esac

# ---- run ----
queue="$(mt state "$STATE" show)" || exit 3
[ -n "$queue" ] || { echo "empty queue"; exit 0; }
info() { ghx pr view "$1" --repo "$repo" --json state,mergeable,isDraft,headRefOid 2>/dev/null; }
field() { python3 -I -c 'import sys,json
try:
    v=json.load(sys.stdin).get(sys.argv[1])
except Exception:
    v=""
print("" if v is None else str(v).lower() if isinstance(v,bool) else v)' "$1"; }
notify_once() { # key title body
  grep -qxF "$1" "$NOTIFIED" 2>/dev/null && return 0
  echo "$1" >> "$NOTIFIED"
  [ "$dry" -eq 1 ] && return 0
  "${MERGE_TRAIN_NOTIFY:-$HERE/notify.sh}" "$2" "$3" >/dev/null 2>&1 || true
}
active_runs() { # sha -> "<id>" lines for queued + in_progress runs on that head sha
  local st
  for st in queued in_progress; do
    ghx api "repos/$repo/actions/runs?head_sha=$1&status=$st&per_page=100" 2>/dev/null | python3 -I -c 'import sys,json
try:
    for r in json.load(sys.stdin).get("workflow_runs", []): print(r["id"])
except Exception:
    pass'
  done
}
cancelled_runs() { # sha -> ids of the latest completed runs on that sha that ended `cancelled`
  ghx api "repos/$repo/actions/runs?head_sha=$1&status=cancelled&per_page=20" 2>/dev/null | python3 -I -c 'import sys,json
try:
    for r in json.load(sys.stdin).get("workflow_runs", []): print(r["id"])
except Exception:
    pass'
}

head=""; headsha=""; eligible=(); shas=()
while read -r pr _wave _prio blocked; do
  [ -n "$pr" ] || continue
  j="$(info "$pr")" || { echo "WAIT $pr unreadable"; continue; }
  st="$(printf '%s' "$j" | field state)"
  case "$st" in
    MERGED) mt state "$STATE" remove "$pr" merged; echo "MERGED $pr"; continue ;;
    CLOSED) mt state "$STATE" remove "$pr"; echo "CLOSED $pr"; continue ;;
    OPEN) ;;
    *) echo "WAIT $pr state-unknown"; continue ;;
  esac
  [ "$blocked" = "-" ] || { echo "WAIT $pr blocked-by $blocked"; continue; }
  [ "$(printf '%s' "$j" | field isDraft)" = true ] && { echo "WAIT $pr draft"; continue; }
  case "$(printf '%s' "$j" | field mergeable)" in
    CONFLICTING)
      echo "REBASE-NEEDED $pr"
      [ "$dry" -eq 1 ] || ghx pr edit "$pr" --repo "$repo" --add-label rebase-needed >/dev/null 2>&1 || true
      notify_once "rebase-$pr" "merge-train: PR #$pr needs a rebase" "$repo#$pr conflicts with main; no CI is spent on it until it is rebased."
      continue ;;
    MERGEABLE) ;;
    *) echo "WAIT $pr mergeable-unknown"; continue ;;
  esac
  sha="$(printf '%s' "$j" | field headRefOid)"
  [ -n "$sha" ] || { echo "WAIT $pr no-head-sha"; continue; }
  if [ -z "$head" ]; then head="$pr"; headsha="$sha"; fi
  eligible+=("$pr"); shas+=("$sha")
done <<EOF_Q
$queue
EOF_Q

# migration registry over every eligible queued PR (refuse the whole pass on a collision)
if [ "${#eligible[@]}" -gt 0 ]; then
  mainfile="$(mktemp)"; trap 'rm -f "$mainfile"' EXIT
  if [ -n "$dir" ]; then
    git -C "$dir" ls-tree -r --name-only origin/main 2>/dev/null | sed -n 's#.*migrations\{0,1\}/0*\([0-9][0-9]*\)[_.-].*#\1#p' > "$mainfile"
  fi
  files=""
  for pr in ${eligible[@]+"${eligible[@]}"}; do
    f="$(ghx api "repos/$repo/pulls/$pr/files?per_page=100" --jq '.[].filename' 2>/dev/null)" || f=""
    while IFS= read -r p; do [ -n "$p" ] && files="$files$pr	$p
"; done <<EOF_F
$f
EOF_F
  done
  if ! out="$(printf '%s' "$files" | mt migcheck "$mainfile")"; then
    printf '%s\n' "$out"; echo "REFUSED migration collision - nothing merged this pass"; exit 1
  fi
fi

[ -n "$head" ] || { echo "no mergeable head"; exit 0; }
echo "HEAD $head $headsha"
i=0
for pr in ${eligible[@]+"${eligible[@]}"}; do
  sha="${shas[$i]}"; i=$((i+1))
  [ "$pr" = "$head" ] && continue
  while read -r rid; do
    [ -n "$rid" ] || continue
    echo "CANCELLED $pr run $rid"
    [ "$dry" -eq 1 ] && continue
    if ghx run cancel "$rid" --repo "$repo" >/dev/null 2>&1; then echo "train-cancelled $rid" >> "$CANCELLED"; fi
  done <<EOF_R
$(active_runs "$sha")
EOF_R
done
# the head: re-run, once, a run the train itself cancelled
while read -r rid; do
  [ -n "$rid" ] || continue
  grep -qxF "train-cancelled $rid" "$CANCELLED" 2>/dev/null || continue
  grep -qxF "rerun $rid" "$CANCELLED" 2>/dev/null && continue
  echo "RERUN $head run $rid"
  [ "$dry" -eq 1 ] && continue
  ghx run rerun "$rid" --repo "$repo" >/dev/null 2>&1 && echo "rerun $rid" >> "$CANCELLED"
done <<EOF_C
$(cancelled_runs "$headsha")
EOF_C

if [ "$do_merge" -eq 1 ] && [ "$dry" -eq 0 ]; then
  [ -x "$gate" ] || { echo "merge-train.sh: merge gate not executable: $gate" >&2; exit 2; }
  "$gate" "$head" "$headsha" --repo "$repo" --interval 30 --max-wait-min 20
fi
exit 0
