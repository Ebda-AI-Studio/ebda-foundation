# common-test-files — the shared test-infra every repo (and every worktree) must always keep

tags: [BOTH]
sources: memory/feedback-test-truncate-wiped-prod-db.md (🔴 P0 prod wipe), CLAUDE.md (Rule 14 — five testing layers), standard/testing.md, standard/worktree-lifecycle.md

## What "solid" looks like

There is a small set of **common test-infra files** that every Force repo depends on and that EVERY worktree inherits by virtue of branching off `main`. They are not feature code — they are the safety rails the test suite runs on. The canonical one is the **destructive-reset prod-guard**: the check that refuses to `TRUNCATE`/`deleteMany`/`db push --force-reset` unless the target DB is provably a disposable localhost/test container. Its ABSENCE in an earlier messaging product let a local `npm test` wipe the **production** managed Postgres DB (0 users → every login 401). a previous storefront product survived the identical risk only because it already had `guardNotProd()` — **the guard lived in one repo and was never propagated**. That is the whole lesson: a guard that exists in one repo and not the others is a latent P0.

So the rule is twofold:

1. **Keep them always.** These files must exist on `main` of every repo, therefore in every worktree. A worktree teardown (`post-merge-cleanup.sh` gate 4) confirms their presence and never removes them.
2. **Propagate them.** When the registry gains a file (or a repo is found missing one), open it across every applicable repo via `ops/propagate.sh` — the foundation's job is to audit + propagate the guard, not assume each repo grew its own.

## The registry (must exist where the test stack applies)

| File / glob | Purpose | Applies to |
|---|---|---|
| `tests/setup*.ts` · `tests/setup*.js` | jest/vitest global setup; usually hosts the prod-guard call | every repo with a test suite |
| `tests/integration/setup.ts` | integration-layer setup + the destructive-reset prod-guard | every repo with integration tests (real DB) |
| `tests/helpers/prod-guard.*` · `tests/**/guard*.*` | the `guardNotProd()` / host-allowlist guard itself | every repo that runs destructive resets |
| `jest.setup.*` / `vitest.setup.*` | timer/Prisma teardown discipline (clear intervals, `$disconnect`) | per test runner |

The guard's invariant (from the an earlier messaging product fix): a destructive reset runs **only if** the DB host is `localhost`/`postgres` OR the db-name matches `test` **AND** the host is NOT a managed provider (`managed-db`/`railway`/`supabase`/`aws`). Anything else → throw before touching data.

## Criteria

| # | Criterion | Solid (grade 2) | Gap detection | Severity |
|---|---|---|---|---|
| 1 | Prod-guard present | every repo running a destructive test-reset has a guard that throws unless the DB is a disposable localhost/test container | grep the reset path (`TRUNCATE`/`deleteMany`/`--force-reset`) for a preceding host/db-name guard | Critical |
| 2 | Guard covers managed providers | guard explicitly rejects `managed-db`/`railway`/`supabase`/`aws` hosts even if the name looks test-ish | read the guard predicate | Critical |
| 3 | Present in every repo (propagated) | the guard + shared setup exist across ALL Force repos, not just the one it was born in | `ops/propagate.sh <src> <guard-path>` dry-run shows no applicable-but-missing repo | High |
| 4 | Survives worktree teardown | `post-merge-cleanup.sh` gate 4 confirms a common test file exists on the parent checkout before/after teardown | run teardown; gate-4 warning fires if a guard is missing | High |
| 6 | A declared runner reaches EVERY suite | one entry point (`ops/run-tests.sh`, an npm `test` script, a Makefile target) discovers every suite CLASS in the repo, and a class that discovers **zero** suites fails the run | list every suite location (`find . -name '*.test.*' -o -name 'test_*'`), then read the runner's globs. Any location not covered is run by nothing. On the foundation this was 13 of 38 suites — including one that had been RED for weeks | High |
| 5 | Teardown discipline intact | module-level `setInterval`/`setTimeout` cleared + Prisma singletons `$disconnect`ed in setup, so Jest doesn't hang past timeout | grep setup files for clear/`$disconnect` | Medium |

## The registry is shape-aware (2026-09-04)

The registry above is jest/vitest/Prisma-shaped, which is correct for the product
repos and **wrong for a repo whose test stack is bash + node-ESM + python**. On
`ebda-foundation` — 38 suites, no database — none of those globs can ever match, so
`post-merge-cleanup.sh` gate 4 warned on every teardown about a prod-guard that is
genuinely N/A there, while the actual gap went unmentioned: **13 suites reachable from
nothing, one of them failing** (`state-aggregator`, asserting a subsystem count of 15
against an actual 34, stale because nothing ran it).

Two rules follow.

1. **Match the rule to the repo's shape.** Where there is no destructive reset, the
   prod-guard is N/A and criterion 6 is the applicable one — the failure mode is not a
   wiped database, it is a suite nobody runs.
2. **A gate reports what it observed; it does not diagnose what it cannot see.** The first
   attempt at making gate 4 shape-aware tried to grep for destructiveness and produced
   three false-positive classes on its first run: it matched **its own pattern definition**
   (the `pgrep -f` self-match shape), the word *TRUNCATED* in prose and docstrings, and
   **SQL-injection test fixtures** (`"'; DROP TABLE users; --"`) — which are the opposite of
   a destructive path. It now states what it found and names what would settle the rest.
   A gate that accuses every repo is worth less than no gate
   (`feedback-monitor-alert-measures-the-monitor`).

## Standing rule

Before tearing down a worktree, and during any cross-repo audit, verify the registry. If a repo is missing a guard, **fix and propagate in the same pass** (`ops/propagate.sh`), never silently. "Invalid credentials for everyone / empty table" → COUNT rows first; a wiped table masquerades as an auth/RLS bug (see memory/feedback-test-truncate-wiped-prod-db.md).
