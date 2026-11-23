#!/usr/bin/env bash
# Ebda AI OS - sched-fail-watch: a failed SCHEDULED job opens a fixer, the same way a failed PR check does.
# Runs every 10 min (launchd). Pure bash + gh + launchctl: it spends NO model tokens, and does nothing when nothing failed.
#
# Fixer path = the review-finding queue (lib/job-failure.sh jf_file_issue -> one issue per job per UTC day on the OS repo -> the
# loop / fixer picks it up, worktree -> fix -> PR -> merge gate). One Telegram line (notify.sh, Keychain creds) per NEW issue.
#
# Covered:
#   (a) Mac launchd jobs ${OS_LAUNCHD_PREFIX}.*   `last exit code` via launchctl. launchd keeps the code until the next run, so a
#       failure counts only when its signature (exit code + log mtime) CHANGED: 2 distinct failing runs in a row (SFW_LAUNCHD_MIN)
#       open the fixer, a flaky single exit does not. A later exit 0 clears the streak and today's dedupe stamp.
#   (b) GitHub scheduled workflows (event=schedule) on the OS org's repos: the newest finished scheduled run per workflow. Red
#       (failure/timed_out/startup_failure) and younger than SFW_MAX_AGE_H opens a fixer; deduped per workflow + day AND per run id
#       (a red run that stays the latest is one issue, not one per day). A green run clears it. cancelled/skipped change nothing.
# NOT covered: (c) Cloudflare cron triggers. A cron-trigger failure is only readable with a Workers Observability API token plus a
#       per-worker query (not a cheap poll); cf-workers-watch covers deploys + live health. Document-only until a token is provisioned.
# Env (test seams): SFW_STATE, SFW_NOTIFY, SFW_LAUNCHD_DIR, SFW_REPOS ("owner/repo ..."), SFW_MAX_PER_TICK, SFW_MAX_AGE_H, SFW_NOW,
#   SFW_GH (gh binary), JF_FAILURE_GH, JF_FAILURE_STATE. Exit 0 always except usage (a watcher must not look like a failing job).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/os-config.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-config.sh" 2>/dev/null || true
command -v os_config_load >/dev/null 2>&1 && os_config_load
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/args.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/args.sh" || exit 2
. "$HERE/lib/single-instance.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/single-instance.sh" || exit 2
. "$HERE/lib/job-failure.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/job-failure.sh" || exit 2
args_help "${BASH_SOURCE[0]}" "$@"
single_instance sched-fail-watch
. "$HERE/lib/os-state.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-state.sh" 2>/dev/null || true
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

ST="${SFW_STATE:-${WHISKY_OS_STATE:-$HOME/.whisky-os-state}/sched-fail}"; mkdir -p "$ST/launchd" "$ST/wf" 2>/dev/null
NOTIFY="${SFW_NOTIFY:-$HERE/notify.sh}"
GH="${SFW_GH:-gh}"
LDIR="${SFW_LAUNCHD_DIR:-$HOME/Library/LaunchAgents}"
MIN="${SFW_LAUNCHD_MIN:-2}"; MAXN="${SFW_MAX_PER_TICK:-3}"; MAXAGE_H="${SFW_MAX_AGE_H:-72}"
NOW="${SFW_NOW:-$(date -u +%s)}"
PREFIX="${OS_LAUNCHD_PREFIX:?OS_LAUNCHD_PREFIX unset (os_config_load)}"
checked=0; CNT="$ST/.filed.$$"; echo 0 > "$CNT"   # per-tick issue counter (a file: the workflow loop runs in a pipe subshell)

alert() { "$NOTIFY" "$1" "$2" >/dev/null 2>&1 || true; }
cap_ok() { [ "$(cat "$CNT" 2>/dev/null || echo 0)" -lt "$MAXN" ]; }
bump() { echo $(( $(cat "$CNT" 2>/dev/null || echo 0) + 1 )) > "$CNT"; }
mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }

# ---------------- (a) launchd ----------------
for plist in "$LDIR"/${PREFIX}.*.plist; do
  [ -f "$plist" ] || continue
  label="$(basename "$plist" .plist)"; checked=$((checked+1))
  rc="$(jf_last_exit "$label")"
  sf="$ST/launchd/$label.streak"
  if [ -z "$rc" ] || [ "$rc" = "0" ]; then
    # recovery (or never exited): forget the streak and today's stamp so the next failure files afresh
    if [ -e "$sf" ]; then rm -f "$sf" "$ST/launchd/$label.reported"; jf_clear "$label"; echo "recovered $label"; fi
    continue
  fi
  logp=""
  for k in StandardErrorPath StandardOutPath; do
    logp="$(/usr/libexec/PlistBuddy -c "Print :$k" "$plist" 2>/dev/null || python3 -c "import plistlib,sys;print(plistlib.load(open(sys.argv[1],'rb')).get(sys.argv[2],''))" "$plist" "$k" 2>/dev/null)"
    logp="${logp//__HOME__/$HOME}"; [ -n "$logp" ] && [ -e "$logp" ] && break; logp=""
  done
  if [ -n "$logp" ]; then sig="$rc:$(mtime "$logp")"; else sig="$rc:nolog"; fi
  seen="$(sed -n 1p "$sf" 2>/dev/null)"; sig_old="${seen#*|}"; n="${seen%%|*}"
  case "$n" in ''|*[!0-9]*) n=0; sig_old="" ;; esac
  if [ "$sig" != "$sig_old" ]; then n=$((n+1)); printf '%s|%s\n' "$n" "$sig" > "$sf"; fi   # unchanged signature = same run, no new evidence
  # no log to tell runs apart: cannot prove a 2nd run, so report on first sight rather than never
  [ -n "$logp" ] || n="$MIN"
  [ "$n" -ge "$MIN" ] || { echo "$label: failure $n/$MIN (waiting for a 2nd run)"; continue; }
  [ "$(sed -n 1p "$ST/launchd/$label.reported" 2>/dev/null)" = "$sig" ] && continue   # this exact failing run already has its fixer
  cap_ok || { echo "$label: capped this tick"; continue; }
  report="$(job_failure_report "$label" "$rc" "$plist")"
  case "$report" in
    "FILED "*) bump; printf '%s\n' "$sig" > "$ST/launchd/$label.reported"; alert "scheduled job failed: $label" "exit $rc, $n consecutive runs. Fixer issue: ${report#FILED }"; echo "filed $label" ;;
    DEDUPED) printf '%s\n' "$sig" > "$ST/launchd/$label.reported" ;;   # today's issue already covers this run
    *) echo "$label: $report" ;;
  esac
done

# ---------------- (b) GitHub scheduled workflows ----------------
repos="${SFW_REPOS:-}"
if [ -z "$repos" ]; then
  cache="$ST/repos.txt"
  # the repo list changes rarely: refresh at most every 6 h (skip-if-unchanged)
  if [ ! -s "$cache" ] || [ $((NOW - $(mtime "$cache"))) -gt 21600 ]; then
    "$GH" repo list "${OS_ORG:-}" --no-archived -L 100 --json nameWithOwner --jq '.[].nameWithOwner' > "$cache.tmp" 2>/dev/null && [ -s "$cache.tmp" ] && mv "$cache.tmp" "$cache"
    rm -f "$cache.tmp"
  fi
  repos="$(cat "$cache" 2>/dev/null | tr '\n' ' ')"
fi
for repo in $repos; do
  runs="$("$GH" run list -R "$repo" --event schedule --limit 30 --json databaseId,workflowName,conclusion,status,createdAt,url 2>/dev/null)" || continue
  [ -n "$runs" ] || continue
  # newest FINISHED, decisive (not cancelled/skipped) run per workflow, as TSV: name, run id, conclusion, createdAt, url
  rows="$(printf '%s' "$runs" | jq -r '
      [ .[] | select(.status=="completed" and (.conclusion=="success" or .conclusion=="failure" or .conclusion=="timed_out" or .conclusion=="startup_failure")) ]
      | group_by(.workflowName) | map(sort_by(.createdAt) | last) | .[]
      | [.workflowName, (.databaseId|tostring), .conclusion, .createdAt, .url] | @tsv' 2>/dev/null)" || continue
  printf '%s\n' "$rows" | while IFS="$(printf '\t')" read -r wname rid concl created url; do
    [ -n "$wname" ] || continue
    slug="$(printf '%s' "${repo}-${wname}" | tr -c 'A-Za-z0-9._-' '_')"; key="wf-$slug"; rf="$ST/wf/$slug.run"
    if [ "$concl" = "success" ]; then
      if [ -e "$rf" ]; then rm -f "$rf"; jf_clear "$key"; echo "recovered $repo/$wname"; fi
      continue
    fi
    [ "$(sed -n 1p "$rf" 2>/dev/null)" = "$rid" ] && continue          # this exact red run already has its fixer
    ts="$(TZ=UTC /bin/date -j -f '%Y-%m-%dT%H:%M:%SZ' "$created" +%s 2>/dev/null || date -d "$created" +%s 2>/dev/null || echo 0)"
    [ $((NOW - ts)) -le $((MAXAGE_H * 3600)) ] || continue             # history, not news
    day="$(date -u +%Y-%m-%d)"
    body="Scheduled workflow \`$wname\` in \`$repo\` failed (**$concl**, run $rid, $created): $url

Opened automatically by sched-fail-watch (\`ops/sched-fail-watch.sh\`), one issue per workflow per day and per failing run. Read the failed logs (\`gh run view $rid -R $repo --log-failed\`), fix the workflow or what it calls, and re-run it."
    cap_ok || continue
    out="$(jf_file_issue "$key" "scheduled-workflow: $repo $wname failed ($day)" "$body")"
    case "$out" in
      "FILED "*) bump; printf '%s\n' "$rid" > "$rf"; alert "scheduled workflow failed: $repo / $wname" "$concl. Fixer issue: ${out#FILED }"; echo "filed $repo/$wname" ;;
      DEDUPED) printf '%s\n' "$rid" > "$rf" ;;                          # today's issue already covers it
      *) echo "$repo/$wname: $out" ;;
    esac
  done
done
filed="$(cat "$CNT")"; rm -f "$CNT"
command -v write_status >/dev/null 2>&1 && write_status sched-fail-watch true "checked $checked launchd jobs, filed $filed" '{}'
exit 0
