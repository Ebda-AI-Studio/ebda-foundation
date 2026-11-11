#!/usr/bin/env bash
# Render wrangler.deploy.jsonc from the wrangler.jsonc template + os/config/os.env + ~/.ebda-os.local.env, then deploy.
#   bash os/cloud/brain/scripts/deploy.sh --dry-run    build + validate only, uploads nothing
#   bash os/cloud/brain/scripts/deploy.sh              deploy to the personal Cloudflare account (controller, Task 7)
# Needs (per-machine, never in git; put them in ~/.ebda-os.local.env):
#   OS_CF_ACCOUNT_ID        the personal Cloudflare account id
#   OS_BRAIN_KV_ID          id of the KV namespace created for the brain (README step 2)
#   OS_BRAIN_HOST           the brain's hostname on a zone in that account (custom domain; workers.dev stays off)
# Optional: OS_BRAIN_ACCESS_TEAM_DOMAIN + OS_BRAIN_ACCESS_AUD (until set, /dash/* and /api/* need the Basic Auth secret
#           DASH_BASIC_PASSWORD, and answer 503 without it = fail closed; ruling RR-dash-auth),
#           OS_BRAIN_HEALTH_TARGETS (JSON list, replaces the default health targets),
#           OS_BRAIN_DEPLOYED_REPOS (space/comma list of owner/name; until set no advisory is urgent),
#           OS_BRAIN_<NAME> for each cloud-watcher var in src/env.ts (SERVICE_TARGETS, PAGE_LOAD_TARGETS, JOURNEY_CONFIG,
#           DEPLOY_DRIFT_TARGETS, CF_ACCOUNT_ID, COST_GH_ORG, SENTRY_ORG, SENTRY_PROJECTS, WORLD_NPM_DEPS, ...): copied into vars.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
. "$HERE/../../ops/lib/os-config.sh" && os_config_load
DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1
# F-12: --check = the default-branch rulesets of every repo in the hands config (no deploy, nothing rendered)
[ "${1:-}" = "--check" ] && exec bash "$HERE/scripts/check-rulesets.sh" "${@:2}"
missing=""
for k in OS_CF_ACCOUNT_ID OS_BRAIN_KV_ID OS_BRAIN_HOST; do [ -n "${!k:-}" ] || missing="$missing $k"; done
if [ -n "$missing" ] && [ "$DRY" -eq 0 ]; then echo "deploy: missing$missing (set them in ~/.ebda-os.local.env)" >&2; exit 2; fi
OUT="$HERE/wrangler.deploy.jsonc"
# the orgs the brain watches: OS_BRAIN_ORGS (env / ~/.ebda-os.local.env), else OS_ORGS in os/config/brain-watchers.json, else every
# billed org. The brain's GitHub token is scoped to Ebda-AI-Studio, so the committed value keeps it from 404ing on the other orgs.
_brain_orgs="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("OS_ORGS", ""))' "$HERE/../../config/brain-watchers.json" 2>/dev/null || true)"
_brain_orgs="${OS_BRAIN_ORGS:-${_brain_orgs:-$OS_BILLED_ORGS}}"
OS_BRAIN_KV_ID="${OS_BRAIN_KV_ID:-00000000000000000000000000000000}" \
OS_BRAIN_ORGS="$_brain_orgs" \
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
    # the hands call back on the route host when one is set (reachable from every ISP), else on the custom domain
    "__HANDS_BRAIN_URL__": ("https://" + (os.environ.get("OS_BRAIN_ROUTE_HOST", "").strip() or os.environ["OS_BRAIN_HOST"].strip())) if (os.environ.get("OS_BRAIN_ROUTE_HOST", "").strip() or os.environ.get("OS_BRAIN_HOST", "").strip()) else "__HANDS_BRAIN_URL__",
}
for k, v in sub.items():
    t = t.replace(k, v.replace("\\", "").replace('"', ""))
host = os.environ.get("OS_BRAIN_HOST", "").strip()
if host:
    import re
    if not re.fullmatch(r"[a-z0-9.-]+", host):
        sys.exit("deploy: OS_BRAIN_HOST must be a bare hostname")
    routes = [{"pattern": host, "custom_domain": True}]
    # optional extra Worker route on a zone where a wildcard route would beat a custom domain (e.g. os.ebda.app/* on ebda.app)
    rh, rz = os.environ.get("OS_BRAIN_ROUTE_HOST", "").strip(), os.environ.get("OS_BRAIN_ROUTE_ZONE", "").strip()
    if rh and rz:
        if not re.fullmatch(r"[a-z0-9.-]+", rh) or not re.fullmatch(r"[a-z0-9.-]+", rz):
            sys.exit("deploy: OS_BRAIN_ROUTE_HOST / OS_BRAIN_ROUTE_ZONE must be bare hostnames")
        routes.append({"pattern": rh + "/*", "zone_name": rz})
    t = t.replace('"workers_dev": false,', '"workers_dev": false,\n  "routes": ' + json.dumps(routes) + ',', 1)
# the declared Console spend limit: the committed default (200) unless HANDS_API_SPEND_LIMIT_USD is set in the environment
lim = os.environ.get("HANDS_API_SPEND_LIMIT_USD")
if lim:
    if not lim.replace(".", "", 1).isdigit() or float(lim) <= 0:
        sys.exit("deploy: HANDS_API_SPEND_LIMIT_USD must be a positive number")
    t = t.replace('"HANDS_API_SPEND_LIMIT_USD": "200"', '"HANDS_API_SPEND_LIMIT_USD": "%s"' % lim)
ht = os.environ.get("OS_BRAIN_HEALTH_TARGETS")
if ht:
    json.loads(ht)  # fail loud on a malformed list
    import re
    t = re.sub(r'"HEALTH_TARGETS": "(?:[^"\\]|\\.)*"', '"HEALTH_TARGETS": ' + json.dumps(ht), t)
# cloud watcher vars: OS_BRAIN_<NAME> -> vars.<NAME> (JSON-valued ones are validated; unset ones stay absent = unconfigured)
WATCHER_VARS = ["SERVICE_TARGETS", "PAGE_LOAD_TARGETS", "PAGE_LOAD_P50_MS", "JOURNEY_CONFIG", "DEPLOY_DRIFT_TARGETS",
    "DEPLOY_DRIFT_GRACE_MIN", "PR_SHEPHERD_STALE_HOURS", "CF_ACCOUNT_ID", "CF_WORKERS_PREFIXES", "CF_WORKERS_EXPECTED",
    "CF_WORKER_ERROR_RATE", "COST_GH_ORG", "COST_ACTIONS_WARN_MIN", "COST_ACTIONS_STOP_MIN", "CF_REQUESTS_WARN",
    "CF_REQUESTS_STOP", "SENTRY_ORG", "SENTRY_PROJECTS", "SENTRY_BASE_URL", "DR_DRILL_REPO", "DR_DRILL_STALE_DAYS",
    "WORLD_STATUS_URLS", "WORLD_NPM_DEPS", "HANDS_CONFIG_JSON"]
JSON_VARS = {"SERVICE_TARGETS", "PAGE_LOAD_TARGETS", "JOURNEY_CONFIG", "DEPLOY_DRIFT_TARGETS", "WORLD_STATUS_URLS", "WORLD_NPM_DEPS", "HANDS_CONFIG_JSON"}
# committed defaults (os/config/brain-watchers.json + the hands repo config os/config/hands.ebda.json); the environment wins
cfg_dir = os.path.join(os.path.dirname(src), "..", "..", "config")
committed = {}
wpath = os.path.join(cfg_dir, "brain-watchers.json")
if os.path.exists(wpath):
    committed = {k: (v if isinstance(v, str) else json.dumps(v, separators=(",", ":"))) for k, v in json.load(open(wpath, encoding="utf-8")).items() if not k.startswith("_")}
    committed.pop("OS_ORGS", None)  # rendered through __OS_ORGS__ above, not a watcher var
    unknown = set(committed) - set(WATCHER_VARS)
    if unknown:
        sys.exit("deploy: brain-watchers.json has unknown keys: " + ", ".join(sorted(unknown)))
hpath = os.path.join(cfg_dir, "hands.ebda.json")
if os.path.exists(hpath):
    h = json.load(open(hpath, encoding="utf-8")); h.pop("_comment", None)
    committed["HANDS_CONFIG_JSON"] = json.dumps(h, separators=(",", ":"))
if os.environ.get("OS_CF_ACCOUNT_ID"):
    committed.setdefault("CF_ACCOUNT_ID", os.environ["OS_CF_ACCOUNT_ID"].strip())
extra = ""
for name in WATCHER_VARS:
    val = os.environ.get("OS_BRAIN_" + name) or committed.get(name)
    if not val:
        continue
    if name in JSON_VARS:
        json.loads(val)  # fail loud on a malformed list
    if name == "DR_DRILL_REPO":
        t = t.replace('"DR_DRILL_REPO": "Ebda-AI-Studio/ebda-store"', '"DR_DRILL_REPO": ' + json.dumps(val))
        continue
    extra += "    %s: %s,\n" % (json.dumps(name), json.dumps(val))
if extra:
    t = t.replace('"vars": {\n', '"vars": {\n' + extra, 1)
# Task 7: merge the containers fragment (max_instances 2, instance_type standard-1, the HandsContainer DO + migration) only when asked
if os.environ.get("OS_BRAIN_CONTAINERS") == "1":
    import re as _re
    frag = _re.sub(r"^\s*//.*$", "", open(os.path.join(os.path.dirname(src), "wrangler.containers.jsonc"), encoding="utf-8").read(), flags=_re.M)
    frag = json.loads(_re.sub(r",(\s*[}\]])", r"\1", frag))
    base = json.loads(_re.sub(r",(\s*[}\]])", r"\1", _re.sub(r"^\s*//.*$", "", t, flags=_re.M)))
    base["containers"] = frag["containers"]
    base["durable_objects"] = frag["durable_objects"]
    base["migrations"] = frag["migrations"]
    t = json.dumps(base, indent=2)
open(out, "w", encoding="utf-8").write(t)
PY
grep -q '__ACCESS_AUD__' "$OUT" && echo "deploy: Access not configured yet: /dash/* and /api/* use Basic Auth (secret DASH_BASIC_PASSWORD) and answer 503 without it" >&2
cd "$HERE"
[ -x node_modules/.bin/wrangler ] || { echo "deploy: run npm ci in $HERE first" >&2; exit 2; }
if [ "$DRY" -eq 1 ]; then
  # the placeholder KV id and test values must never survive as a deployable file (a stray `wrangler deploy --config` would use them)
  trap 'rm -f "$OUT"' EXIT
  node_modules/.bin/wrangler deploy --config wrangler.deploy.jsonc --dry-run --outdir dist
  exit $?
fi
export CLOUDFLARE_ACCOUNT_ID="$OS_CF_ACCOUNT_ID"
exec node_modules/.bin/wrangler deploy --config wrangler.deploy.jsonc
