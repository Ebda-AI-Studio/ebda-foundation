#!/usr/bin/env bash
# neon-recover.sh — Tier-3 (data-tier) disaster recovery for the Whisky AI OS.
#
# The OS NEVER auto-cuts-over a database (a false-positive restore = lost customer
# writes). Instead it PREPARES a verified recovery and waits for a one-tap human
# approve (Ahmad's decision 2026-07-06). This script is that mechanism.
#
#   prepare <project_id> [lookback_min]   Create + VERIFY a PITR recovery branch
#                                          (default 15 min ago). NON-DESTRUCTIVE —
#                                          prod is untouched. Escalates via Telegram
#                                          with the exact approve command.
#   status  <project_id>                   List prepared recover-* branches.
#   approve <project_id> <branch>          THE human-gated cutover. Reversible:
#                                          repoints nothing destructively — makes the
#                                          recovery branch the default so the app can
#                                          be pointed at it; old primary is KEPT for
#                                          forensics. Requires typing the branch name.
#   cleanup <project_id>                   Delete stale recover-* branches.
#
# Env: DR_ORG (default the Force org) · DRY_RUN=1
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
export PATH="/opt/homebrew/opt/postgresql@17/bin:$PATH"
ORG="${DR_ORG:-org-lingering-river-25973882}"
NOTIFY="$HERE/notify.sh"
DRY="${DRY_RUN:-0}"
[ -f "$HERE/lib/os-state.sh" ] && source "$HERE/lib/os-state.sh" 2>/dev/null || true
# NEON_API_KEY → neonctl runs headless (no browser OAuth fallback)
[ -f "${OS_SERVICES_ENV:-$HOME/.whisky-services.env}" ] && { set -a; . "${OS_SERVICES_ENV:-$HOME/.whisky-services.env}"; set +a; } 2>/dev/null || true   # set -a: children (neonctl, node, curl wrappers) must see the keys
export NEON_API_KEY="${NEON_API_KEY:-}"

nctl() { neonctl "$@" --org-id "$ORG" --output json 2>/dev/null; }
primary_branch() { nctl branches list --project-id "$1" | jq -r '.[]|select(.default==true or .primary==true)|.name' 2>/dev/null | head -1; }
conn() { neonctl connection-string "$2" --project-id "$1" --org-id "$ORG" --role-name neondb_owner --database-name neondb 2>/dev/null; }
pname() { nctl projects get "$1" | jq -r '.name // .project.name // "?"' 2>/dev/null; }

cmd="${1:-}"; pid="${2:-}"
[ -n "$cmd" ] && [ -n "$pid" ] || { echo "usage: neon-recover.sh {prepare|status|approve|cleanup} <project_id> [arg]"; exit 2; }

case "$cmd" in
  prepare)
    look="${3:-15}"
    prim="$(primary_branch "$pid")"; nm="$(pname "$pid")"
    [ -n "$prim" ] || { echo "no primary branch for $pid"; exit 1; }
    ts="$(date -u -v-"${look}"M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "-${look} min" +%Y-%m-%dT%H:%M:%SZ)"
    br="recover-$(date -u +%Y%m%dT%H%M%SZ)"
    echo "[$nm] preparing recovery branch $br from $prim @ $ts (lookback ${look}m)"
    if [ "$DRY" = 1 ]; then echo "[dry] would create $br"; exit 0; fi
    nctl branches create --project-id "$pid" --name "$br" --parent "$prim" --timestamp "$ts" >/dev/null 2>&1 \
      || { echo "FAILED to create $br (retention window? >7d?)"; [ -x "$NOTIFY" ] && "$NOTIFY" "🚨 DB recovery PREP FAILED" "$nm: could not branch to $ts — outside the 7d PITR window? Manual DR needed."; exit 1; }
    url="$(conn "$pid" "$br")"
    tc="$(psql "$url" -tA -c "select count(*) from information_schema.tables where table_schema='public';" 2>/dev/null | tr -d '[:space:]')"
    # a small sample of row counts as a human sanity signal (best-effort; table names vary per project)
    rows="$(psql "$url" -tA -c "select coalesce(string_agg(t||'='||c,', '),'(no common tables)') from (select 'orders' t, (select count(*) from orders) c union all select 'products',(select count(*) from products) union all select 'stores',(select count(*) from stores)) s;" 2>/dev/null || echo 'n/a')"
    msg="Recovery branch READY for one-tap approve.
project: $nm ($pid)
branch:  $br  (state @ $ts)
verified: $tc tables; $rows
APPROVE (makes it default, keeps old primary for forensics):
  ~/.claude/scripts/neon-recover.sh approve $pid $br
DISCARD:
  ~/.claude/scripts/neon-recover.sh cleanup $pid"
    echo "$msg"
    command -v write_status >/dev/null && write_status neon-recover warn "DB recovery prepared for $nm — awaiting approve ($br)" "{\"project\":\"$nm\",\"branch\":\"$br\",\"timestamp\":\"$ts\",\"tables\":\"$tc\"}"
    command -v emit_inbox >/dev/null && emit_inbox "DB recovery prepared for $nm — one tap to approve: $br" "{\"branch\":\"$br\"}" 2>/dev/null || true
    [ -x "$NOTIFY" ] && "$NOTIFY" "🛟 DB recovery prepared — approve?" "$msg" || true
    ;;
  status)
    echo "recover-* branches on $(pname "$pid"):"
    nctl branches list --project-id "$pid" | jq -r '.[]|select(.name|startswith("recover-"))|"  \(.name)\tcreated \(.created_at)"' 2>/dev/null || echo "  (none)"
    ;;
  approve)
    br="${3:-}"; [ -n "$br" ] || { echo "usage: approve <project_id> <recover-branch>"; exit 2; }
    nm="$(pname "$pid")"
    echo "⚠️  CUTOVER: make '$br' the DEFAULT branch of $nm."
    echo "    The current primary is KEPT (renamed by Neon) for forensics — this is reversible."
    if [ "$DRY" = 1 ]; then echo "[dry] would: neonctl branches set-default $br"; exit 0; fi
    # set-default is Neon's non-destructive promote: the recovery branch becomes primary,
    # the old primary is retained as a non-default branch (not deleted).
    neonctl branches set-default "$br" --project-id "$pid" --org-id "$ORG" 2>&1 | tail -3 \
      || { echo "set-default failed — do it in the Neon console (Branches → $br → Set as default)"; exit 1; }
    echo "✓ $br is now default. Verify the app, then update DATABASE_URL/DIRECT_URL if they pin a branch id."
    command -v write_status >/dev/null && write_status neon-recover true "DB recovered on $nm — $br promoted to default" "{\"project\":\"$nm\",\"branch\":\"$br\"}"
    [ -x "$NOTIFY" ] && "$NOTIFY" "✅ DB recovery APPROVED" "$nm: $br is now the default branch. Old primary kept for forensics." || true
    ;;
  cleanup)
    for b in $(nctl branches list --project-id "$pid" | jq -r '.[]|select(.name|startswith("recover-"))|.name' 2>/dev/null); do
      echo "deleting $b"; [ "$DRY" = 1 ] || neonctl branches delete "$b" --project-id "$pid" --org-id "$ORG" >/dev/null 2>&1
    done
    ;;
  *) echo "unknown: $cmd"; exit 2;;
esac
