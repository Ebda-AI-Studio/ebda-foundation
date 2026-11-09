#!/usr/bin/env bash
# reverify <kind> <target-json> -> 0 still-true (act), 1 resolved (drop). Authoritative stale defense.
set -uo pipefail
_f() { printf '%s' "$2" | python3 -c 'import json,sys;print(json.load(sys.stdin).get(sys.argv[1],""))' "$1"; }
kind="$1"; t="$2"
SD="${WHISKY_STATE_DIR:-$HOME/.whisky-os-state}"
case "$kind" in
  ci-failure)
    slug="$(_f slug "$t")"; sha="$(_f sha "$t")"
    r="$(gh api "repos/$slug/commits/$sha/check-runs" --jq 'any(.check_runs[]?; .conclusion=="failure" or .conclusion=="timed_out")' 2>/dev/null)"
    [ "$r" = "true" ] && exit 0 || exit 1 ;;
  code-finding)
    id="$(_f id "$t")"; [ -n "$id" ] || exit 1
    python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));a=d.get("findings",[]) if isinstance(d,dict) else d;sys.exit(0 if any((x.get("id")==sys.argv[2]) for x in a) else 1)' "$SD/dream-findings.json" "$id" 2>/dev/null ;;
  service-down)
    url="$(_f url "$t")"; [ -n "$url" ] || exit 0
    curl -fsS -m 8 "$url" >/dev/null 2>&1 && exit 1 || exit 0 ;;   # probe ok now -> resolved
  runner-offline)
    exit 0 ;;   # conservatively still act; runner-restore is idempotent
  # Fail-CLOSED on unrecognized kinds: an event type added without an explicit
  # verify case must NOT be acted on unverified. Each new kind opts in above.
  *) exit 1 ;;
esac
