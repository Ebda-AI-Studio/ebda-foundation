#!/usr/bin/env bash
# Turn a short-lived Graph Explorer USER token into never-expiring PAGE tokens for the brand Pages and store them as the brain secret
# SOCIAL_FACEBOOK ({"ebda":{"pageId","pageToken"},"whisky11":{...}}), plus a Keychain copy. Nothing secret is printed or put in argv.
# Doc: os/ops/social-meta-token.md. Plan: docs/plans/2026-11-11-social-posting.md section 9.
#
#   1. copy the App Secret (developers.facebook.com > the app > App settings > Basic)   then: bash social-meta-token.sh --save-app-secret
#   2. copy the User Token from Graph Explorer                                           then: bash social-meta-token.sh
#   (input = the clipboard; add --stdin to pipe it instead)
# Options: --dry-run (exchange + verify, store nothing). Env: META_APP_ID (default the Ebda AI Studio Social app), META_GRAPH_VERSION
# (v27.0), SOCIAL_FB_PAGE_EBDA / SOCIAL_FB_PAGE_WHISKY11 (page ids, when the Page names do not contain "ebda" / "whisky").
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/os-config.sh
. "$HERE/lib/os-config.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-config.sh" 2>/dev/null || true
command -v os_config_load >/dev/null 2>&1 && os_config_load
APP_ID="${META_APP_ID:-1733132125094316}"
V="${META_GRAPH_VERSION:-v27.0}"
KC_APP=ebda-os-meta-app-secret
KC_OUT=ebda-os-social-facebook
WORKER="${OS_BRAIN_WORKER:-ebda-os-brain}"
WRANGLER_VER=4.152.0

# default = the clipboard (`! cmd` in Claude Code has no usable stdin); --stdin reads stdin instead
FROM_STDIN=0
for a in "$@"; do [ "$a" = --stdin ] && FROM_STDIN=1; done
read_input() { if [ "$FROM_STDIN" = 1 ]; then cat; else pbpaste; fi | tr -d '[:space:]'; }
kc_put() { # service, value on stdin; `security -i` keeps the value out of argv / ps
  local v; v="$(cat)"
  printf 'add-generic-password -U -a ebda-os -s %s -w "%s"\n' "$1" "$v" | security -i >/dev/null
}
die() { echo "social-meta-token: $*" >&2; exit 1; }

if [ "${1:-}" = "--save-app-secret" ]; then
  s="$(read_input)"
  [[ "$s" =~ ^[0-9a-f]{32}$ ]] || die "the clipboard does not hold a 32-hex App Secret (copy it from App settings > Basic)"
  printf '%s' "$s" | kc_put "$KC_APP"
  echo "social-meta-token: App Secret stored in Keychain ($KC_APP). Now copy the Graph Explorer user token and run without --save-app-secret."
  command -v pbcopy >/dev/null && printf '' | pbcopy
  exit 0
fi
DRY=0; for a in "$@"; do [ "$a" = --dry-run ] && DRY=1; done

SECRET="$(security find-generic-password -s "$KC_APP" -w 2>/dev/null)" || die "no App Secret in Keychain: run with --save-app-secret first"
SHORT="$(read_input)"
[[ "$SHORT" =~ ^EAA[A-Za-z0-9]{40,}$ ]] || die "the clipboard does not hold a Graph Explorer user token (starts with EAA)"
command -v pbcopy >/dev/null && printf '' | pbcopy   # do not leave the token on the clipboard

# every Graph request goes through curl's config on stdin (below), so tokens and the secret never appear in argv
OUT="$(SHORT="$SHORT" SECRET="$SECRET" APP_ID="$APP_ID" V="$V" PE="${SOCIAL_FB_PAGE_EBDA:-}" PW="${SOCIAL_FB_PAGE_WHISKY11:-}" \
  python3 -I - <<'PY'
import json, os, subprocess, sys, urllib.parse
V, APP = os.environ["V"], os.environ["APP_ID"]
def graph(path, params):
    q = urllib.parse.urlencode(params)
    cfg = f'url = "https://graph.facebook.com/{V}/{path}?{q}"\nsilent\nshow-error\nmax-time = 30\n'
    r = subprocess.run(["curl", "-K", "-"], input=cfg, capture_output=True, text=True)
    try:
        j = json.loads(r.stdout or "{}")
    except ValueError:
        sys.exit(f"social-meta-token: non-JSON answer from {path} (curl rc {r.returncode})")
    if "error" in j:
        e = j["error"]
        sys.exit(f"social-meta-token: {path}: Meta error {e.get('code')}: {e.get('message','')[:200]}")
    return j
app_token = f"{APP}|{os.environ['SECRET']}"
long = graph("oauth/access_token", {"grant_type": "fb_exchange_token", "client_id": APP, "client_secret": os.environ["SECRET"], "fb_exchange_token": os.environ["SHORT"]})["access_token"]
pages = graph("me/accounts", {"fields": "id,name,access_token,tasks", "limit": "100", "access_token": long}).get("data", [])
if not pages:
    sys.exit("social-meta-token: the token sees no Pages: in Graph Explorer, Get User Access Token again and tick BOTH Pages")
want = {"ebda": os.environ.get("PE") or None, "whisky11": os.environ.get("PW") or None}
match = {"ebda": "ebda", "whisky11": "whisky"}
out, report = {}, []
for brand in ("ebda", "whisky11"):
    cands = [p for p in pages if p["id"] == want[brand]] if want[brand] else [p for p in pages if match[brand] in p["name"].lower()]
    if len(cands) != 1:
        report.append(f"{brand}: {'no' if not cands else 'more than one'} matching Page (seen: {', '.join(p['name'] for p in pages)}); set SOCIAL_FB_PAGE_{brand.upper()}=<page id>")
        continue
    p = cands[0]
    d = graph("debug_token", {"input_token": p["access_token"], "access_token": app_token})["data"]
    scopes = set(d.get("scopes", []))
    problems = []
    if not d.get("is_valid"): problems.append("token not valid")
    if d.get("expires_at", -1) != 0: problems.append(f"expires_at={d.get('expires_at')} (want 0 = never)")
    if "pages_manage_posts" not in scopes: problems.append("missing pages_manage_posts")
    if "CREATE_CONTENT" not in (p.get("tasks") or []): problems.append("you lack CREATE_CONTENT on this Page")
    if problems:
        report.append(f"{brand}: {p['name']} ({p['id']}): " + "; ".join(problems)); continue
    out[brand] = {"pageId": p["id"], "pageToken": p["access_token"]}
    feed = "yes" if "pages_read_user_content" in scopes else "NO (Instagram-share spacing + digest feed read stay off)"
    report.append(f"{brand}: {p['name']} ({p['id']}): OK, never expires; feed read: {feed}")
print(json.dumps({"secret": out, "report": report}))
PY
)" || exit 1

python3 -I -c 'import json,sys; [print("  "+l) for l in json.load(sys.stdin)["report"]]' <<<"$OUT"
SECRET_JSON="$(python3 -I -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["secret"]))' <<<"$OUT")"
n="$(python3 -I -c 'import json,sys; print(len(json.loads(sys.stdin.read())))' <<<"$SECRET_JSON")"
[ "$n" -ge 1 ] || die "no Page passed the checks: nothing stored"
[ "$n" -eq 2 ] || echo "social-meta-token: only $n of 2 Pages passed; storing those (fix the other and re-run)" >&2
if [ "$DRY" -eq 1 ]; then echo "social-meta-token: dry run, nothing stored"; exit 0; fi

# Keychain copy is base64 (security -i cannot take the JSON quotes); read back: security find-generic-password -s $KC_OUT -w | base64 -d
printf '%s' "$SECRET_JSON" | base64 | tr -d '\n' | kc_put "$KC_OUT"
[ -n "${OS_CF_ACCOUNT_ID:-}" ] && export CLOUDFLARE_ACCOUNT_ID="$OS_CF_ACCOUNT_ID"
printf '%s' "$SECRET_JSON" | npx --yes "wrangler@$WRANGLER_VER" secret put SOCIAL_FACEBOOK --name "$WORKER" >/dev/null \
  || die "wrangler secret put failed (the Keychain copy $KC_OUT is saved; retry: security find-generic-password -s $KC_OUT -w | base64 -d | npx wrangler secret put SOCIAL_FACEBOOK --name $WORKER)"
echo "social-meta-token: SOCIAL_FACEBOOK stored on $WORKER ($n Page(s)) and in Keychain ($KC_OUT)."
