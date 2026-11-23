# shellcheck shell=bash
# lib/job-failure.sh - a scheduled job (launchd) that exited non-zero opens a review-finding issue with the log tail (G14).
#
# WHY (2026-11-15). os-selftest judged each launchd job by log FRESHNESS only. A job that ran on time and exited non-zero
# (a backup, a drain, a watcher) looked fresh, so its failure reached nobody until a human read a log. The OS's act-don't-ping
# rule needs a tracked, deduped work item for it: one issue per job per day, carrying the exit code and the log tail, so the
# fixer path (review-finding queue -> worktree -> fix -> PR) picks it up. No new daemon: os-selftest already walks every job.
#
# jf_last_exit <label>           -> the job's `last exit code` (integer) or empty (never exited / launchctl missing / unknown)
# jf_log_tail <plist> [n]        -> last n lines (default 40) of StandardErrorPath, else StandardOutPath; secrets masked
# job_failure_report <label> <rc> <plist>  -> prints FILED <url> | DEDUPED | SKIPPED <why>; files at most one issue per job per UTC day
# Test seams: JF_LAUNCHCTL_PRINT (file with launchctl-print text), JF_FAILURE_GH (gh binary), JF_FAILURE_STATE (stamp dir).

jf_last_exit() {
  local label="${1-}" out
  if [ -n "${JF_LAUNCHCTL_PRINT-}" ]; then out="$(cat "$JF_LAUNCHCTL_PRINT" 2>/dev/null)"
  else
    command -v launchctl >/dev/null 2>&1 || return 0
    out="$(launchctl print "gui/$(id -u)/${label}" 2>/dev/null)" || return 0
  fi
  printf '%s\n' "$out" | sed -n 's/^[[:space:]]*last exit code = \([0-9][0-9]*\)[[:space:]]*$/\1/p' | head -1
}

jf_log_tail() {
  local plist="${1-}" n="${2:-40}" p
  [ -f "$plist" ] || return 0
  for k in StandardErrorPath StandardOutPath; do
    p="$(/usr/libexec/PlistBuddy -c "Print :$k" "$plist" 2>/dev/null || python3 -c "import plistlib,sys;print(plistlib.load(open(sys.argv[1],'rb')).get(sys.argv[2],''))" "$plist" "$k" 2>/dev/null)"
    p="${p//__HOME__/$HOME}"
    [ -n "$p" ] && [ -s "$p" ] && {
      tail -n "$n" "$p" 2>/dev/null | sed -E 's/(ghp_|gho_|github_pat_|sk-|xox[bp]-|AKIA)[A-Za-z0-9_-]{8,}/\1***MASKED***/g; s/((token|secret|password|api[_-]?key|authorization)[=: ]+)[^[:space:]]+/\1***MASKED***/Ig'
      return 0
    }
  done
}

# jf_file_issue <stamp-key> <title> <body>  -> FILED <url> | DEDUPED | SKIPPED <why>. One review-finding issue per key per UTC day
# (the shared fixer queue: G14 launchd jobs and sched-fail-watch scheduled workflows both file through here, so one failure is one issue).
# The stamp is written only after the issue exists: a failed filing is retried on the next run, never silently dropped.
jf_file_issue() {
  local key="${1-}" title="${2-}" body="${3-}" sd day stamp gh_bin slug url
  [ -n "$key" ] && [ -n "$title" ] || { echo "SKIPPED usage"; return 0; }
  sd="${JF_FAILURE_STATE:-${WHISKY_OS_STATE:-$HOME/.whisky-os-state}/job-failure}"; mkdir -p "$sd" 2>/dev/null
  day="$(date -u +%Y-%m-%d)"; stamp="$sd/${key}.${day}"
  [ -e "$stamp" ] && { echo "DEDUPED"; return 0; }
  gh_bin="${JF_FAILURE_GH:-gh}"
  { command -v "$gh_bin" >/dev/null 2>&1 || [ -x "$gh_bin" ]; } || { echo "SKIPPED no-gh"; return 0; }
  [ -n "${OS_REPO_SLUG:-}" ] || ! command -v os_config_load >/dev/null 2>&1 || os_config_load
  slug="${OS_REPO_SLUG:-}"; [ -n "$slug" ] || { echo "SKIPPED no-repo-slug"; return 0; }
  "$gh_bin" label create review-finding -R "$slug" --color D93F0B --description "OS finding for the fixer queue" >/dev/null 2>&1 || true
  if url="$("$gh_bin" issue create -R "$slug" --label review-finding --title "$title" --body "$body" 2>/dev/null)" && [ -n "$url" ]; then
    : > "$stamp"
    echo "FILED $url"
  else echo "SKIPPED gh-failed"; fi
}

# jf_clear <stamp-key>  -> recovery: forget today's (and older) stamps so the NEXT failure of this key files a fresh issue.
jf_clear() {
  local key="${1-}" sd; [ -n "$key" ] || return 0
  sd="${JF_FAILURE_STATE:-${WHISKY_OS_STATE:-$HOME/.whisky-os-state}/job-failure}"
  rm -f "$sd/${key}."[0-9]*-[0-9]*-[0-9]* 2>/dev/null; return 0
}

job_failure_report() {
  local label="${1-}" rc="${2-}" plist="${3-}" day tail body
  [ -n "$label" ] && [ -n "$rc" ] || { echo "SKIPPED usage"; return 0; }
  [ "$rc" = "0" ] && { echo "SKIPPED exit-0"; return 0; }
  day="$(date -u +%Y-%m-%d)"
  tail="$(jf_log_tail "$plist" 40)"; [ -n "$tail" ] || tail="(no log output found)"
  body="Scheduled job \`$label\` exited non-zero (last exit code **$rc**) on $day (UTC).

Opened automatically by sched-fail-watch (\`lib/job-failure.sh\`, G14), one issue per job per day. Fix the job, or if the exit is expected, make it exit 0.

Log tail (secrets masked):
\`\`\`
$tail
\`\`\`"
  jf_file_issue "$label" "job-failure: $label exited $rc ($day)" "$body"
}
