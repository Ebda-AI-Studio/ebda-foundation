#!/usr/bin/env bash
# Render wrangler.deploy.jsonc from the wrangler.jsonc template + os/config/os.env + ~/.ebda-os.local.env, then deploy.
#   bash os/cloud/brain/scripts/deploy.sh --dry-run    build + validate only, uploads nothing
#   bash os/cloud/brain/scripts/deploy.sh              deploy to the personal Cloudflare account (controller, Task 7)
# Needs (per-machine, never in git; put them in ~/.ebda-os.local.env):
#   OS_CF_ACCOUNT_ID        the personal Cloudflare account id
#   OS_BRAIN_KV_ID          id of the KV namespace created for the brain (README step 2)
#   OS_BRAIN_HOST           the brain's hostname on a zone in that account (custom domain; workers.dev stays off)
# Optional: OS_BRAIN_ACCESS_TEAM_DOMAIN + OS_BRAIN_ACCESS_AUD (until set, /api/* answers 503 = fail closed),
#           OS_BRAIN_HEALTH_TARGETS (JSON list, replaces the default health targets),
#           OS_BRAIN_DEPLOYED_REPOS (space/comma list of owner/name; until set no advisory is urgent).
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
. "$HERE/../../ops/lib/os-config.sh" && os_config_load
DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1
missing=""
for k in OS_CF_ACCOUNT_ID OS_BRAIN_KV_ID OS_BRAIN_HOST; do [ -n "${!k:-}" ] || missing="$missing $k"; done
if [ -n "$missing" ] && [ "$DRY" -eq 0 ]; then echo "deploy: missing$missing (set them in ~/.ebda-os.local.env)" >&2; exit 2; fi
OUT="$HERE/wrangler.deploy.jsonc"
OS_BRAIN_KV_ID="${OS_BRAIN_KV_ID:-00000000000000000000000000000000}" \
OS_BRAIN_ORGS="$OS_BILLED_ORGS" \
python3 -I - "$HERE/wrangler.jsonc" "$OUT" <<'PY'
import json, os, sys
src, out = sys.argv[1], sys.argv[2]
t = open(src, encoding="utf-8").read()
sub = {
    "__BRAIN_KV_ID__": os.environ["OS_BRAIN_KV_ID"],
    "__OS_ORGS__": os.environ["OS_BRAIN_ORGS"],
    "__DEPLOYED_REPOS__": os.environ.get("OS_BRAIN_DEPLOYED_REPOS") or "__DEPLOYED_REPOS__",
    "__ACCESS_TEAM_DOMAIN__": os.environ.get("OS_BRAIN_ACCESS_TEAM_DOMAIN") or "__ACCESS_TEAM_DOMAIN__",
    "__ACCESS_AUD__": os.environ.get("OS_BRAIN_ACCESS_AUD") or "__ACCESS_AUD__",
    "__HANDS_BRAIN_URL__": ("https://" + os.environ["OS_BRAIN_HOST"].strip()) if os.environ.get("OS_BRAIN_HOST", "").strip() else "__HANDS_BRAIN_URL__",
}
for k, v in sub.items():
    t = t.replace(k, v.replace("\\", "").replace('"', ""))
host = os.environ.get("OS_BRAIN_HOST", "").strip()
if host:
    import re
    if not re.fullmatch(r"[a-z0-9.-]+", host):
        sys.exit("deploy: OS_BRAIN_HOST must be a bare hostname")
    t = t.replace('"workers_dev": false,', '"workers_dev": false,\n  "routes": [{ "pattern": "%s", "custom_domain": true }],' % host, 1)
ht = os.environ.get("OS_BRAIN_HEALTH_TARGETS")
if ht:
    json.loads(ht)  # fail loud on a malformed list
    import re
    t = re.sub(r'"HEALTH_TARGETS": "(?:[^"\\]|\\.)*"', '"HEALTH_TARGETS": ' + json.dumps(ht), t)
open(out, "w", encoding="utf-8").write(t)
PY
grep -q '__ACCESS_AUD__' "$OUT" && echo "deploy: Access not configured yet: /api/* will answer 503 until OS_BRAIN_ACCESS_* are set" >&2
cd "$HERE"
[ -x node_modules/.bin/wrangler ] || { echo "deploy: run npm ci in $HERE first" >&2; exit 2; }
if [ "$DRY" -eq 1 ]; then
  exec node_modules/.bin/wrangler deploy --config wrangler.deploy.jsonc --dry-run --outdir dist
fi
export CLOUDFLARE_ACCOUNT_ID="$OS_CF_ACCOUNT_ID"
exec node_modules/.bin/wrangler deploy --config wrangler.deploy.jsonc
