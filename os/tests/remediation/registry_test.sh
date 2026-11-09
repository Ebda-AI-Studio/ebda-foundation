. "$(dirname "$0")/assert.sh"
. "$(dirname "$0")/../../ops/remediation/registry.sh"
assert_eq "0" "$(is_operational graph-pending; echo $?)"  "graphify is operational"
assert_eq "0" "$(is_operational dr-dump-missing; echo $?)" "dr backup is operational"
assert_eq "1" "$(is_operational lockfile-drift; echo $?)"  "lockfile is NOT operational (gated)"
# idempotence: a repo already in sync -> fix_lockfile_drift is a no-op success, stages nothing
tmp="$(mktemp -d)"; ( cd "$tmp" && git init -q && git config user.email test@example.com && git config user.name test && echo '{"name":"x","version":"1.0.0"}' > package.json && npm i --package-lock-only >/dev/null 2>&1 && git add package.json package-lock.json && git commit -q -m init )
fix_lockfile_drift "$tmp" >/dev/null 2>&1; rc=$?
assert_eq "0" "$rc" "in-sync repo -> fix returns 0"
staged="$(cd "$tmp" && git diff --cached --name-only | wc -l | tr -d ' ')"
assert_eq "0" "$staged" "in-sync repo -> nothing staged (idempotent)"
rm -rf "$tmp"
report
