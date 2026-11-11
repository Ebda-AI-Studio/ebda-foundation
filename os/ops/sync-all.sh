#!/usr/bin/env bash
# ============================================================
# sync-all.sh — the ONE "sync everything" verb of the Live Companion OS.
#
# "Foundation and memory sync together." The memory pipeline already syncs the
# foundation repo every run (update-memory-pipeline.sh → sync_foundation), so
# the unified verb is a thin, discoverable wrapper around it that ALSO emits a
# status + bus event so the run shows up on the dashboard and in Zero's senses.
#
# Syncs, in one idempotent command:
#   • scoped Claude memory + global index
#   • the Obsidian vault (committed + pushed)
#   • graphify graphs
#   • the foundation OS repo (self-map ARCHITECTURE.md + graphify-out, allowlist)
#
# Usage:
#   ops/sync-all.sh                 # full sync (scope: all)
#   ops/sync-all.sh vault           # scope passthrough to the pipeline
#   DRY_RUN=1 ops/sync-all.sh       # show intended actions, no mutations
#
# Exit: always 0 (a sync must never fail a caller); the status line reports
# success/failure per the pipeline's own exit.
# ============================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/os-state.sh
. "$HERE/lib/os-state.sh" 2>/dev/null || true

PIPELINE="$HOME/.claude/scripts/update-memory-pipeline.sh"
SCOPE="${1:-all}"
DRY_RUN="${DRY_RUN:-0}"
TS_START="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

log() { printf '  [sync-all] %s\n' "$*"; }

if [ ! -x "$PIPELINE" ] && [ ! -f "$PIPELINE" ]; then
  log "memory pipeline not found at $PIPELINE — nothing to sync."
  type write_status >/dev/null 2>&1 && \
    write_status "sync-all" "warn" "memory pipeline missing" "{\"pipeline\":\"$PIPELINE\"}"
  exit 0
fi

if [ "$DRY_RUN" = "1" ]; then
  log "DRY_RUN: would run: $PIPELINE $SCOPE  (memory + vault + graphify + foundation)"
  type write_status >/dev/null 2>&1 && \
    write_status "sync-all" "true" "dry-run (no mutations)" "{\"scope\":\"$SCOPE\"}"
  exit 0
fi

log "syncing everything (scope: $SCOPE) — memory + vault + graphify + foundation..."
rc=0
DRY_RUN=0 bash "$PIPELINE" "$SCOPE" 2>&1 | sed 's/^/  [sync-all] /'
rc="${PIPESTATUS[0]:-0}"

if [ "$rc" -eq 0 ]; then
  log "sync complete."
  type write_status >/dev/null 2>&1 && \
    write_status "sync-all" "true" "synced memory + vault + graphify + foundation" \
      "{\"scope\":\"$SCOPE\",\"started\":\"$TS_START\"}"
  type emit_event >/dev/null 2>&1 && \
    emit_event "sync-all" "info" "Synced everything (scope: $SCOPE)" "{\"scope\":\"$SCOPE\"}"
else
  log "sync finished with errors (rc=$rc)."
  type write_status >/dev/null 2>&1 && \
    write_status "sync-all" "warn" "sync ran with errors (rc=$rc)" "{\"scope\":\"$SCOPE\",\"rc\":$rc}"
  type emit_event >/dev/null 2>&1 && \
    emit_event "sync-all" "medium" "Sync ran with errors (rc=$rc)" "{\"scope\":\"$SCOPE\",\"rc\":$rc}"
fi
exit 0
