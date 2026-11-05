# docs-parity — Documentation Parity Rubric

tags: [BOTH]
sources: PLAYBOOK §12 (documentation parity), §8 (log retention documented), §4 (SCALING.md), §10 (ROLLBACK.md), §16; CLAUDE.md (documentation-parity rule + docs/contract-parity audit); reference-iceberg-audit.md (term 38: Documentation)

## What "solid" looks like
Every feature ships with ALL relevant docs (README, DEPLOYMENT, runbooks, architecture, merchant/client-facing, plan docs) updated in the SAME session — local AND pushed — and the docs reflect reality. Pricing/plan/feature docs are generated FROM the runtime gating code (code is the source of truth), the four operational docs (DEPLOYMENT log-retention, SCALING, ROLLBACK) exist, and the live contract/quote templates are checked against the plan-feature matrix every release.

## Criteria
| # | Criterion | Solid (grade 2) | Gap detection | Severity |
|---|---|---|---|---|
| 1 | Core docs exist | `README.md` + `docs/DEPLOYMENT.md` present in the repo | file-exists check for `README.md` and `docs/DEPLOYMENT.md` | High |
| 2 | Plan-feature matrix generated from code | `docs/business/plan-feature-matrix.md` exists and is derived from the runtime gating code (e.g. `plan-baselines.ts` + `features.ts`), not hand-authored | file-exists check for `docs/business/plan-feature-matrix.md` AND `packages/shared/src/plan-baselines.ts`; grep matrix for plan keys absent from `plan-baselines.ts` | High |
| 3 | Log retention documented in DEPLOYMENT | DEPLOYMENT.md states the verified log-drain retention window (≥30 days), not assumed | grep `docs/DEPLOYMENT.md` for a retention statement (`retention`/`30-day`/`30 days`) | Medium |
| 4 | SCALING runbook present | `docs/SCALING.md` documents replica prerequisites + dashboard steps + post-scale watch items | file-exists check for `docs/SCALING.md` | Medium |
| 5 | ROLLBACK runbook present | `docs/ROLLBACK.md` documents recovery paths | file-exists check for `docs/ROLLBACK.md` | High |
| 6 | Plan docs for big changes | Multi-file/feature work has a written plan in `docs/plans/` (or `docs/superpowers/plans/`) | file-exists check that `docs/plans/` or `docs/superpowers/plans/` contains `*.md` | Medium |
| 7 | UAT checklist per feature | Each revenue/PII/ops feature has `docs/uat/<feature>.md` with golden-path + edge-case steps | file-exists check that `docs/uat/` contains per-feature `*.md` | Medium |
| 8 | Contract/quote parity gate | `docs/business/CONTRACT-CHECKLIST.md` exists and the live bilingual HTML templates (the business assets folder) are verified against the plan-feature matrix | file-exists check for `docs/business/CONTRACT-CHECKLIST.md`; grep the asset HTML for self-serve/free-trial language (`free trial`/`30-day trial`/`signup`) that contradicts the managed-agency model | High |
| 9 | No stale-stack drift in README/ROADMAP | README/ROADMAP name the actual stack | grep `README.md` + `ROADMAP.md` for known-stale tokens (`Stripe`, `Claude`, `Next 14`/`Next.js 14`) that contradict the real stack (the project's real payment gateways / model provider / framework major) | Medium |

## Evidence (filled during audit, per repo)
- a previous storefront product: …
- an earlier messaging product: …
