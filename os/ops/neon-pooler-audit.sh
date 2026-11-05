#!/usr/bin/env bash
# Scan every project under $OS_PROJECTS_DIR/ for the Neon pooler trap.
#
# Two traps:
# 1. DATABASE_URL points at -pooler endpoint WITHOUT &pgbouncer=true
#    → Prisma throws P2028/42P05 under concurrent load.
# 2. DIRECT_URL points at -pooler endpoint
#    → migrations run through PgBouncer transaction-mode pooling, breaks
#      DDL + advisory locks.
#
# Matches both sslmode=require AND sslmode=verify-full (Neon's stricter mode).
# Exits 0 always — diagnostic only, never blocks.
#
# Full policy: ~/.claude/projects/-Users-ahmadsharaf/memory/feedback-neon-pooled-needs-pgbouncer-and-direct-url.md

# shellcheck source=lib/os-config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/os-config.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-config.sh" 2>/dev/null || true
command -v os_config_load >/dev/null 2>&1 && os_config_load
set -uo pipefail

PROJECTS_DIR="${PROJECTS_DIR:-$OS_PROJECTS_DIR}"
PROJECTS_ROOT="$PROJECTS_DIR"
# shellcheck source=/dev/null
. "$(dirname "$0")/lib/projects-layout.sh"
trap_count=0

echo "── Neon pooler audit — $(date '+%Y-%m-%d %H:%M') ──"
echo

while IFS= read -r project; do
    project="$project/"
    name=$(basename "$project")
    case "$name" in _*|node_modules|.*) continue ;; esac
    # Exempt: projects using the @neondatabase/serverless HTTP driver. The
    # pgbouncer-trap only applies to Prisma/pg over TCP. HTTP-driver projects
    # often have NO local DATABASE_URL (Vercel auto-injects). Note them once
    # and move on.
    pkgjson="${project}package.json"
    if [[ -f "$pkgjson" ]] && grep -q '"@neondatabase/serverless"' "$pkgjson" 2>/dev/null \
       && ! grep -q '"@prisma/client"' "$pkgjson" 2>/dev/null; then
        echo "── $name ── ⚪ exempt (uses @neondatabase/serverless HTTP driver)"
        continue
    fi
    envs=$(find "$project" -maxdepth 4 -name ".env*" -not -path "*/node_modules/*" -not -path "*/.git/*" 2>/dev/null)
    [[ -z "$envs" ]] && continue
    project_has_neon=0
    while IFS= read -r env; do
        [[ -z "$env" ]] && continue
        grep -q "neon.tech" "$env" 2>/dev/null || continue
        if [[ $project_has_neon -eq 0 ]]; then
            echo "── $name ──"
            project_has_neon=1
        fi

        rel=${env#"$OS_PROJECTS_DIR"/}
        db_trap=""
        dir_trap=""

        if grep -qE "^DATABASE_URL.*-pooler.*sslmode=(require|verify-full)" "$env" 2>/dev/null \
           && ! grep -q "^DATABASE_URL.*pgbouncer=true" "$env" 2>/dev/null; then
            db_trap="🔴 DATABASE_URL missing pgbouncer=true"
            trap_count=$((trap_count + 1))
        fi
        if grep -qE "^DIRECT_URL.*-pooler" "$env" 2>/dev/null; then
            dir_trap="🔴 DIRECT_URL on pooler host (should be unpooled)"
            trap_count=$((trap_count + 1))
        fi

        if [[ -z "$db_trap" && -z "$dir_trap" ]]; then
            printf "  🟢 %s\n" "$rel"
        else
            printf "  %s\n" "$rel"
            [[ -n "$db_trap" ]] && printf "     %s\n" "$db_trap"
            [[ -n "$dir_trap" ]] && printf "     %s\n" "$dir_trap"
        fi
    done <<<"$envs"
done < <(list_repo_roots)

echo
if [[ $trap_count -eq 0 ]]; then
    echo "✓ all clean ($trap_count traps)"
else
    echo "⚠ $trap_count trap(s) found"
    echo "Fix: append &pgbouncer=true to pooled DATABASE_URL; drop -pooler from DIRECT_URL host."
    echo "Full policy + 7-step deploy checklist:"
    echo "  ~/.claude/projects/-Users-ahmadsharaf/memory/feedback-neon-pooled-needs-pgbouncer-and-direct-url.md"
fi
