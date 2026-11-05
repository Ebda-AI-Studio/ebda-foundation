# environments — Environment Isolation Rubric

tags: [BOTH]
sources: PLAYBOOK §11, §16, CLAUDE.md (Production Reality gates 8 & 13), reference-iceberg-audit.md (rules 8, 13; term 28 Environments)

## What "solid" looks like
Local dev and staging never touch prod data. Local points at a scratch/preview DB branch with a verified host; preview/staging points at a staging API + staging DB, never prod; a shared queue broker is namespaced per-environment so staging jobs never run against prod data; and the preview-env isolation is CI-enforced, not assumed.

## Criteria
| # | Criterion | Solid (grade 2) | Gap detection | Severity |
|---|---|---|---|---|
| 1 | Local dev DB is not prod | `.env`/`.env.local` `DATABASE_URL` host points at a scratch/preview branch, never the prod host | grep `.env*` for `DATABASE_URL`; confirm the host is NOT the prod DB host before any `migrate`/`db push` | Critical |
| 2 | Local runs as app role, not owner | Local `DATABASE_URL` uses the app role (so RLS is exercised locally), not the owner role | grep `.env*` `DATABASE_URL` for the owner role name (e.g. `neondb_owner`); flag if local connects as owner | High |
| 3 | Preview/staging points at staging, not prod | Preview/staging env vars resolve to staging API + staging DB host, never the prod host | `vercel env ls --json` (Preview scope) — confirm `DATABASE_URL`/API base host ≠ prod host | Critical |
| 4 | CI-enforced preview isolation | A CI step asserts the preview env is isolated from prod (rule 13) | grep `.github/workflows/*` for a `vercel env ls --json` isolation check; flag if absent | High |
| 5 | Queue prefix on shared broker | Every staging service sets `QUEUE_PREFIX=<project>-staging` when staging + prod share a queue broker | grep staging service config/env for `QUEUE_PREFIX`; flag if shared broker and no per-env prefix | Critical |
| 6 | Host verified before migrate | The DB host in `.env` is checked before running `migrate`/`db push` (no prod schema mutation from local) | confirm a pre-migrate host guard or documented check exists in scripts/runbook for `migrate`/`db push` | High |
| 7 | local/staging never touch prod (release gate) | Production-ready checklist asserts "local/staging never touch prod" and snapshot+rollback rehearsed | grep release/`docs/*` checklist for a "local/staging never touch prod" line | Medium |

## Evidence (filled during audit, per repo)
- FWB: …
- WBS: …
