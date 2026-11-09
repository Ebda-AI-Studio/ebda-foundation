# testing — Testing Layers & CI Gating Rubric

tags: [BOTH]
sources: PLAYBOOK §5 (five testing layers) + §6 (CI/CD standard), CLAUDE.md (rule 14 — five testing layers; rule 15 — Jest/Prisma teardown discipline), reference-iceberg-audit.md (term 31: test coverage)

## What "solid" looks like
All five testing layers present for every revenue/PII/operations path — unit + integration + E2E in CI as hard gates (integration NOT `continue-on-error`), load (k6) with a documented p95 ceiling, and a per-feature UAT checklist; Jest/vitest + Prisma teardown discipline so CI doesn't hang; every CI job has a timeout and Prisma generate runs before typecheck. No feature ships to a paying customer without all five green for the touched paths.

## Criteria
| # | Criterion | Solid (grade 2) | Gap detection | Severity |
|---|---|---|---|---|
| 1 | Unit layer is a CI hard gate | vitest/jest unit job runs in CI, blocking, completes <10s on mocked deps | grep `.github/workflows/*.yml` for a `unit`/`test` job; confirm it is NOT `continue-on-error: true` | High |
| 2 | Integration layer on real DB, blocking | Real DB + service + API integration job runs in CI as a hard gate, not `continue-on-error` | grep workflow yml for an `integration` job; grep that job block for `continue-on-error: true` (must be absent) | Critical |
| 3 | Integration test isolation | `TRUNCATE ... RESTART IDENTITY CASCADE` in `beforeAll` for every table the tests write to | grep test files for `TRUNCATE` + `RESTART IDENTITY CASCADE` in `beforeAll`/setup | High |
| 4 | E2E/automation runs on every PR | Playwright golden-path flows run in CI on every PR, not just locally | file-exists `playwright.config.*` + grep workflows for an `e2e` job triggered on `pull_request` | High |
| 5 | Load layer with documented p95 | k6 script present + a documented p95 ceiling; p95>500ms fixed before ship | file-exists k6 script (`*.js`/`*.ts` referencing `k6`); grep docs for a p95 ceiling statement | Medium |
| 6 | UAT checklist per feature | `docs/uat/<feature>.md` with golden-path + edge-case steps | file-exists `docs/uat/*.md` | Medium |
| 7 | Prisma teardown discipline | Every Prisma singleton `$disconnect()` in teardown; no `--forceExit` masking leaks | grep test setup for `$disconnect()` in `afterAll`/`globalTeardown`; grep jest config/scripts for `--forceExit` (must be absent) | High |
| 8 | Timer teardown discipline | Every module-level `setInterval`/`setTimeout` exported + cleared in `afterAll` | grep source for `setInterval(`/`setTimeout(`; confirm a matching `clearInterval`/`clearTimeout` in `afterAll`/`jest.setup` | Medium |
| 9 | testTimeout for managed Postgres cold starts | `testTimeout: 30000` configured so managed Postgres cold starts don't false-fail | grep jest/vitest config for `testTimeout` set to 30000 | Medium |
| 10 | Every CI job has a timeout | `timeout-minutes` on EVERY job (lint=5, typecheck=10, build=15, unit=10, integration=15, e2e=20, audit=5) | grep workflow yml jobs for `timeout-minutes:`; flag any job lacking it | High |
| 11 | Prisma generate before typecheck | `db:generate`/`prisma generate` step runs before the typecheck step in CI | grep workflow yml: confirm `prisma generate`/`db:generate` precedes the typecheck/`tsc` step | High |
| 12 | Pre-push hook mirrors CI subset | Pre-push hook runs lockfile drift + prisma generate + lint + typecheck + unit before push | file-exists `.husky/pre-push` (or `.git/hooks/pre-push`); grep it for lint + typecheck + unit invocations | Medium |
| 13 | Destructive-reset prod-guard | Every `TRUNCATE`/`deleteMany`/`db push --force-reset` is preceded by a guard that throws unless the DB is a disposable localhost/test container (rejects managed-db/railway/supabase/aws). Present in EVERY repo, not just where it was born — see `common-test-files.md` | grep the reset path for a preceding host/db-name guard; `ops/propagate.sh` shows no applicable-but-missing repo | Critical |
| 14 | Test doubles never reimplement the logic under test | Any fake standing in for a query engine, provider or protocol is a thin transport, not a reimplementation; behaviour that must be verified runs against a REAL engine (e.g. a `node:sqlite` adapter for D1, kept outside `src/`) | Read the fake: if it branches on the same inputs the production code branches on, it can only confirm itself. Probe: mutate the real statement without changing the fake's dispatch key — a green suite is the finding | Critical |
| 15 | Coverage is measured across a seam, not on one side of it | Both halves of an injected-dependency seam are exercised — the pure builders AND the `main()`/wiring half that calls them | Coverage report per file, not per package: a well-covered helper module beside a 0%-covered entry point is the signature. On one build this hid a `--dry-run` path printing a customer's email to stdout | High |
| 16 | No gate's evidence is a SKIP | Every CI-gating test can actually execute on a CI runner; a test requiring an interactive login, a cloud credential or a GUI is either made runnable in-process or is explicitly NOT counted as a gate | grep CI logs for `skipped`/`pending` on any job named as a gate. A test that can only skip proves nothing, and reads as green forever | High |

## Evidence (filled during audit, per repo)
- a previous storefront product: …
- an earlier messaging product: …
