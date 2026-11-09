#!/usr/bin/env bash
# fleet-domains.sh — discover live storefront domains for page-load-monitor.
# Source this file, then call: fleet_domains   (prints "<domain>\t<label>" lines)
# Order of truth: fresh cache (30m TTL) -> platform API -> stale cache -> per-machine fleet JSON.
# Fail-open: any error falls through to the fallback file; never exits non-zero.

# The fleet list is per-machine (never in the repo): ~/.ebda-os.local.json, shape in os/config/fleet.example.json.
# Absent file = empty fleet: callers see no domains and do nothing (exit 0, one log line).
FLEET_STORES_FILE="${FLEET_STORES_FILE:-$HOME/.ebda-os.local.json}"
FLEET_DOMAINS_CACHE="${FLEET_DOMAINS_CACHE:-$HOME/.whisky-os-state/fleet-domains.json}"
FLEET_CACHE_TTL="${FLEET_CACHE_TTL:-1800}"   # seconds

_fleet_emit_from_json() {   # $1 = json file path
  python3 - "$1" <<'PY' 2>/dev/null
import json,sys
try:
    d=json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
for s in d.get("stores",[]):
    dom=s.get("domain"); lab=s.get("label","custom")
    if dom: print(f"{dom}\t{lab}")
PY
}

_fleet_cache_fresh() {
  [ -f "$FLEET_DOMAINS_CACHE" ] || return 1
  local now mtime
  now="$(date +%s)"
  mtime="$(stat -c %Y "$FLEET_DOMAINS_CACHE" 2>/dev/null)" || mtime="$(stat -f %m "$FLEET_DOMAINS_CACHE" 2>/dev/null)"
  [ -n "$mtime" ] && [ "$((now - mtime))" -lt "$FLEET_CACHE_TTL" ]
}

fleet_domains() {
  mkdir -p "$(dirname "$FLEET_DOMAINS_CACHE")" 2>/dev/null || true
  # 1. fresh cache
  if _fleet_cache_fresh; then
    _fleet_emit_from_json "$FLEET_DOMAINS_CACHE" && return 0
  fi
  # 2. platform API (only if creds present)
  if [ -n "${FLEET_STORES_API_URL:-}" ] && [ -n "${FLEET_STORES_API_TOKEN:-}" ]; then
    if curl -fsS -m 15 -H "Authorization: Bearer $FLEET_STORES_API_TOKEN" \
         "$FLEET_STORES_API_URL" -o "$FLEET_DOMAINS_CACHE".tmp 2>/dev/null \
       && _fleet_emit_from_json "$FLEET_DOMAINS_CACHE".tmp >/dev/null 2>&1; then
      mv "$FLEET_DOMAINS_CACHE".tmp "$FLEET_DOMAINS_CACHE"
      _fleet_emit_from_json "$FLEET_DOMAINS_CACHE" && return 0
    fi
    rm -f "$FLEET_DOMAINS_CACHE".tmp 2>/dev/null || true
  fi
  # 3. stale cache (better than nothing)
  if [ -f "$FLEET_DOMAINS_CACHE" ]; then
    _fleet_emit_from_json "$FLEET_DOMAINS_CACHE" && return 0
  fi
  # 4. fallback file — also seed cache so downstream TTL logic works
  if [ ! -f "$FLEET_STORES_FILE" ]; then echo "fleet-domains: no fleet list at $FLEET_STORES_FILE (see os/config/fleet.example.json) - nothing to watch" >&2; return 0; fi
  cp "$FLEET_STORES_FILE" "$FLEET_DOMAINS_CACHE" 2>/dev/null || true
  _fleet_emit_from_json "$FLEET_STORES_FILE"
}
