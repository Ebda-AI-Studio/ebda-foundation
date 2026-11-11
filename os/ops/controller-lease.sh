#!/usr/bin/env bash
# Ebda AI OS - controller-lease.sh   (launch-map row HANDS-COORD)
#
# A controller (a Claude session, or Ahmad) that is about to work in a repo takes a lease on it in the brain. While the lease is
# live the brain hands no job for that repo to the hands, and the hands re-check it before touching the repo. Leases expire on
# their own (max 240 min), so a crashed session never freezes the hands for longer than that; renew by claiming again.
#
#   controller-lease.sh claim   <owner/name> [ttl-min] [note]   exit 0 = held by you, 4 = held by another controller
#   controller-lease.sh release <owner/name>                    exit 0 = released (or was not yours)
# Holder = $OS_CONTROLLER_ID, else "<user>@<host>:<CLAUDE_SESSION_ID or pid>". Brain + token: OS_BRAIN_URL + INGEST_TOKEN from the
# environment or $OS_SERVICES_ENV (never git). Brain unreachable or not configured: exit 10 (the hands fail closed on their side).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/os-config.sh
. "$HERE/lib/os-config.sh" 2>/dev/null && os_config_load 2>/dev/null || true
if [ -f "${OS_SERVICES_ENV:-}" ]; then
  for _k in OS_BRAIN_URL INGEST_TOKEN; do
    [ -n "${!_k:-}" ] && continue
    _l="$(grep -E "^${_k}=" "$OS_SERVICES_ENV" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"'"'")"
    [ -n "$_l" ] && export "$_k=$_l"
  done
fi
verb="${1:-}"; repo="${2:-}"
case "$verb" in claim|release) ;; *) sed -n 2,12p "$0" | sed 's/^# \{0,1\}//'; exit 2 ;; esac
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "controller-lease: repo must be owner/name" >&2; exit 2; }
if [ -z "${OS_BRAIN_URL:-}" ] || [ -z "${INGEST_TOKEN:-}" ]; then echo "controller-lease: OS_BRAIN_URL / INGEST_TOKEN not set (services env)" >&2; exit 10; fi
holder="${OS_CONTROLLER_ID:-$(id -un)@$(hostname -s):${CLAUDE_SESSION_ID:-$$}}"
holder="$(printf '%s' "$holder" | tr -c 'A-Za-z0-9_.@:-' '-' | cut -c1-100)"
body="$(python3 -I -c 'import json,sys; a=sys.argv; d={"repo":a[1],"holder":a[2]}
if a[3]: d["ttlMin"]=int(a[3])
if a[4]: d["note"]=a[4][:200]
print(json.dumps(d))' "$repo" "$holder" "${3:-}" "${4:-}")" || { echo "controller-lease: ttl must be a number" >&2; exit 2; }
method=POST; [ "$verb" = release ] && method=DELETE
bf="$(mktemp)"; trap 'rm -f "$bf"' EXIT; printf '%s' "$body" > "$bf"
out="$(curl -sS -m 15 -o - -w '\n%{http_code}' -X "$method" -H "Authorization: Bearer $INGEST_TOKEN" -H 'content-type: application/json' --data-binary "@$bf" "${OS_BRAIN_URL%/}/leases" 2>&1)" || { echo "controller-lease: brain unreachable" >&2; exit 10; }
code="$(printf '%s' "$out" | tail -1)"; resp="$(printf '%s' "$out" | sed '$d')"
echo "controller-lease: $verb $repo as $holder -> $code $resp"
case "$code" in 200) exit 0 ;; 409) exit 4 ;; *) exit 10 ;; esac
