#!/usr/bin/env bash
# Ebda Foundation — Cost Guard (OS oversight function)
# Read-only watchdog. Detects the cost/billing regressions that bled the budget:
#   1) any repo where neon-snapshot.yml is ACTIVE again
#   2) any Neon project with prod-* snapshot branches or > BRANCH_MAX branches
# Alerts (Telegram if configured); never deletes. Human-gated remediation.
# Schedule via launchd/cron; or run on demand. Exit 1 if any violation found.
# shellcheck source=lib/os-config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/os-config.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-config.sh" 2>/dev/null || true
command -v os_config_load >/dev/null 2>&1 && os_config_load
set -uo pipefail
. "$(dirname "$0")/lib/os-state.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-state.sh" 2>/dev/null || true
# NEON_API_KEY → neonctl runs headless (no browser OAuth fallback from launchd)
[ -f "$OS_SERVICES_ENV" ] && { set -a; . "$OS_SERVICES_ENV"; set +a; } 2>/dev/null || true   # set -a: children (neonctl, node, curl wrappers) must see the keys
export NEON_API_KEY="${NEON_API_KEY:-}"

ORG="$OS_NEON_ORG"        # Neon org (neonctl --org-id)
# GitHub orgs that bill Ahmad — NOT the Neon org above. Whisky-11 added 2026-10-15:
# its Actions billing failed and nothing watched it (see check 4).
GH_ORGS="${GH_ORGS:-$OS_BILLED_ORGS}"
BRANCH_MAX=8
REPOS=(
  "$OS_ORG/ebda-store"
  "$OS_ORG/ebda-whatsapp"
  "$OS_ORG/ebda-studio"
 
)
# Dynamic — pull live project IDs from Neon so this never drifts on a migration.
NEON_PROJECTS=($(neonctl projects list --org-id "$ORG" 2>/dev/null | grep -oE '[a-z]+-[a-z]+-[0-9]{8}' | sort -u))

violations=()

# 1) neon-snapshot must stay disabled everywhere
for slug in "${REPOS[@]}"; do
  st=$(_ut "$OS_UT_FAST" gh api "repos/$slug/actions/workflows" --jq '.workflows[]|select(.path|test("neon-snapshot"))|.state' 2>/dev/null)
  [ "$st" = "active" ] && violations+=("neon-snapshot RE-ENABLED on $slug")
done

# 2) no prod-* snapshots; branch count under cap
for pid in ${NEON_PROJECTS[@]+"${NEON_PROJECTS[@]}"}; do
  json=$(neonctl branches list --project-id "$pid" --org-id "$ORG" -o json 2>/dev/null) || continue
  read -r total prod <<<"$(printf '%s' "$json" | python3 -c "import sys,json;b=json.load(sys.stdin);b=b.get('branches',b) if isinstance(b,dict) else b;p=[x for x in b if x.get('name','').startswith('prod-')];print(len(b),len(p))" 2>/dev/null)"
  [ -n "${prod:-}" ] && [ "$prod" -gt 0 ] && violations+=("$pid has $prod prod-* snapshot branch(es) — snapshots are retired")
  [ -n "${total:-}" ] && [ "$total" -gt "$BRANCH_MAX" ] && violations+=("$pid has $total branches (> $BRANCH_MAX)")
done

# 3) GitHub Advanced Security is metered per active committer and can be switched on
#    per-repo by anyone with admin, with no signal anywhere until the invoice arrives.
#    On 2026-08-04 it was 76% of the GitHub bill ($12.26 of $16.26) from ONE private
#    landing-page repo nobody was working in — and it duplicated the gitleaks workflow
#    that repo already ran.
#
#    Check the BILLING endpoint, not the repo's security_and_analysis block: the
#    repo-level advanced_security field reads "-" even while usage is being billed, so
#    a per-repo sweep looks clean and finds nothing.
#
#    Any committer at all is the alert. This org's baseline is zero, so 1 is a change
#    someone made, and the whole failure mode is that nobody knew it happened.
for GH_ORG in $GH_ORGS; do
for product in secret_protection code_security; do
  ghas=$(_ut "$OS_UT_FAST" gh api \
    "orgs/$GH_ORG/settings/billing/advanced-security?advanced_security_product=$product" \
    --jq '"\(.total_advanced_security_committers)|\([.repositories[]?|select(.advanced_security_committers>0)|.name]|join(", "))"' 2>/dev/null)
  [ -n "$ghas" ] || continue          # no admin scope / endpoint unavailable — stay silent, do not fake a pass
  count="${ghas%%|*}"; repos="${ghas#*|}"
  case "$count" in ''|*[!0-9]*) continue ;; esac
  [ "$count" -gt 0 ] && violations+=("GitHub Advanced Security ($product) is BILLING for $count active committer(s) in $GH_ORG: ${repos:-unknown repo} — metered add-on, disable it unless deliberate")
done
done

# 4) GitHub Actions refusing jobs for BILLING. When an org's payment fails or its
#    spending limit is hit, every GitHub-hosted job is rejected at startup and the
#    run is just "failure" — it reads as broken tests, not as dead CI. On
#    2026-10-15 the Whisky-11 org had no CI at all this way and nothing noticed.
#    Look only at each repo's LATEST run, and only call it billing when the job's
#    own annotation says so (a real test failure must not trip this).
for GH_ORG in $GH_ORGS; do
  refused=()
  for repo in $(_ut "$OS_UT_FAST" gh repo list "$GH_ORG" --limit 200 --no-archived --json name -q '.[].name' 2>/dev/null); do
    read -r run_id concl <<<"$(_ut "$OS_UT_FAST" gh api "repos/$GH_ORG/$repo/actions/runs?per_page=1" \
      --jq '.workflow_runs[0] | "\(.id) \(.conclusion)"' 2>/dev/null)"
    [ "${concl:-}" = "failure" ] || continue
    url=$(_ut "$OS_UT_FAST" gh api "repos/$GH_ORG/$repo/actions/runs/$run_id/jobs" --jq '.jobs[0].check_run_url // empty' 2>/dev/null)
    [ -n "$url" ] || continue
    _ut "$OS_UT_FAST" gh api "${url#https://api.github.com/}/annotations" --jq '.[].message' 2>/dev/null \
      | grep -qiE 'payments have failed|spending limit' && refused+=("$repo")
  done
  [ ${#refused[@]} -gt 0 ] && violations+=("GitHub Actions is REFUSING jobs in $GH_ORG for billing (payment failed / spending limit) — latest run never started in: ${refused[*]}. Fix at github.com/organizations/$GH_ORG/settings/billing, or run CI on Umbra (vars.USE_SELF_HOSTED)")
done

if [ ${#violations[@]} -eq 0 ]; then
  echo "[cost-guard] OK — no neon-snapshot active, no prod-* branches, all projects under $BRANCH_MAX branches."
  write_status "cost" "true" "no violations: no active neon-snapshot, no prod-* branches, all projects under $BRANCH_MAX branches" '{}'
  exit 0
fi

msg="⚠️ Ebda OS Cost Guard — $(printf '%s' "${#violations[@]}") violation(s):"$'\n'"$(printf '  - %s\n' ${violations[@]+"${violations[@]}"})"
echo "$msg"
# Notify through the OS's single channel (Whisky Whoop) via the shared primitive.
"$(dirname "$0")/notify.sh" "Cost Guard" "$msg" >/dev/null 2>&1 || true
DETAIL=$(printf '%s\n' ${violations[@]+"${violations[@]}"} | python3 -c 'import json,sys; print(json.dumps({"items":[l for l in sys.stdin.read().splitlines() if l]}))')
write_status "cost" "false" "${#violations[@]} cost violation(s) detected" "$DETAIL"
exit 1
