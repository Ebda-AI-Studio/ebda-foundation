#!/usr/bin/env bash
# ops/fleet-dep-audit.sh — repo/lockfile discovery + failure semantics (issue #197).
#
# The sweep went blind after the 2026-09-25 business-folder layout moved repos 3-5
# levels deep: `find -maxdepth 3 -name package.json` found 0 repos and the script
# would have printed "OK — 0 repos". Every case runs against a throwaway tree, a
# throwaway HOME (state files), fake npm/pnpm shims (no network, never an install)
# and a stub notifier (nothing pages).
set -uo pipefail
OPS="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
_pass=0; _fail=0
pass() { echo "PASS: $1"; _pass=$((_pass+1)); }
fail() { echo "FAIL: $1"; _fail=$((_fail+1)); }

mkdir -p "$T/bin" "$T/home/.claude/scripts"
ln -s "$OPS/lib" "$T/home/.claude/scripts/lib"
# shims: log every invocation; emit a canned audit JSON (override per case via env)
cat > "$T/bin/npm" <<'SH'
#!/usr/bin/env bash
echo "npm $* @ $PWD" >> "$SHIM_LOG"
[ "$1" = audit ] || exit 9
[ -n "${NPM_JSON_FILE:-}" ] && [ -f "$NPM_JSON_FILE" ] && { cat "$NPM_JSON_FILE"; exit 1; }
echo '{"metadata":{"vulnerabilities":{"critical":0,"high":0}},"vulnerabilities":{}}'
SH
cat > "$T/bin/pnpm" <<'SH'
#!/usr/bin/env bash
echo "pnpm $* @ $PWD" >> "$SHIM_LOG"
[ "$1" = audit ] || exit 9
[ -n "${PNPM_JSON_FILE:-}" ] && [ -f "$PNPM_JSON_FILE" ] && { cat "$PNPM_JSON_FILE"; exit 1; }
echo '{"advisories":{},"metadata":{"vulnerabilities":{"critical":0,"high":0}}}'
SH
cat > "$T/bin/notify" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$NOTIFY_LOG"
SH
chmod +x "$T/bin/"*

# run_audit <tree> [script]  -> sets OUT, RC; state in $T/home/.whisky-os-state
run_audit() {
  rm -rf "$T/home/.whisky-os-state"; : > "$T/shim.log"; : > "$T/notify.log"
  OUT=$(HOME="$T/home" FLEET_AUDIT_HERE="$T/home/.claude/scripts" FLEET_AUDIT_ROOT="$1" \
        FLEET_AUDIT_NPM="$T/bin/npm" FLEET_AUDIT_PNPM="$T/bin/pnpm" FLEET_AUDIT_NOTIFY="$T/bin/notify" \
        SHIM_LOG="$T/shim.log" NOTIFY_LOG="$T/notify.log" bash "${2:-$OPS/fleet-dep-audit.sh}" 2>&1); RC=$?
  ST="$T/home/.whisky-os-state/fleet-dep-audit-status.json"
}
field() { python3 -c "import json,sys;d=json.load(open('$ST'));print(eval(sys.argv[1]))" "$1" 2>/dev/null; }
mkrepo() { mkdir -p "$1/.git"; }
lock() { mkdir -p "$(dirname "$1")"; echo '{}' > "$1"; }

# --- 1. depth-5 repo with a space in its path is found and audited -------------
R="$T/t1"
mkrepo "$R/Whisky-11/clients/some client/my repo"; lock "$R/Whisky-11/clients/some client/my repo/package-lock.json"
mkrepo "$R/Personal/projects/plain"; lock "$R/Personal/projects/plain/package-lock.json"
run_audit "$R"
[ "$RC" = 0 ] && [ "$(field "d['detail']['repos']")" = 2 ] && [ "$(field "d['detail']['lockfiles']")" = 2 ] \
  && pass "finds the depth-5 repo with a space in its path (2 repos, 2 lockfiles)" || { fail "depth-5/space discovery: rc=$RC out=$OUT"; }
grep -q "my repo" "$T/shim.log" && pass "the spaced repo was actually audited" || fail "spaced repo never audited: $(cat "$T/shim.log")"
grep -q "npm install\|npm ci\|pnpm install" "$T/shim.log" && fail "audit must never install" || pass "never installs (audit only)"
grep -q -- "--omit=dev --json" "$T/shim.log" && pass "npm audit runs --omit=dev --json" || fail "npm flags: $(cat "$T/shim.log")"

# --- 2. things that are NOT fleet repos are skipped ----------------------------
R="$T/t2"
mkrepo "$R/Ebda-AI-Studio/internal-projects/real"; lock "$R/Ebda-AI-Studio/internal-projects/real/package-lock.json"
mkdir -p "$R/_worktrees/real__feat-x"; echo "gitdir: /x/.git/worktrees/y" > "$R/_worktrees/real__feat-x/.git"; lock "$R/_worktrees/real__feat-x/package-lock.json"
mkdir -p "$R/Ebda-AI-Studio/internal-projects/wt-file"; echo "gitdir: /x" > "$R/Ebda-AI-Studio/internal-projects/wt-file/.git"; lock "$R/Ebda-AI-Studio/internal-projects/wt-file/package-lock.json"
mkrepo "$R/Ebda-AI-Studio/internal-projects/real/build/vendored"; lock "$R/Ebda-AI-Studio/internal-projects/real/build/vendored/package-lock.json"
mkrepo "$R/Ebda-AI-Studio/internal-projects/real/third_party/nested"; lock "$R/Ebda-AI-Studio/internal-projects/real/third_party/nested/package-lock.json"
mkrepo "$R/Ebda-AI-Studio/internal-projects/real/node_modules/dep"; lock "$R/Ebda-AI-Studio/internal-projects/real/node_modules/dep/package-lock.json"
lock "$R/Ebda-AI-Studio/internal-projects/real/.open-next/server-functions/default/package-lock.json"
mkrepo "$R/_archive/dead"; lock "$R/_archive/dead/package-lock.json"
mkrepo "$R/_backups/old"; lock "$R/_backups/old/package-lock.json"
run_audit "$R"
[ "$(field "d['detail']['repos']")" = 1 ] && pass "skips worktrees, .git FILES, build/ + .open-next output + nested checkouts, node_modules, archive, backups (1 repo)" \
  || fail "exclusions: repos=$(field "d['detail']['repos']") out=$OUT"
[ "$(grep -c '' "$T/shim.log")" = 1 ] && pass "exactly the real repo's lockfile audited" || fail "audited: $(cat "$T/shim.log")"

# --- 3. empty tree / no lockfiles = FAILURE + alert ----------------------------
R="$T/t3"; mkdir -p "$R"
run_audit "$R"
okflag=$(python3 -c "import json;print(json.load(open('$ST'))['ok'])" 2>/dev/null)
[ "$RC" = 1 ] && [ "$okflag" = "false" ] && pass "empty tree: exit 1 + status ok=false" || fail "empty tree: rc=$RC ok=$okflag out=$OUT"
echo "$OUT" | grep -q "OK" && fail "empty tree must not print OK: $OUT" || pass "empty tree never prints OK"
[ -s "$T/notify.log" ] && pass "empty tree alerts" || fail "empty tree did not alert"
R="$T/t3b"; mkrepo "$R/Personal/projects/nolock"; echo '{}' > "$R/Personal/projects/nolock/package.json"
run_audit "$R"
okflag=$(python3 -c "import json;print(json.load(open('$ST'))['ok'])" 2>/dev/null)
[ "$RC" = 1 ] && [ "$okflag" = "false" ] && [ -s "$T/notify.log" ] && pass "repos but 0 lockfiles: failure + alert" || fail "0 lockfiles: rc=$RC ok=$okflag"

# --- 4. pnpm repo + sub-dir lockfiles are audited; vulns reported --------------
R="$T/t4"
mkrepo "$R/Whisky-11/clients/c/pn"; lock "$R/Whisky-11/clients/c/pn/pnpm-lock.yaml"
mkrepo "$R/Ebda-AI-Studio/internal-projects/msg"
lock "$R/Ebda-AI-Studio/internal-projects/msg/backend/package-lock.json"; lock "$R/Ebda-AI-Studio/internal-projects/msg/frontend/package-lock.json"
echo '{"advisories":{"1":{"module_name":"lodash","severity":"critical","url":"https://github.com/advisories/GHSA-aaaa-bbbb-cccc"}},"metadata":{"vulnerabilities":{"critical":1,"high":0}}}' > "$T/pn.json"
PNPM_JSON_FILE="$T/pn.json" run_audit "$R"
grep -q "pnpm audit --prod --json @ .*/pn$" "$T/shim.log" && pass "pnpm-lock.yaml repo audited with pnpm audit --prod --json" || fail "pnpm not audited: $(cat "$T/shim.log")"
[ "$(grep -c '^npm audit' "$T/shim.log")" = 2 ] && grep -q "msg/backend" "$T/shim.log" && grep -q "msg/frontend" "$T/shim.log" \
  && pass "sub-dir lockfiles (backend + frontend) each audited" || fail "sub-dir lockfiles: $(cat "$T/shim.log")"
echo "$OUT" | grep -q "lodash (critical)" && [ "$RC" = 0 ] && [ "$(field "d['ok']")" = warn ] \
  && [ "$(field "d['detail']['vuln_repos']")" = 1 ] && pass "pnpm critical reported (status warn, vuln_repos=1, status keys kept)" || fail "pnpm vuln: rc=$RC out=$OUT"
[ -s "$T/notify.log" ] && pass "vulns alert" || fail "vulns did not alert"

# --- 5. every audit erroring is a failure, not a clean sweep -------------------
R="$T/t5"; mkrepo "$R/Personal/projects/x"; lock "$R/Personal/projects/x/package-lock.json"
echo '{"error":{"code":"ENOTFOUND","summary":"registry unreachable"}}' > "$T/err.json"
NPM_JSON_FILE="$T/err.json" run_audit "$R"
[ "$RC" = 1 ] && echo "$OUT" | grep -q "FAILED" && pass "all audits erroring = failure (never a false clean)" || fail "audit errors: rc=$RC out=$OUT"

# --- 6. mutation: the old maxdepth-3 discovery must turn case 1 red ------------
MUT="$T/mutant.sh"; sed 's/-maxdepth 8/-maxdepth 3/' "$OPS/fleet-dep-audit.sh" > "$MUT"
cmp -s "$MUT" "$OPS/fleet-dep-audit.sh" && fail "mutation did not change the script (anchor moved)"
R="$T/t1"; run_audit "$R" "$MUT"
[ "$RC" != 0 ] || [ "$(field "d['detail']['repos']")" != 2 ] && pass "mutation (maxdepth 3) is caught: depth-5 repo goes unseen" || fail "mutant survived — discovery test is vacuous"

# --- 7. the plist must survive install.sh re-bootstrapping ---------------------
P="$OPS/launchd/com.ebda.os.fleet-dep-audit.plist"
grep -q "<key>StartCalendarInterval</key>" "$P" && ! grep -q "<key>StartInterval</key>" "$P" \
  && pass "plist uses StartCalendarInterval (a StartInterval timer resets on every install.sh bootstrap and never fires)" \
  || fail "plist still uses StartInterval"

echo "---"; echo "fleet-dep-audit: $_pass passed, $_fail failed"
[ "$_fail" = 0 ]
