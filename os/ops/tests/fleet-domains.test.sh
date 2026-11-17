#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export FLEET_DOMAINS_CACHE="$TMP/cache.json"
export FLEET_STORES_FILE="$TMP/fallback.json"
printf '{"stores":[{"domain":"a.example","label":"custom"},{"domain":"b.example","label":"subdomain"}]}' > "$FLEET_STORES_FILE"
unset FLEET_STORES_API_TOKEN

. ./lib/fleet-domains.sh
out="$(fleet_domains)"
grep -qx "$(printf 'a.example\tcustom')" <<<"$out" || { echo "FAIL: a.example missing"; exit 1; }
grep -qx "$(printf 'b.example\tsubdomain')" <<<"$out" || { echo "FAIL: b.example missing"; exit 1; }
[ -f "$FLEET_DOMAINS_CACHE" ] || { echo "FAIL: cache not written"; exit 1; }
echo "PASS fleet-domains fallback"
