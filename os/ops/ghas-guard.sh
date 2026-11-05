#!/usr/bin/env bash
# Whisky AI OS — GitHub Advanced Security guard (weekly).
# Owner rule (Ahmad, 2026-09-25): GitHub Advanced Security (Secret Protection /
# Code Security / CodeQL) stays OFF on every private repo — it bills per active
# committer ($12.26 Jul + $19.00 Aug 2026 before it was turned off). Free scanners
# (gitleaks, semgrep, secretlint) run in CI instead.
#
# Checks, per org:
#   1) billing: 0 active committers for secret_protection and code_security
#   2) this month's metered usage has no `ghas` line
#   3) the enforced `no-paid-security` code-security configuration still exists,
#      is enforced, is attached to EVERY private repo, and is the default for new
#      private/internal repos
#   4) no private repo reports a paid feature enabled
# A check that cannot run (lost admin:org scope, API error) is a FAILURE, not a
# pass — cost-guard's daily billing check stays silent in that case, this one
# must not. Read-only: never enables, disables or detaches anything.
# Exit 0 = all clear, 1 = violation or unverifiable.
set -uo pipefail
. "$(dirname "$0")/lib/os-state.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-state.sh" 2>/dev/null || true
declare -F _ut >/dev/null 2>&1 || _ut() { shift; "$@"; }
: "${OS_UT_FAST:=30}"

read -r -a ORGS <<<"${GHAS_GUARD_ORGS:-Ebda-AI-Studio whisky-11}"
CONFIG_NAME="${GHAS_GUARD_CONFIG:-no-paid-security}"
MONTH_START=$(date -u +%Y-%m-01)

violations=()
checked=0
v() { violations+=("$1"); }

for org in "${ORGS[@]}"; do
  # 1) billed committers
  for product in secret_protection code_security; do
    out=$(_ut "$OS_UT_FAST" gh api \
      "orgs/$org/settings/billing/advanced-security?advanced_security_product=$product" \
      --jq '"\(.total_advanced_security_committers)|\([.repositories[]?|select(.advanced_security_committers>0)|.name]|join(", "))"' 2>/dev/null)
    count="${out%%|*}"
    case "$count" in
      ''|*[!0-9]*) v "$org: could not read $product billing (admin:org scope lost?) — UNVERIFIED" ;;
      0) checked=$((checked+1)) ;;
      *) v "$org: $product is BILLING $count committer(s) on: ${out#*|}" ;;
    esac
  done

  # 2) this month's metered GHAS usage
  usage=$(_ut "$OS_UT_FAST" gh api "orgs/$org/settings/billing/usage" \
    --jq "[.usageItems[]? | select(.product==\"ghas\" and .date >= \"$MONTH_START\") | .netAmount] | add // 0" 2>/dev/null)
  if [ -z "$usage" ]; then
    # free-plan orgs have no enhanced-billing usage endpoint; billing (1) still covers them
    :
  elif python3 -c "import sys; sys.exit(0 if float('$usage') > 0 else 1)" 2>/dev/null; then
    v "$org: GHAS usage this month is \$$usage"
  else
    checked=$((checked+1))
  fi

  # 3) the enforced configuration
  cfg=$(_ut "$OS_UT_FAST" gh api "orgs/$org/code-security/configurations" \
    --jq "[.[] | select(.name==\"$CONFIG_NAME\")][0] | \"\(.id)|\(.enforcement)|\(.advanced_security)|\(.secret_scanning)|\(.code_scanning_default_setup)\"" 2>/dev/null)
  if ! [[ "${cfg%%|*}" =~ ^[0-9]+$ ]]; then
    v "$org: enforced config '$CONFIG_NAME' is MISSING (or unreadable)"
  else
    IFS='|' read -r cid enf adv ss cs <<<"$cfg"
    [ "$enf" = "enforced" ] || v "$org: '$CONFIG_NAME' enforcement is '$enf', expected 'enforced'"
    for pair in "advanced_security=$adv" "secret_scanning=$ss" "code_scanning_default_setup=$cs"; do
      [ "${pair#*=}" = "disabled" ] || v "$org: '$CONFIG_NAME' has ${pair%%=*}=${pair#*=}"
    done
    attached=$(_ut "$OS_UT_FAST" gh api --paginate "orgs/$org/code-security/configurations/$cid/repositories?per_page=100" \
      --jq '.[] | select(.status=="enforced" or .status=="attached") | .repository.name' 2>/dev/null | sort -u)
    private=$(_ut "$OS_UT_FAST" gh api --paginate "orgs/$org/repos?type=private&per_page=100" --jq '.[].name' 2>/dev/null | sort -u)
    if [ -z "$private" ] || [ -z "$attached" ]; then
      v "$org: could not list private repos / '$CONFIG_NAME' attachments — UNVERIFIED"
    else
      missing=$(comm -13 <(printf '%s\n' "$attached") <(printf '%s\n' "$private") | grep -v '^$' | tr '\n' ' ')
      [ -n "$missing" ] && v "$org: private repo(s) WITHOUT '$CONFIG_NAME': $missing"
    fi
    def=$(_ut "$OS_UT_FAST" gh api "orgs/$org/code-security/configurations/defaults" \
      --jq "[.[] | select(.configuration.name==\"$CONFIG_NAME\") | .default_for_new_repos][0] // \"none\"" 2>/dev/null)
    case "$def" in private_and_internal|all) checked=$((checked+1)) ;; *) v "$org: '$CONFIG_NAME' is not the default for new private repos (default_for_new_repos=$def)" ;; esac
  fi

  # 4) any private repo with a paid feature switched on
  on=$(_ut "$OS_UT_FAST" gh api --paginate "orgs/$org/repos?type=private&per_page=100" \
    --jq '.[] | select(.security_and_analysis != null) | select(([.security_and_analysis.advanced_security.status, .security_and_analysis.code_security.status, .security_and_analysis.secret_scanning.status, .security_and_analysis.secret_scanning_push_protection.status] | index("enabled")) != null) | .name' 2>/dev/null)
  rc=$?
  if [ "$rc" -ne 0 ]; then v "$org: could not list private repos to check paid features — UNVERIFIED"
  elif [ -n "$on" ]; then v "$org: paid security feature ENABLED on private repo(s): $(printf '%s ' $on)"; fi
done

if [ ${#violations[@]} -eq 0 ] && [ "$checked" -gt 0 ]; then
  echo "[ghas-guard] OK — ${ORGS[*]}: 0 billed committers, no GHAS usage this month, '$CONFIG_NAME' enforced on every private repo and default for new ones."
  declare -F write_status >/dev/null && write_status "ghas" "true" "GitHub Advanced Security off and enforced on ${ORGS[*]}" '{}'
  exit 0
fi
[ "$checked" -eq 0 ] && v "no check could run at all — gh auth/scope problem"

msg="⚠️ GitHub Advanced Security guard — ${#violations[@]} problem(s):"$'\n'"$(printf '  - %s\n' ${violations[@]+"${violations[@]}"})"$'\n'"Rule: GHAS stays OFF (bills per committer). Fix: re-attach '$CONFIG_NAME' / disable the feature; admin:org scope via 'gh auth refresh -h github.com -s admin:org'."
echo "$msg"
"$(dirname "$0")/notify.sh" "GHAS Guard" "$msg" >/dev/null 2>&1 || true
if declare -F write_status >/dev/null; then
  DETAIL=$(printf '%s\n' ${violations[@]+"${violations[@]}"} | python3 -c 'import json,sys; print(json.dumps({"items":[l for l in sys.stdin.read().splitlines() if l]}))')
  write_status "ghas" "false" "${#violations[@]} GHAS problem(s)" "$DETAIL"
fi
exit 1
