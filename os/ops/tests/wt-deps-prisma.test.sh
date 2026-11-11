#!/usr/bin/env bash
# wt-deps.sh must leave a repo with a prisma schema holding a GENERATED client, never the ~2 KB placeholder `npm ci` leaves
# (2026-11-11: a poisoned cache entry made ebda-store customer-auth-backup.test.ts fail with "reading 'isDecimal'").
# A fake `npm` stands in for the installer: `npm ci` writes a STUB client, `npm run db:generate` writes a REAL-sized one.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; OPS="$HERE/.."
pass=0; fail=0
ok(){ if [ "$2" = "$3" ]; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1 - got '$2' want '$3'"; fail=$((fail+1)); fi; }
TMP="$(mktemp -d "$HOME/.wt-deps-prisma-test.XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
export WT_DEPS_CACHE="$TMP/cache"
mkdir -p "$TMP/bin"
cat > "$TMP/bin/npm" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_NPM_LOG"
case "$1" in
  ci) mkdir -p node_modules/.prisma/client node_modules/pkg; head -c 2000 /dev/zero | tr '\0' x > node_modules/.prisma/client/index.d.ts ;;
  run) [ "$2" = db:generate ] && { mkdir -p node_modules/.prisma/client; head -c 50000 /dev/zero | tr '\0' x > node_modules/.prisma/client/index.d.ts; } ;;
esac
exit 0
FAKE
chmod +x "$TMP/bin/npm"; export FAKE_NPM_LOG="$TMP/npm.log"; : > "$FAKE_NPM_LOG"
export PATH="$TMP/bin:$PATH"
R="$TMP/repo"; mkdir -p "$R/packages/database/prisma"
git -C "$R" init -q -b main; git -C "$R" config user.email t@example.invalid; git -C "$R" config user.name t
echo '{"name":"demo","scripts":{"db:generate":"prisma generate"}}' > "$R/package.json"; echo '{"lockfileVersion":3}' > "$R/package-lock.json"
echo 'model A { id Int @id }' > "$R/packages/database/prisma/schema.prisma"
git -C "$R" add -A; git -C "$R" commit -q -m init
size(){ wc -c < "$1/node_modules/.prisma/client/index.d.ts" | tr -d ' '; }
big(){ [ "$(size "$1")" -ge 10000 ] && echo yes || echo no; }
mkwt(){ git -C "$R" worktree add -q "$TMP/$1" -b "$1" >/dev/null 2>&1; echo "$TMP/$1"; }

# 1. cache MISS: install, generate, snapshot -> the entry itself holds a real client
W1="$(mkwt w1)"; bash "$OPS/wt-deps.sh" "$W1" >"$TMP/o1" 2>&1
ok "miss: worktree has a generated client" "$(big "$W1")" "yes"
ENTRY="$(ls -d "$WT_DEPS_CACHE"/*/*/ | head -1)"
ok "miss: the cached snapshot holds the generated client" "$([ "$(wc -c < "$ENTRY/tree/node_modules/.prisma/client/index.d.ts")" -ge 10000 ] && echo yes || echo no)" "yes"

# 2. a POISONED entry (stub client, as built before this fix): clone, then the clone is repaired in the worktree
head -c 2000 /dev/zero | tr '\0' x > "$ENTRY/tree/node_modules/.prisma/client/index.d.ts"
: > "$FAKE_NPM_LOG"
W2="$(mkwt w2)"; bash "$OPS/wt-deps.sh" "$W2" >"$TMP/o2" 2>&1
ok "poisoned entry: clone is repaired with db:generate" "$(big "$W2")" "yes"
ok "poisoned entry: no npm ci ran (clone, not install)" "$(grep -c '^ci' "$FAKE_NPM_LOG")" "0"
ok "poisoned entry: db:generate ran once" "$(grep -c '^run db:generate' "$FAKE_NPM_LOG")" "1"

# 3. a good client is left alone
: > "$FAKE_NPM_LOG"; W3="$(mkwt w3)"; bash "$OPS/wt-deps.sh" "$W3" >"$TMP/o3" 2>&1
ok "a second clone of the still-poisoned entry is repaired again (per clone)" "$(grep -c 'db:generate' "$FAKE_NPM_LOG")" "1"

# 4. REFRESH rebuilds the entry through the script's own path
: > "$FAKE_NPM_LOG"; W4="$(mkwt w4)"; WT_DEPS_REFRESH=1 bash "$OPS/wt-deps.sh" "$W4" >"$TMP/o4" 2>&1
ok "refresh: ran a fresh install + generate" "$(grep -c '^ci' "$FAKE_NPM_LOG")/$(grep -c 'db:generate' "$FAKE_NPM_LOG")" "1/1"
ok "refresh: entry now holds a real client" "$([ "$(wc -c < "$ENTRY/tree/node_modules/.prisma/client/index.d.ts")" -ge 10000 ] && echo yes || echo no)" "yes"
: > "$FAKE_NPM_LOG"; W5="$(mkwt w5)"; bash "$OPS/wt-deps.sh" "$W5" >"$TMP/o5" 2>&1
ok "after refresh a clone needs no generate" "$(grep -c 'db:generate' "$FAKE_NPM_LOG")" "0"
ok "after refresh the clone is real" "$(big "$W5")" "yes"

# 5. a repo with no prisma schema never runs generate
R2="$TMP/repo2"; mkdir -p "$R2"; git -C "$R2" init -q -b main; git -C "$R2" config user.email t@example.invalid; git -C "$R2" config user.name t
echo '{"name":"plain","scripts":{"db:generate":"x"}}' > "$R2/package.json"; echo '{"lockfileVersion":3}' > "$R2/package-lock.json"
git -C "$R2" add -A; git -C "$R2" commit -q -m init
: > "$FAKE_NPM_LOG"; bash "$OPS/wt-deps.sh" "$R2" >"$TMP/o6" 2>&1
ok "no schema.prisma: db:generate never runs" "$(grep -c 'db:generate' "$FAKE_NPM_LOG")" "0"
echo "---"; echo "wt-deps-prisma: $pass passed, $fail failed"; [ "$fail" = 0 ]
