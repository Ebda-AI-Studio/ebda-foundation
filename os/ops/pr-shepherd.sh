#!/usr/bin/env bash
# Whisky AI OS — pr-shepherd.sh (launchd ${OS_LAUNCHD_PREFIX}.pr-shepherd, every 20 min)
#
# The CI/CD closed loop for OPEN PRs. Born 2026-07-12 after one session spent
# hours doing these six moves by hand — each is a real incident from that day:
#
#   HEAL   1. rerun jobs the infra killed (OOM "exit 137", disk-full, runner
#             lost) — max 2 reruns per (pr, head-sha), ledger-tracked
#          2. rerun a head whose latest required run was CANCELLED and never
#             re-ran (CRM#32 sat blocked for days on a cancelled run)
#          3. update-branch when a green PR is merely BEHIND (strict up-to-date
#             protection races busy main — store#621 needed 3 manual updates)
#          4. resolve unresolved AI-review threads ONLY when the Claude-review
#             check on the CURRENT head is SUCCESS (advisory re-posts blocked
#             CRM#32 via required conversation resolution — 12 threads, 1 real
#             finding which was FIXED first; the reviewer passing = advisory)
#   SHIP   5. squash-merge when: not draft, all checks green, no unresolved
#             threads, branch not auto-fix/* or dream-fix/* (those fleets own
#             their own merge policy / DREAM_AUTOMERGE gate)
#   ALERT  6. content failures (real red) → ONE Telegram per (pr, head) with
#             the failing job names — never blind-rerun a content failure
#
# Pure gh API — zero LLM tokens. DRY_RUN=1 previews every action.
# shellcheck source=lib/os-config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/os-config.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-config.sh" 2>/dev/null || true
command -v os_config_load >/dev/null 2>&1 && os_config_load
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/os-state.sh" 2>/dev/null || true
# merge only on a REAL green — "nothing failing" is not "something passed"
. "$HERE/lib/pr-merge-gate.sh" 2>/dev/null || true

DRY="${DRY_RUN:-0}"
# The brain shepherds the orgs it watches (OS_ORGS in config/brain-watchers.json). This Mac job covers ONE other org, named
# per machine in ~/.ebda-os.local.env (OS_PR_SHEPHERD_ORG); unset, or the brain's own primary org, = skip, so two shepherds
# never act on the same PRs (ruling INSTALL-1).
ORG="${OS_PR_SHEPHERD_ORG:-}"
if [ -z "$ORG" ]; then echo "pr-shepherd: OS_PR_SHEPHERD_ORG not set - the brain shepherds $OS_ORG; skip"; exit 0; fi
if [ "$ORG" = "$OS_ORG" ]; then echo "pr-shepherd: $ORG is shepherded by the brain; refusing a second shepherd - skip"; exit 0; fi
LEDGER="$HOME/.whisky-os-state/pr-shepherd-ledger.json"
mkdir -p "$(dirname "$LEDGER")"; [ -s "$LEDGER" ] || echo '{}' > "$LEDGER"
INFRA_RE='exit code 137|Killed +npm|No space left on device|lost communication with the server|shutdown signal|The operation was canceled and the runner'
JQ=$(command -v jq 2>/dev/null || echo /usr/bin/jq)

led_get() { "$JQ" -r --arg k "$1" '.[$k] // 0' "$LEDGER" 2>/dev/null || echo 0; }
led_inc() {
  tmp=$(mktemp); "$JQ" --arg k "$1" '.[$k] = ((.[$k] // 0) + 1)' "$LEDGER" > "$tmp" 2>/dev/null && mv "$tmp" "$LEDGER"
}

acted=(); alerts=(); merged=()

# every non-archived org repo with open PRs (dynamic — no list to drift)
repos=$(_ut "$OS_UT_FAST" gh api "orgs/$ORG/repos?per_page=100" --jq '.[] | select(.archived==false and .open_issues_count>=0) | .name' 2>/dev/null)

for repo in $repos; do
  prs=$(_ut "$OS_UT_FAST" gh pr list -R "$ORG/$repo" --state open --json number,isDraft,headRefName,title \
        --jq '.[] | select(.isDraft==false) | "\(.number)\t\(.headRefName)\t\(.title)"' 2>/dev/null)
  [ -z "$prs" ] && continue
  while IFS=$'\t' read -r num branch title; do
    [ -z "$num" ] && continue
    case "$branch" in auto-fix/*|dream-fix/*) fleet=1 ;; *) fleet=0 ;; esac
    head=$(_ut "$OS_UT_FAST" gh pr view "$num" -R "$ORG/$repo" --json headRefOid --jq '.headRefOid[0:12]' 2>/dev/null)
    key="$repo#$num@$head"

    pending=$(_ut "$OS_UT_FAST" gh pr view "$num" -R "$ORG/$repo" --json statusCheckRollup --jq '[.statusCheckRollup[] | select((.conclusion // "") == "" and .status != "COMPLETED")] | length' 2>/dev/null || echo 99)
    failed_names=$(_ut "$OS_UT_FAST" gh pr view "$num" -R "$ORG/$repo" --json statusCheckRollup --jq '[.statusCheckRollup[] | select(.conclusion == "FAILURE")] | .[].name' 2>/dev/null)
    # The POSITIVE gate. `pending`/`failed_names` above are two NEGATIVE tests
    # and nothing asserts a check actually passed: a CANCELLED check is neither
    # pending (status IS COMPLETED) nor FAILURE, so it was invisible to both.
    # That is how client-repo#99 was squash-merged on a cancelled CI run
    # that had never once gone green. See lib/pr-merge-gate.sh.
    verdict=$(_ut "$OS_UT_FAST" gh pr view "$num" -R "$ORG/$repo" --json statusCheckRollup \
                --jq '.statusCheckRollup[] | "\((.conclusion // ""))|\((.status // ""))"' 2>/dev/null \
              | merge_verdict 2>/dev/null || echo "blocked")
    verdict="${verdict:-blocked}"   # unreadable rollup must never mean mergeable

    # ---- 1+2: heal infra failures / stuck-cancelled heads ----
    if [ -n "$failed_names" ]; then
      run_id=$(_ut "$OS_UT_FAST" gh run list -R "$ORG/$repo" --branch "$branch" --json databaseId,conclusion --jq '.[] | select(.conclusion=="failure" or .conclusion=="cancelled") | .databaseId' 2>/dev/null | head -1)
      infra=0
      if [ -n "$run_id" ]; then
        _ut "$OS_UT_FAST" gh run view -R "$ORG/$repo" "$run_id" --log-failed 2>/dev/null | tail -80 | grep -qiE "$INFRA_RE" && infra=1
      fi
      if [ "$infra" = "1" ]; then
        n=$(led_get "rerun:$key")
        if [ "${n:-0}" -lt 2 ]; then
          [ "$DRY" = "1" ] || _ut "$OS_UT_FAST" gh run rerun "$run_id" -R "$ORG/$repo" --failed >/dev/null 2>&1
          led_inc "rerun:$key"; acted+=("HEAL $repo#$num: infra-killed run $run_id re-run ($((n+1))/2)")
        else
          [ "$(led_get "alert:$key")" = "0" ] && { alerts+=("$repo#$num: infra failure persists after 2 reruns — runner needs attention"); led_inc "alert:$key"; }
        fi
      else
        # content failure — alert once per head, never rerun
        if [ "$(led_get "alert:$key")" = "0" ]; then
          alerts+=("$repo#$num ($title): RED — $(echo "$failed_names" | tr '\n' ',' | sed 's/,$//')")
          led_inc "alert:$key"
        fi
      fi
      continue
    fi

    # stuck-cancelled: nothing failed, nothing pending, but latest run never completed green
    if [ "$pending" = "0" ]; then
      # NEWEST RUN PER WORKFLOW, not --limit 1 across all of them. gcc#99 had
      # gitleaks(success) and CI(cancelled) created in the SAME second, so a
      # single --limit 1 could read "success" and skip the heal entirely.
      rid=$(_ut "$OS_UT_FAST" gh run list -R "$ORG/$repo" --branch "$branch" --limit 30 \
              --json databaseId,workflowName,conclusion,createdAt \
              --jq 'group_by(.workflowName)[] | max_by(.createdAt) | select(.conclusion=="cancelled") | .databaseId' 2>/dev/null | head -1)
      if [ -n "$rid" ] && [ "$(led_get "rerun:$key")" -lt 2 ]; then
        [ "$DRY" = "1" ] || _ut "$OS_UT_FAST" gh run rerun "$rid" -R "$ORG/$repo" >/dev/null 2>&1
        led_inc "rerun:$key"; acted+=("HEAL $repo#$num: cancelled head re-run")
        continue
      fi
    fi

    [ "$pending" != "0" ] && continue   # checks still running — next cycle

    # ---- 4: advisory review threads (only when the AI review check PASSED) ----
    unresolved=$(_ut "$OS_UT_FAST" gh api graphql -f query="query{repository(owner:\"$ORG\",name:\"$repo\"){pullRequest(number:$num){reviewThreads(first:30){nodes{id isResolved}}}}}" --jq '[.data.repository.pullRequest.reviewThreads.nodes[]|select(.isResolved==false)]|length' 2>/dev/null || echo 0)
    if [ "${unresolved:-0}" -gt 0 ]; then
      ai_ok=$(_ut "$OS_UT_FAST" gh pr view "$num" -R "$ORG/$repo" --json statusCheckRollup --jq '[.statusCheckRollup[] | select(.name=="Claude PR review" and .conclusion=="SUCCESS")] | length' 2>/dev/null)
      if [ "${ai_ok:-0}" -gt 0 ]; then
        if [ "$DRY" != "1" ]; then
          _ut "$OS_UT_FAST" gh api graphql -f query="query{repository(owner:\"$ORG\",name:\"$repo\"){pullRequest(number:$num){reviewThreads(first:30){nodes{id isResolved}}}}}" --jq '.data.repository.pullRequest.reviewThreads.nodes[]|select(.isResolved==false)|.id' 2>/dev/null \
            | while read -r tid; do gh api graphql -f query="mutation{resolveReviewThread(input:{threadId:\"$tid\"}){thread{isResolved}}}" >/dev/null 2>&1; done
        fi
        acted+=("HEAL $repo#$num: resolved $unresolved advisory thread(s) — review check green")
      else
        continue  # reviewer itself blocked — a human decides
      fi
    fi

    # ---- fleet PRs stop here: maintained, never merged by the shepherd ----
    [ "$fleet" = "1" ] && continue

    # ---- 5+3: merge green; update-branch when merely behind ----
    # Merge ONLY on a positive green. "no-signal" (nothing failing but nothing
    # passed either — every check cancelled, or no checks at all) alerts once
    # and is left for a human; it must never be mistaken for success.
    if [ "$verdict" != "green" ]; then
      if [ "$(led_get "alert:$key")" = "0" ]; then
        alerts+=("$repo#$num ($title): NOT MERGED — checks are '$verdict', not green")
        led_inc "alert:$key"
      fi
      continue
    fi
    if [ "$DRY" = "1" ]; then acted+=("(dry) SHIP $repo#$num would merge"); continue; fi
    if gh pr merge "$num" -R "$ORG/$repo" --squash --delete-branch >/dev/null 2>&1; then
      merged+=("$repo#$num $title")
    else
      ms=$(_ut "$OS_UT_FAST" gh api "repos/$ORG/$repo/pulls/$num" --jq .mergeable_state 2>/dev/null)
      if [ "$ms" = "behind" ]; then
        _ut "$OS_UT_FAST" gh api -X PUT "repos/$ORG/$repo/pulls/$num/update-branch" >/dev/null 2>&1 \
          && acted+=("HEAL $repo#$num: behind main — branch updated, next cycle merges")
      fi
    fi
  done <<EOF_PRS
$prs
EOF_PRS
done

echo "== pr-shepherd =="
printf '%s\n' "${acted[@]+"${acted[@]}"}" | sed 's/^/  /'
[ "${#merged[@]}" -gt 0 ] && printf '  MERGED %s\n' ${merged[@]+"${merged[@]}"}
[ "${#alerts[@]}" -gt 0 ] && printf '  ALERT %s\n' ${alerts[@]+"${alerts[@]}"}
[ "${#acted[@]}" -eq 0 ] && [ "${#merged[@]}" -eq 0 ] && [ "${#alerts[@]}" -eq 0 ] && echo "  quiet — nothing to shepherd"

command -v write_status >/dev/null 2>&1 && write_status "pr-shepherd" \
  "$([ "${#alerts[@]}" -gt 0 ] && echo warn || echo true)" \
  "acted=${#acted[@]} merged=${#merged[@]} alerts=${#alerts[@]}" \
  "{\"acted\":${#acted[@]},\"merged\":${#merged[@]},\"alerts\":${#alerts[@]}}"
if [ "${#merged[@]}" -gt 0 ] || [ "${#alerts[@]}" -gt 0 ]; then
  body=""
  [ "${#merged[@]}" -gt 0 ] && body="merged:
$(printf '%s\n' ${merged[@]+"${merged[@]}"})"
  [ "${#alerts[@]}" -gt 0 ] && body="$body
needs a human:
$(printf '%s\n' ${alerts[@]+"${alerts[@]}"})"
  [ -x "$HERE/notify.sh" ] && "$HERE/notify.sh" "🚢 pr-shepherd" "$body" >/dev/null 2>&1 || true
fi
exit 0
