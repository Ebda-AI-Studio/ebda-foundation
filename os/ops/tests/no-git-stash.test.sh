#!/usr/bin/env bash
# The stash stack is shared by every worktree and session: a script that pushes or pops it can take another session's entry.
# No script in os/ops may run `git stash` to push/save/pop/apply (or bare). Reading the vault's own orphan lint-staged entries
# (stash list / drop in update-memory-pipeline.sh) is the one allowed use; tests and hooks/block-stash-pop.sh (the deny
# guard itself, which must name the commands it blocks) are exempt.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
hits="$(grep -rnE "git[[:space:]]+stash([[:space:]]+(push|pop|apply|save)|[[:space:]]*(\$|[;&|)\"'\`]))" . 2>/dev/null \
  | grep -vE '^\./(tests/|hooks/block-stash-pop\.sh:)' | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#')"
if [ -n "$hits" ]; then echo "FAIL: git stash push/pop in os/ops:"; echo "$hits"; exit 1; fi
echo "PASS: no git stash push/pop/apply/save anywhere in os/ops"
