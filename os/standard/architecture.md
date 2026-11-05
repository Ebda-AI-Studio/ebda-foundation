# architecture — Architecture & Stack Decisions Rubric

tags: [BOTH]
sources: PLAYBOOK §2 (architecture decisions), §3.3 (money + transactions), reference-iceberg-audit.md (term 1: architecture)

## What "solid" looks like
A monorepo with shared types/Zod across API + frontends as one source of truth for contracts; the day-1 stack decisions locked (Express/TS API, Next.js App Router per-app frontends, Prisma+Postgres on Neon, Redis cache, Inngest/BullMQ async, custom-JWT-in-cookies auth, Railway/Vercel deploy); all money handled as integers in the smallest unit through one centralized, tested helper module; Prisma transactions wrapped with explicit maxWait/timeout.

## Criteria
| # | Criterion | Solid (grade 2) | Gap detection | Severity |
|---|---|---|---|---|
| 1 | Monorepo workspace shape | npm workspaces with `apps/{api,admin,web}` + `packages/{database,shared,ui,config}`; shared types/Zod live in a package both API and frontends import | check root `package.json` for a `workspaces` key; check that `apps/` and `packages/` dirs exist; grep frontends for an import from the shared/types package | High |
| 2 | API framework decision locked | Express (or NestJS) + TypeScript with explicit middleware chains | file-exists `apps/api/package.json`; grep its deps for `"express"` or `"@nestjs/core"` and `"typescript"` | Medium |
| 3 | Per-app Next.js frontends | Admin + storefront are separate Next.js App Router apps (per-app auth + deploy) | file-exists `apps/admin/app/` and `apps/web/app/` (App Router dirs); grep each `package.json` for `"next"` | Medium |
| 4 | ORM + DB decision locked | Prisma + Postgres (Neon), migrations as committed SQL, pooled + direct URLs | file-exists `packages/database/prisma/schema.prisma`; confirm a `prisma/migrations/` dir with committed `.sql`; grep `.env`/schema for both pooled and `DIRECT_URL` | Medium |
| 5 | Cache layer decision | Redis two-tier (Redis → in-memory bounded map → CDN s-maxage), TTL floor ≥120s | grep deps for `"ioredis"`/`"redis"`; grep cache module for a TTL constant ≥120 | Medium |
| 6 | Async/jobs decision | Inngest (or BullMQ) for anything >300ms or 3rd-party | grep deps for `"inngest"` or `"bullmq"`; confirm a job/functions dir exists | Medium |
| 7 | Money stored as integer minor units | All amounts are integers in smallest unit (fils/cents), never floats | grep Prisma schema for money fields typed `Float`/`Decimal` instead of `Int` (e.g. `price\s+Float`); grep code for `parseFloat`/`* 100` on money paths | Critical |
| 8 | Centralized money helper | One `money.ts`/`discount.ts` module with unit tests (round, clamp, apply); no ad-hoc money math elsewhere | file-exists a single `money.ts`/`discount.ts` helper + a matching `*.test.ts`; grep for inline money arithmetic outside that module | High |
| 9 | Transaction maxWait wrapper | Every `prisma.$transaction` passes `{maxWait:10000, timeout:30000}` (via a `withMoneyTx` wrapper), not the 2s default | grep for `\$transaction(` calls and confirm a `maxWait`/`timeout` option or a shared `withMoneyTx` wrapper; flag bare `$transaction(` with no options object | High |
| 10 | Deterministic findFirst ordering | Any `findFirst` with an `OR` that can match multiple rows has an explicit `orderBy` | grep for `findFirst(` blocks containing `OR:` and lacking `orderBy:` | Medium |

## Evidence (filled during audit, per repo)
- a previous storefront product: …
- an earlier messaging product: …
