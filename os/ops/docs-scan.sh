#!/usr/bin/env bash
# Whisky AI OS — docs-scan (keep docs reflecting reality).
# Read-only HEURISTIC pass over each prod repo: flags the common doc-drift the fleet
# audit found — missing/misplaced runbooks and obviously-stale stack mentions — and
# alerts the Ebda OS bot. This is the cheap, scheduled tier; the DEEP qualitative
# scan (every doc claim vs the live code) is the audit fleet's `docs-parity` lens,
# run on a cadence via an audit run (LLM, separate).
# shellcheck source=lib/os-config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/os-config.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-config.sh" 2>/dev/null || true
command -v os_config_load >/dev/null 2>&1 && os_config_load
set -uo pipefail
. "$(dirname "$0")/lib/os-state.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-state.sh" 2>/dev/null || true
HERE="$(cd "$(dirname "$0")" && pwd)"
PROJECTS="$OS_PROJECTS_DIR"
# TCC canary: a blind launchd context must abort, not telegram phantom drift
OS_JOB_NAME=docs-scan
if command -v require_projects_access >/dev/null 2>&1; then
  require_projects_access || exit 0
fi

# Tier-A prod repos that must carry the full runbook set.
FULL_REPOS=(ebda-store ebda-whatsapp ebda-studio)
# All live prod repos (README expected).
ALL_REPOS=(ebda-store ebda-whatsapp ebda-studio ebda-foundation mypovonai digital-card)
# Hosting/stack terms that are stale for the Ebda stack (Cloudflare Workers, Railway, managed Postgres).
STALE='Netlify|Heroku|render\.com|DigitalOcean'

findings=()

for r in "${ALL_REPOS[@]}"; do
  d=$(resolve_repo_dir "$r" 2>/dev/null || echo "$PROJECTS/$r"); [ -d "$d" ] || continue
  # README somewhere
  find "$d" -maxdepth 2 -iname 'README*' -not -path '*/node_modules/*' 2>/dev/null | grep -q . || findings+=("$r: no README")
  # stale hosting mentions in PRODUCT docs (skip meta-docs: audits/plans/superpowers are historical)
  hits=$(grep -rliE "$STALE" "$d"/*.md "$d"/docs 2>/dev/null | grep -viE 'node_modules|/\.|/audits/|/superpowers/|/plans/' | head -3)
  [ -n "$hits" ] && findings+=("$r: stale hosting term ($STALE) in $(echo "$hits" | sed "s#$d/##" | tr '\n' ' ')")
done

for r in "${FULL_REPOS[@]}"; do
  d="$PROJECTS/$r"; [ -d "$d" ] || continue
  # runbooks must exist AND live under docs/ (audit: store had DEPLOYMENT.md misplaced at root)
  for doc in DEPLOYMENT ROLLBACK SCALING; do
    if ! find "$d/docs" -iname "${doc}.md" 2>/dev/null | grep -q .; then
      if find "$d" -maxdepth 1 -iname "${doc}.md" 2>/dev/null | grep -q .; then
        findings+=("$r: ${doc}.md is at repo root — should be under docs/")
      else
        findings+=("$r: missing docs/${doc}.md runbook")
      fi
    fi
  done
done

if [ ${#findings[@]} -eq 0 ]; then
  echo "[docs-scan] OK — no structural doc-drift across prod repos."
  write_status "docs-scan" "true" "no structural doc-drift across prod repos" '{}'
  exit 0
fi
msg="📄 Docs-scan — ${#findings[@]} drift item(s):"$'\n'"$(printf '  • %s\n' ${findings[@]+"${findings[@]}"})"
echo "$msg"
# suppressible: dream-scan invokes this per-repo for parsing — it must not
# telegram on every call (Ahmad got the same digest 3x, 2026-07-12)
if [ "${DOCS_SCAN_NO_NOTIFY:-0}" != "1" ]; then
  "$HERE/notify.sh" "Docs-scan" "$msg" >/dev/null 2>&1 || true
fi
DETAIL=$(printf '%s\n' ${findings[@]+"${findings[@]}"} | python3 -c 'import json,sys; print(json.dumps({"items":[l for l in sys.stdin.read().splitlines() if l]}))')
write_status "docs-scan" "false" "${#findings[@]} doc-drift finding(s)" "$DETAIL"
exit 1
