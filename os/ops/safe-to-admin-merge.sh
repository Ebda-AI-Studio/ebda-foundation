#!/usr/bin/env bash
# Whisky AI OS — admin-merge safety gate.
# The remediation loop MUST call this before ANY `gh pr merge --admin` (or merge that
# bypasses a failing check). It reads the PR's failing checks and refuses if a SECURITY
# check is among them — you never bypass a secret/SAST/vuln scan; those need a real fix.
#
#   safe-to-admin-merge.sh <owner/repo> <pr-number>
#   exit 0  -> no failing checks; merge normally (no admin needed)
#   exit 1  -> a SECURITY check is FAILING -> DO NOT admin-merge. Fix it. (gitleaks/semgrep/zap/secret/sast/codeql)
#   exit 2  -> only non-security checks failing (infra/flake, e.g. a Vercel-token gate) -> admin-merge ONLY with explicit human OK
set -uo pipefail
slug="${1:?owner/repo}"; num="${2:?pr-number}"

SECURITY='gitleaks|semgrep|secret|leaked|security|sast|zap|trufflehog|codeql|vuln|audit'

br=$(gh pr view "$num" --repo "$slug" --json headRefName --jq .headRefName 2>/dev/null)
# `cancelled`, `timed_out`, `stale`, `action_required` and `startup_failure` are
# NOT failures, but they are not passes either. Selecting only "failure" let
# pr-shepherd merge client-repo#99 on an all-cancelled CI run (fixed in
# lib/pr-merge-gate.sh). The required-checks gate below already demands an actual
# SUCCESS, but it only runs when the base branch is PROTECTED — on an
# unprotected branch this list is the only gate, so it has to catch them too.
fails=$(gh run list --repo "$slug" --branch "$br" --limit 15 --json name,conclusion \
  --jq '.[] | select(.conclusion=="failure" or .conclusion=="cancelled" or .conclusion=="timed_out" or .conclusion=="stale" or .conclusion=="action_required" or .conclusion=="startup_failure") | .name' 2>/dev/null | sort -u)

# A REQUIRED check that never ran is not a pass. `gh run list` only reports runs
# that actually executed, so with GitHub Actions billing blocked (every run dies at
# infra level, or never starts at all) `fails` is EMPTY and this gate used to say
# "OK — no failing checks" and exit 0 for a PR whose Semgrep, gitleaks and Security
# Audit gates had never executed once. Empty run-history is a FINDING, not a skip.
# NOTE: on an unprotected branch `gh api` writes its 404 body to STDOUT and exits
# non-zero, so the command substitution must be guarded by the exit status — not
# just 2>/dev/null, or the error JSON becomes a "required check" and every
# unprotected repo is wrongly refused.
base_ref=$(gh pr view "$num" --repo "$slug" --json baseRefName --jq .baseRefName 2>/dev/null)
if required=$(gh api "repos/$slug/branches/$base_ref/protection" \
      --jq '.required_status_checks.contexts[]?' 2>/dev/null); then
  required=$(printf '%s' "$required" | sort -u)
else
  required=""   # branch not protected -> nothing is required -> fall through
fi
if [ -n "$required" ]; then
  passed=$(gh pr view "$num" --repo "$slug" --json statusCheckRollup \
    --jq '.statusCheckRollup[]? | select(.conclusion=="SUCCESS") | .name' 2>/dev/null | sort -u)
  neverran=""
  while IFS= read -r ctx; do
    [ -n "$ctx" ] || continue
    printf '%s\n' "$passed" | grep -Fqx "$ctx" || neverran="${neverran}${ctx}"$'\n'
  done <<< "$required"
  neverran=$(printf '%s' "$neverran" | sed '/^$/d')
  if [ -n "$neverran" ]; then
    sec_nr=$(printf '%s\n' "$neverran" | grep -iE "$SECURITY" || true)
    if [ -n "$sec_nr" ]; then
      echo "[safe-merge] ⛔ REFUSE — required SECURITY check(s) have NOT PASSED on $slug#$num:"
      printf '%s\n' "$sec_nr" | sed 's/^/   - /; s/$/ (never ran \/ still pending)/'
      echo "   These are not 'green', they are UNRUN. Never admin-merge past a security scan"
      echo "   on the strength of an empty run-history. Get the check running, or take an"
      echo "   explicit, recorded human decision to accept the risk."
      exit 1
    fi
    echo "[safe-merge] ⚠️ required non-security check(s) have NOT PASSED on $slug#$num:"
    printf '%s\n' "$neverran" | sed 's/^/   - /; s/$/ (never ran \/ still pending)/'
    echo "   admin-merge ONLY with explicit human approval."
    exit 2
  fi
fi

if [ -z "$fails" ]; then
  echo "[safe-merge] OK — no failing checks on $slug#$num."
  exit 0
fi

sec=$(printf '%s\n' "$fails" | grep -iE "$SECURITY" || true)
if [ -n "$sec" ]; then
  echo "[safe-merge] ⛔ REFUSE — SECURITY check(s) FAILING on $slug#$num:"
  printf '   - %s\n' $sec
  echo "   Never admin-merge past a security scan. Fix the finding (or allowlist a verified false-positive), then merge."
  exit 1
fi

echo "[safe-merge] ⚠️ non-security failure(s) on $slug#$num (infra/flake):"
printf '   - %s\n' $fails
echo "   admin-merge is allowed ONLY with explicit human approval. Confirm the failure is unrelated to the change first."
exit 2
