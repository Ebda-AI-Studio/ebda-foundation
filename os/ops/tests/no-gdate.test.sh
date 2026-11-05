#!/usr/bin/env bash
# No OS script may depend on GNU `gdate` (Homebrew/MacPorts coreutils): it is not
# on the launchd PATH, so behaviour depended on who launched the job (#197,
# auto-fix-check.sh). Also pins that the replacement parses a UTC stamp as UTC.
set -uo pipefail
cd "$(dirname "$0")/.."; OPS="$(pwd)"
_pass=0; _fail=0
pass() { echo "PASS: $1"; _pass=$((_pass+1)); }
fail() { echo "FAIL: $1"; _fail=$((_fail+1)); }

# non-comment, non-fix-launchd-path uses of gdate
scan() { grep -nE '(^|[^A-Za-z_#-])gdate\b' "$@" 2>/dev/null | grep -vE '^[^:]*:[0-9]+:[[:space:]]*#' ; }
hits="$(scan "$OPS"/*.sh "$OPS"/lib/*.sh | grep -v 'fix-launchd-path.sh' || true)"
[ -z "$hits" ] && pass "no ops script invokes gdate" || fail "gdate still referenced: $hits"

# the epoch expression used by auto-fix-check.sh
expr_line="$(grep -n 'RUN_EPOCH=\$(TZ=UTC /bin/date' "$OPS/auto-fix-check.sh" | head -1)"
[ -n "$expr_line" ] && pass "auto-fix-check parses createdAt with TZ=UTC /bin/date (no \$DATE indirection)" || fail "UTC-pinned date expression missing"
STAMP="2026-10-03T12:00:00Z"
want="$(python3 -c "import datetime;print(int(datetime.datetime(2026,10,3,12,tzinfo=datetime.timezone.utc).timestamp()))")"
got="$(PATH=/usr/bin:/bin CREATED="$STAMP" bash -c 'TZ=UTC /bin/date -j -f "%Y-%m-%dT%H:%M:%SZ" "$CREATED" +%s 2>/dev/null || date -d "$CREATED" +%s')"
got_tz="$(PATH=/usr/bin:/bin TZ=Asia/Tokyo CREATED="$STAMP" bash -c 'TZ=UTC /bin/date -j -f "%Y-%m-%dT%H:%M:%SZ" "$CREATED" +%s 2>/dev/null || date -d "$CREATED" +%s')"
[ "$got" = "$want" ] && [ "$got_tz" = "$want" ] && pass "UTC stamp -> correct epoch with a minimal PATH, any local TZ" || fail "epoch got=$got got_tz=$got_tz want=$want"

echo "== MUTATION CHECK =="
M="$(mktemp -d)/auto-fix-check.sh"; { cat "$OPS/auto-fix-check.sh"; echo 'DATE=$(command -v gdate || echo date)'; } > "$M"
[ -n "$(scan "$M")" ] && pass "mutation (gdate reintroduced) is caught by the scan" || fail "MUTATION survived"
rm -rf "$(dirname "$M")"
echo; echo "no-gdate.test: $_pass passed, $_fail failed"; [ "$_fail" -eq 0 ]
