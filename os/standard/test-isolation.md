# test-isolation - a test must not be able to reach the real repo, whatever env it inherits

tags: [BOTH]
sources: `feedback-hook-exported-git-dir-turns-a-test-git-init-into-a-repo-mutation`, `ci-merge-gates-never-merge-on-no-checks`

**Incident (2026-10-25, ebda-store).** A new test did `git init` + commits + `checkout` in a `mkdtemp` dir. By hand it
passed. Under the husky **pre-push hook**, git exports `GIT_DIR`, `GIT_WORK_TREE` and `GIT_INDEX_FILE` into every child,
`execFileSync`/`spawnSync` inherit them, and **`cwd` / `git -C` do not override `GIT_DIR`**. The test re-initialised the real
repository and set `core.bare=true` for 20-40 minutes: the root checkout failed with "this operation must be run in a
work tree", a stray commit landed on the feature branch, extra branches appeared, and unrelated sibling tests went red
("0 tracked files"). The symptom is far from the cause and invisible outside a hook.

**The rule:** *any test that runs a MUTATING git command (init, commit, checkout, switch, config, add, reset, worktree,
branch, merge, rebase, tag, stash, clone) runs it through a sanitised environment.*

**Tradeoff:** one import per test file; a second helper to keep in step with the repo's own language.

## The helper - `ops/test-git-env.sh` (repo-agnostic, for shell tests)
Source it (`. ~/.claude/scripts/test-git-env.sh`) for `clean_git_env`, `sandbox_git_init <dir>`, `sandbox_git <dir> <args>`; or
run `test-git-env.sh -- <cmd>`. It strips every `GIT_*` variable, sets `GIT_CONFIG_GLOBAL=/dev/null`,
`GIT_CONFIG_NOSYSTEM=1`, disables commit signing, and **re-asserts that the sandbox dir is its own git toplevel on every call** (refuses otherwise).
JS/TS repos keep a twin in-repo (ebda-store: `tests/helpers/git-env.ts` -> `initSandboxRepo()`, `sandboxGit()`, `cleanGitEnv()`); a twin must do the same three things.

## The guard - `ops/check-test-git-env.sh <dir>`
Fails (names file:line) any test file that mentions a mutating git subcommand but neither uses a git-env helper nor strips
`GIT_DIR` itself. Heuristic by design - it catches the forgotten import, not a determined bypass; ebda-store's version
is `tests/unit/no-unsanitised-git-in-tests.test.ts` (self-tested on good/bad snippets, mutation-checked). Run it in each repo's unit job.

## Prove a git-touching test the way the hook runs it
`GIT_DIR=$(git rev-parse --absolute-git-dir) GIT_WORK_TREE=$PWD GIT_INDEX_FILE=... <test command>`, then assert HEAD,
`core.bare` and the branch list of the real repo are unchanged. `ops/tests/test-git-env.test.sh` does exactly this (it reproduces the bug first).

## Fixtures that look like secrets
A committed fake key fails the secret scanner for every PR that touches that branch's history (`merge-gate.md`). Build
such fixtures at runtime (`"AKIA" + "IOSFODNN7EXAMPLE"`), never as literals.

## Grading
| # | Criterion | Check | Severity |
|---|---|---|---|
| 1 | Git-mutating tests use a sanitised env | `check-test-git-env.sh <repo>` exits 0 | High |
| 2 | The helper survives the hook env | `ops/tests/test-git-env.test.sh` passes | High |
| 3 | Secret-looking fixtures are runtime-built | `gitleaks detect` on the tree is clean without allowlisting fixtures | Medium |
