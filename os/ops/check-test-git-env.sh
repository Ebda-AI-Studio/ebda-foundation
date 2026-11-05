#!/usr/bin/env bash
# check-test-git-env.sh <dir> - guard: every test file that spawns MUTATING git must use the sanitised helper.
# Fails (exit 1, file:line listed) on a test (*.test.*, *.spec.*, or under tests/ __tests__/) that mentions a mutating
# git subcommand but neither imports/sources a git-env helper nor strips GIT_DIR itself. Heuristic by design (a regex
# cannot prove a spawn); the repo's own helper names are matched by GIT_ENV_HELPERS (default below).
# See standard/test-isolation.md.
set -uo pipefail
dir="${1:?usage: check-test-git-env.sh <dir>}"
helpers="${GIT_ENV_HELPERS:-test-git-env|git-env|cleanGitEnv|sandboxGit|sandbox_git|env -u GIT_DIR|unset GIT_DIR|delete (process\\.)?env\\.GIT_DIR}"
mut='git[ "'"'"',]+(-C +[^ ]+ +)?(init|commit|checkout|switch|config|add|reset|worktree|branch|merge|rebase|tag|stash|clone)\b|"(init|commit|checkout)"'
bad=0
while IFS= read -r f; do
  case "$f" in */node_modules/*|*/check-test-git-env.sh|*/test-git-env.sh|*/check-test-git-env.test.sh) continue ;; esac
  grep -Eq "$mut" "$f" || continue
  grep -Eq "$helpers" "$f" && continue
  echo "UNSANITISED git in test: $f"; grep -nE "$mut" "$f" | head -3 | sed 's/^/    /'; bad=1
done < <(find "$dir" -type f \( -name '*.test.*' -o -name '*.spec.*' -o -path '*/tests/*' -o -path '*/__tests__/*' \) \
           -not -path '*/node_modules/*' \( -name '*.sh' -o -name '*.ts' -o -name '*.js' -o -name '*.mjs' -o -name '*.py' \) 2>/dev/null)
[ "$bad" = 0 ] || { echo "check-test-git-env: FAIL - route mutating git through ops/test-git-env.sh (or the repo's equivalent)" >&2; exit 1; }
echo "check-test-git-env: ok"
