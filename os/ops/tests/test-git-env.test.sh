#!/usr/bin/env bash
# test-git-env: reproduce the 2026-10-25 incident (hook-exported GIT_DIR turns a test `git init` into a mutation of
# the REAL repo) and prove the helper + guard stop it.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; OPS="$HERE/.."
pass=0; fail=0
ok(){ if [ "$2" = "$3" ]; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1 - got '$2' want '$3'"; fail=$((fail+1)); fi; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
. "$OPS/test-git-env.sh"
REAL="$TMP/real"; mkdir -p "$REAL"; git -C "$REAL" init -q; git -C "$REAL" config user.email a@example.invalid; git -C "$REAL" config user.name a
git -C "$REAL" commit -q --allow-empty -m base
SB="$TMP/sandbox"
hookenv() { GIT_DIR="$REAL/.git" GIT_WORK_TREE="$REAL" "$@"; }

# 1. the bug: with the hook's env, a plain `git init` + commit in a temp dir hits the REAL repo
( mkdir -p "$TMP/naive" && cd "$TMP/naive" && GIT_DIR="$REAL/.git" GIT_WORK_TREE="$REAL" git config core.bare true ) >/dev/null 2>&1
ok "precondition: inherited GIT_DIR really mutates the real repo" "$(git -C "$REAL" config core.bare)" "true"
git -C "$REAL" config core.bare false

# 2. the helper under the same env leaves the real repo alone
hookenv bash -c ". '$OPS/test-git-env.sh'; sandbox_git_init '$SB' && sandbox_git '$SB' commit -q --allow-empty -m sbx && sandbox_git '$SB' checkout -q -b other"
ok "helper under hook env: real repo core.bare untouched" "$(git -C "$REAL" config core.bare)" "false"
ok "helper: real repo still one commit" "$(git -C "$REAL" rev-list --count HEAD)" "1"
ok "helper: real repo has no stray branch" "$(git -C "$REAL" branch --list other | wc -l | tr -d ' ')" "0"
ok "helper: sandbox got its own commits" "$(git -C "$SB" rev-list --count HEAD)" "1"
ok "helper: sandbox branch exists" "$(git -C "$SB" rev-parse --abbrev-ref HEAD)" "other"

# 3. sandbox_git refuses a dir that is not its own toplevel (a plain subdir of the real repo)
mkdir -p "$REAL/sub"; sandbox_git "$REAL/sub" status >/dev/null 2>&1; ok "sandbox_git refuses a non-toplevel dir" "$?" "1"

# 4. run mode strips GIT_* for a child
ok "run mode: child sees no GIT_DIR" "$(GIT_DIR=/x bash "$OPS/test-git-env.sh" -- sh -c 'echo ${GIT_DIR:-none}')" "none"

# 5. the guard: flags a test spawning mutating git without the helper, passes the sanitised one
G="$TMP/g"; mkdir -p "$G/tests"
printf 'import { execFileSync } from "node:child_process";\nexecFileSync("git", ["init"]);\n' > "$G/tests/bad.test.ts"
bash "$OPS/check-test-git-env.sh" "$G" >/dev/null 2>&1; ok "guard fails an unsanitised git test" "$?" "1"
printf 'import { initSandboxRepo } from "./helpers/git-env";\nexecFileSync("git", ["init"]);\n' > "$G/tests/bad.test.ts"
bash "$OPS/check-test-git-env.sh" "$G" >/dev/null 2>&1; ok "guard passes when the helper is used" "$?" "0"
printf 'git init x\n' > "$G/tests/plain.test.sh"
bash "$OPS/check-test-git-env.sh" "$G" >/dev/null 2>&1; ok "guard fails a bare shell test" "$?" "1"
echo "---"; echo "test-git-env: $pass passed, $fail failed"; [ "$fail" = 0 ]
