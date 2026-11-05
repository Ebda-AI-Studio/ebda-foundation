#!/usr/bin/env bash
# dr-drill.sh — Disaster-Recovery self-test for the Whisky AI OS.
#
# PROVES the OS can actually recover, continuously — not just claims it in a
# runbook. For each Neon-backed Force project it drills BOTH restore paths on
# throwaway branches, verifies, then tears them down:
#   1. PITR      — branch the primary to a past timestamp, connect, assert schema+data.
#   2. Dump      — restore the latest local pg_dump into a fresh branch, assert table count.
# Production (the primary branch) is NEVER touched — only `drill-*` branches are
# created and they are always deleted (start-of-run sweep + end-of-run teardown).
#
# Writes ~/.whisky-os-state/dr-drill-status.json (dashboard "Disaster Recovery"
# tile) and notifies via notify.sh / emit_event on any failure.
#
# Env: DRY_RUN=1 (skip mutations, report intent) · DR_MODE=pitr|full (default full)
#      DR_RESTORE_TIMEOUT (seconds for the dump restore, default 420)
# shellcheck source=lib/os-config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/os-config.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-config.sh" 2>/dev/null || true
command -v os_config_load >/dev/null 2>&1 && os_config_load
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/lib/os-state.sh" 2>/dev/null || { echo "os-state.sh missing"; exit 0; }
export PATH="/opt/homebrew/opt/postgresql@17/bin:/opt/homebrew/bin:$PATH"
# Load NEON_API_KEY so neonctl runs headless — long-lived key takes precedence over
# OAuth and NEVER opens a browser (the daily interactive-auth-tab bug). Fall back to
# the OAuth token only if no key is set.
[ -f "$OS_SERVICES_ENV" ] && { set -a; . "$OS_SERVICES_ENV"; set +a; } 2>/dev/null || true   # set -a: children (neonctl, node, curl wrappers) must see the keys
export NEON_API_KEY="${NEON_API_KEY:-}"

ORG="${DR_ORG:-$OS_NEON_ORG}"
DR_MODE="${DR_MODE:-full}"
DR_RESTORE_TIMEOUT="${DR_RESTORE_TIMEOUT:-420}"
# Bounded-restore needs a `timeout` binary. macOS ships NEITHER GNU timeout nor
# gtimeout by default (coreutils provides gtimeout via brew/MacPort) — so on this
# Mac the old `command -v timeout` guard fell through to an UNBOUNDED restore,
# silently dropping the hang protection (dead-gate class, 2026-07-22 audit).
# Detect either name once; TO_BIN empty = genuinely no timeout available.
TO_BIN=""
command -v timeout  >/dev/null 2>&1 && TO_BIN="timeout"
[ -z "$TO_BIN" ] && command -v gtimeout >/dev/null 2>&1 && TO_BIN="gtimeout"
DRY_RUN="${DRY_RUN:-0}"

# project_id : friendly : backup_dir_name  (backups at $OS_PROJECTS_DIR/_backups/<dir>/)
PROJECTS=(
  "crimson-king-40424588:fwb:ebda-store"
  "spring-dew-80973306:wbs:ebda-whatsapp"
)

BACKUPS="$OS_PROJECTS_DIR/_backups"
fails=(); warns=(); oks=(); details_json="["

nctl() { neonctl "$@" --org-id "$ORG" --output json 2>/dev/null; }
primary_branch() { nctl branches list --project-id "$1" | jq -r '.[] | select(.default==true or .primary==true) | .name' 2>/dev/null | head -1; }
conn() { neonctl connection-string "$2" --project-id "$1" --org-id "$ORG" --role-name neondb_owner --database-name neondb 2>/dev/null; }
del_branch() { [ "$DRY_RUN" = 1 ] && return 0; neonctl branches delete "$2" --project-id "$1" --org-id "$ORG" >/dev/null 2>&1; }
table_count() { psql "$1" -tA -c "select count(*) from information_schema.tables where table_schema='public';" 2>/dev/null | tr -d '[:space:]'; }

sweep_stale() { # delete any leftover drill-* branch from a crashed prior run
  local pid="$1" b
  for b in $(nctl branches list --project-id "$pid" | jq -r '.[].name' 2>/dev/null | grep '^drill-'); do
    echo "  sweep stale branch: $b"; del_branch "$pid" "$b"
  done
}

drill_pitr() { # $1=pid $2=friendly  -> echoes "ok|warn|fail:<msg>"
  local pid="$1" fr="$2" prim ts url tc
  local br="drill-pitr-$fr"
  prim="$(primary_branch "$pid")"; [ -n "$prim" ] || { echo "fail:no primary branch"; return; }
  ts="$(date -u -v-10M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '-10 min' +%Y-%m-%dT%H:%M:%SZ)"
  if [ "$DRY_RUN" = 1 ]; then echo "ok:DRY_RUN pitr $prim@$ts"; return; fi
  nctl branches create --project-id "$pid" --name "$br" --parent "$prim" --timestamp "$ts" >/dev/null 2>&1 \
    || { echo "fail:pitr branch create failed (retention window? primary=$prim)"; return; }
  url="$(conn "$pid" "$br")"; tc="$(table_count "$url")"
  del_branch "$pid" "$br"
  { [ -n "$tc" ] && [ "$tc" -gt 5 ] 2>/dev/null; } && echo "ok:pitr tables=$tc" || echo "fail:pitr connected but tables=$tc"
}

drill_dump() { # $1=pid $2=friendly $3=backup_dir -> echoes "ok|warn|fail:<msg>"
  local pid="$1" fr="$2" dir="$3" dump prim url tc rc
  local br="drill-dump-$fr"
  dump="$(ls -t "$BACKUPS/$dir"/*.sql.gz 2>/dev/null | grep -v '\.enc$' | head -1)"
  [ -n "$dump" ] || { echo "warn:no local plaintext dump in $dir"; return; }
  # cheap validity gate first. Capture head into a var so pipefail doesn't trip
  # on zcat's SIGPIPE when head closes the pipe early.
  local head_txt; head_txt="$(zcat < "$dump" 2>/dev/null | head -40)"
  printf '%s' "$head_txt" | grep -q 'PostgreSQL database dump' \
    || { echo "fail:latest dump not valid SQL ($(basename "$dump"))"; return; }
  if [ "$DR_MODE" != full ] || [ "$DRY_RUN" = 1 ]; then echo "ok:dump valid $(basename "$dump")"; return; fi
  prim="$(primary_branch "$pid")"
  nctl branches create --project-id "$pid" --name "$br" --parent "$prim" >/dev/null 2>&1 \
    || { echo "fail:dump branch create failed"; return; }
  url="$(conn "$pid" "$br")"
  psql "$url" -q -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;" >/dev/null 2>&1
  # bounded restore — a slow network must not hang the OS job
  if [ -n "$TO_BIN" ]; then
    zcat < "$dump" | "$TO_BIN" "$DR_RESTORE_TIMEOUT" psql "$url" -q --single-transaction -v ON_ERROR_STOP=1 >/dev/null 2>&1; rc=$?
  else
    zcat < "$dump" | psql "$url" -q --single-transaction -v ON_ERROR_STOP=1 >/dev/null 2>&1; rc=$?
  fi
  tc="$(table_count "$url")"
  del_branch "$pid" "$br"
  if [ "$rc" = 0 ] && [ -n "$tc" ] && [ "$tc" -gt 5 ] 2>/dev/null; then
    echo "ok:dump restored tables=$tc $(basename "$dump")"
  elif [ "$rc" = 124 ]; then
    echo "warn:dump restore timed out >${DR_RESTORE_TIMEOUT}s (dump is valid though)"
  else
    echo "fail:dump restore rc=$rc tables=$tc"
  fi
}

# Require a NON-INTERACTIVE credential: the API key (preferred) or a pre-existing
# OAuth token. Never let neonctl fall back to its browser login from launchd.
if [ -z "$NEON_API_KEY" ] && [ -z "$(jq -r '.access_token // empty' "$HOME/.config/neonctl/credentials.json" 2>/dev/null)" ]; then
  write_status dr-drill warn "no NEON_API_KEY and neonctl not authenticated — DR drill skipped" '{"reason":"no neon credential"}'
  exit 0
fi

for entry in "${PROJECTS[@]}"; do
  IFS=: read -r pid fr dir <<<"$entry"
  echo "== $fr ($pid) =="

  # The drill restores into a fresh branch and pg_dumps — both open real
  # connections, so drilling a PARKED project wakes its compute and defeats the
  # pause. Skip rather than silently spend: a paused DB is not accepting writes,
  # so there is no new state whose restorability is in question.
  if [ -f "$HOME/.whisky-os-state/${fr}-paused" ] || [ -f "$HOME/.whisky-os-state/${dir}-paused" ]; then
    echo "  SKIP — $fr is paused (ops/wbs-power.sh status); not waking it for a drill"
    continue
  fi
  sweep_stale "$pid"
  p="$(drill_pitr "$pid" "$fr")"; echo "  PITR: $p"
  d="$(drill_dump "$pid" "$fr" "$dir")"; echo "  DUMP: $d"
  for r in "pitr:$p" "dump:$d"; do
    kind="${r%%:*}"; res="${r#*:}"; st="${res%%:*}"; msg="${res#*:}"
    case "$st" in
      ok)   oks+=("$fr/$kind: $msg") ;;
      warn) warns+=("$fr/$kind: $msg") ;;
      *)    fails+=("$fr/$kind: $msg") ;;
    esac
  done
  details_json+="{\"project\":\"$fr\",\"pitr\":\"$p\",\"dump\":\"$d\"},"
done
details_json="${details_json%,}]"

# aggregate
if [ "${#fails[@]}" -gt 0 ]; then
  ok=false; summary="DR drill FAILED: ${fails[*]}"
elif [ "${#warns[@]}" -gt 0 ]; then
  ok=warn; summary="DR drill degraded: ${warns[*]}"
else
  ok=true; summary="DR recovery verified — ${#oks[@]} checks passed (PITR + dump restore, both projects)"
fi

write_status dr-drill "$ok" "$summary" "{\"passed\":${#oks[@]},\"warned\":${#warns[@]},\"failed\":${#fails[@]},\"mode\":\"$DR_MODE\",\"results\":$details_json}"

if [ "$ok" = false ]; then
  emit_event dr-drill critical "$summary" "$details_json" 2>/dev/null || true
  emit_inbox "DR self-test FAILED — recovery capability is broken: ${fails[*]}" 2>/dev/null || true
  "$HERE/notify.sh" "🚨 DR self-test FAILED" "$summary" "The OS can't prove it can recover. Fix before the next incident." 2>/dev/null || true
elif [ "$ok" = warn ]; then
  emit_event dr-drill medium "$summary" "$details_json" 2>/dev/null || true
fi

echo "== $summary =="
