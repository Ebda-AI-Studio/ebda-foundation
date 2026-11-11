#!/usr/bin/env bash
# Daily social content job (launchd social-content): loads OS_BRAIN_URL + INGEST_TOKEN from $OS_SERVICES_ENV (the same source as
# restore-drill.sh) and runs social/social-content.mjs. Pass --dry-run to generate and render without posting.
# Plan: docs/plans/2026-11-11-social-posting.md
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/os-config.sh
. "$HERE/lib/os-config.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-config.sh" 2>/dev/null || true
command -v os_config_load >/dev/null 2>&1 && os_config_load
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin"
if [ -f "${OS_SERVICES_ENV:-}" ]; then
  for _k in OS_BRAIN_URL INGEST_TOKEN; do
    [ -n "${!_k:-}" ] && continue
    _l="$(grep -E "^${_k}=" "$OS_SERVICES_ENV" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"'"'")"
    [ -n "$_l" ] && export "$_k=$_l"
  done
fi
exec node "$HERE/social/social-content.mjs" "$@"
