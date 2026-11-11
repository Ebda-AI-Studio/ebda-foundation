# Force AI Foundation — Fleet Readiness Sweep (2026-06-08)

A fleet-wide production-readiness sweep across every project in the Force AI portfolio, plus the two deep-audited flagships (force-website-builder, whatsapp-bulk-sender). Grades are out of 2.0. Tier A = production SaaS handling money / PII / multi-tenant ops; Tier B = DB-backed marketing sites with admin CMS; Tier C = personal / local-only tooling; spec = design-only, no shippable code.

## Company rollup

| project | tier | grade /2 | live? | #criticals | top gap |
|---|---|---|---|---|---|
| indibat-platform | A | 0.70 | No (local build only) | 4 | Broken admin authorization — any student can self-promote to admin (privilege escalation) |
| whatsapp-bulk-sender | A | 0.79 | Yes (deep-audited) | 3 | CRITICAL RLS + billing + prod-env-in-local |
| force-website-builder | A | 1.05 | Yes (flagship, deep-audited) | 0 | Only observability = 2 (otherwise clean) |
| om-hassan-menu | A | 1.10 | Yes (Vercel) | 3 | Local .env.local points at prod Neon DB; no CI; zero tests |
| digital-card | A | 1.50 | Yes (Vercel) | 2 | CI on main is RED (Vercel-env gate hard-fails); observability = 0 |
| Force_media_CRM | A | 1.70 | Yes (Vercel) | 0 | Observability = 0 (no Sentry / uptime / log drain) |
| al_assriya_landing | B | 1.60 | Yes (alassriya.com) | 3 | Prod Neon URL + weak JWT secret in local .env.local; ephemeral upload storage breaks CMS images |
| code_tech_landing_page | B | 1.50 | Vercel-linked (live unconfirmed) | 2 | Broken anon-insert RLS (NEW.email in WITH CHECK); no CI |
| force_media_landing_page | B | 2.00 | Yes (forcemediakw.com) | 0 | No tests / no E2E smoke; no uptime monitor or failure alerting |
| Force Media AI Media Buyer | C | 1.50 | Self-hosted (Docker, no PaaS) | 0 | Money-mutation idempotency unproven; no RLS (service-role everywhere) |
| beethoven | C | 1.30 | No | 0 | Hardcoded `admin123` password fallback; fully in-memory state |
| alex_uni | C | 1.00 | No | 2 | Hardcoded client-side credentials; impersonates a real university portal (phishing shape) |
| legende_hm_calc | C | 1.00 | Yes (legendehm.net) | 2 | Security rests entirely on unverified Supabase RLS; not under version control |
| mypovonai | C | 2.00 | No (local-only) | 0 | Local SQLite DB not in any off-machine backup set |
| whisky-wallpaper | C | 2.00 | No (GitHub Releases) | 0 | No CI; self-signed distribution (Gatekeeper friction) |
| ComfyUI | C | 2.00 | No (local desktop) | 0 | Local user state (workflows/db) not backed up |
| rvc-training | C | 1.60 | No (local CLI) | 0 | Ahmad's training edits/model run unbacked; origin = unpushable upstream |
| voice-converter | C | 2.00 | No (local ML) | 0 | Trained model weights gitignored with no documented backup |
| whisky-claude | C | 2.00 | No (GitHub Releases) | 0 | No CI; ad-hoc self-signed releases (no notarization) |
| classifieds-marketplace | spec | 0.00 | No (spec only) | 0 | No application code — docs only |
| wedding_zone_landingpage | spec | 0.00 | Partial (unrelated proposal page) | 0 | Named product unbuilt; only deployed file is mislabeled scope |
| gcc-horse-market | spec | 0.00 | No (spec only) | 0 | One 116-line design doc, no scaffold |
| learning-app-brainstorm | spec | 0.00 | No (spec only) | 0 | No source code, not even committed to git |

## Tier A scorecard — the production SaaS

The Tier-A tier is the company's real exposure: anything that handles money, PII, or multi-tenant operations. Worst grade first.

### indibat-platform — 0.70 (NOT live; local build only)
Arabic/RTL learning platform (Supabase + Tap Payments KWD + Bunny.net video). Handles money and PII. Most dangerous codebase in the fleet despite not being deployed — every critical is a real exploit.
- **Broken admin authorization (privilege escalation):** every admin Server Action in `src/lib/actions/admin-users.ts` uses the RLS-bypassing service-role client with ZERO caller auth check. `changeUserRole(id,'admin')` (line 277) lets ANY authenticated student self-promote to admin; `deleteUser` (327), `resetUserPassword` (223), `changeUserEmail` (239), `grantCourseAccess` (339) equally exposed. The admin layout role check guards page rendering only, not the directly-POST-invokable actions.
- **Content-access bypass (paid-video leak):** `src/app/api/videos/sign/route.ts:6-30` signs ANY videoId for ANY logged-in user, with no purchase/grant check. Free-tier students can stream any paid course video by enumerating videoIds.
- **Tap webhook — no idempotency:** `src/app/api/webhooks/tap/route.ts:6-30` re-fetches the charge from Tap (blocks status-spoofing) but has no processed-marker, so Tap's normal retries re-increment coupon `current_uses` (line 107) and re-send confirmation emails.
- **Dependency audit fails the zero-tolerance gate:** `npm audit` = 37 vulns (22 moderate, 15 high). Rules 1/10 require 0/0/0/0.

### whatsapp-bulk-sender — 0.79 (live; deep-audited)
- CRITICAL RLS gap (tenant isolation), billing integrity, and prod-env-in-local — per the prior deep audit.

### force-website-builder — 1.05 (live; flagship, deep-audited)
- No criticals. The flagship is the cleanest deep-audited project; the only standing weakness is observability = 2.

### om-hassan-menu — 1.10 (live on Vercel)
Single-tenant bilingual QR menu — no cart, no payments, no PII. Criticals are deploy-safety / standards, not security holes.
- **Local `.env.local` points at the PROD-serving Neon DB** with live creds (pooled neondb URL, live NEON_API_KEY, ADMIN_JWT_SECRET/ADMIN_PASSWORD_HASH) — single Neon branch, so local `prisma migrate dev` mutates production schema. Not a leak, a real deploy-safety hazard.
- **Retired neon-snapshot.yml still active** — creates a `prod-<sha>` branch on every push to main; should be `gh workflow disable`d per the 2026-06-08 cost retirement.
- (PASS, listed for evidence) No committed secrets — git history scan for the Neon password and NEON_API_KEY returns nothing; only `.env.example` is tracked.

### digital-card — 1.50 (live on Vercel)
Single-admin bilingual digital business-card site. No money handling.
- **CI on main is RED** (run 26339142485, exit 22) — the custom rule-13 Vercel-env gate's `curl -sf` hit an HTTP error (expired/invalid VERCEL_TOKEN) and the job exits before tsc/lint/unit/e2e/build run, so the green suite is NOT validating main. Live Vercel deploy is ahead of a red, unattended pipeline.
- (PASS) No secret/RLS/money criticals — `.env.local` is gitignored, never in history, and points at a Neon PREVIEW branch (not prod). Single-admin, so multi-tenant RLS is N/A.

### Force_media_CRM — 1.70 (live on Vercel)
Single-tenant internal agency CRM (Next.js 16 + Prisma + Neon + NextAuth v5). No payments. Highest-graded live Tier-A project.
- **No criticals.** Top gaps are observability = 0 (no Sentry, no uptime monitor, no log drain), dead rate-limiter (`src/lib/rate-limit.ts` is implemented + unit-tested but imported by ZERO live routes — login and Groq AI endpoints are unthrottled), and docs drift (DEPLOYMENT.md still leads with Netlify while the app is Vercel). `google-credentials.json` holds a real service-account key on disk (gitignored, never in history) — rotate to a secrets manager.

## Critical findings across the fleet

Every critical from every project, grouped by class, worst first.

### Tenant isolation / authorization (worst class — direct exploits)
- **indibat-platform — privilege escalation:** any authenticated student can call `changeUserRole(self,'admin')` via a directly-invokable Server Action; same path exposes user deletion, password reset, email change, and course-access grants. (`src/lib/actions/admin-users.ts`)
- **indibat-platform — paid-content bypass:** `videos/sign` signs any videoId for any logged-in user; enumerate IDs to stream paid courses for free.
- **indibat-platform — RLS not the runtime boundary:** RLS policies exist (migration 002) but nearly all server reads/writes use `createServiceClient()`, bypassing RLS — auth must be re-asserted in app code and for admin actions it currently isn't.
- **whatsapp-bulk-sender — CRITICAL RLS gap** (tenant isolation), per deep audit.
- **code_tech_landing_page — broken anon-insert RLS:** `001_initial_schema.sql:63-69` uses `NEW.email` inside a WITH CHECK clause (NEW is trigger-only, invalid in RLS) — errors at runtime and likely blocks all anonymous lead submissions (availability bug, not a hole). Admin auth is purely client-side, so the entire security model rests on RLS being correct on every table.
- **legende_hm_calc — client-side-only role gating:** `admin.js` reads role from `user_profiles` via the anon client; the real boundary is Supabase RLS, which is NOT in the repo and is unverified. If RLS is missing, the anon key can read/write those tables directly.
- **Force Media AI Media Buyer — no RLS, service-role everywhere:** single-tenant today (acceptable), but zero isolation the moment a second client's ad accounts share the DB — flagged so it isn't reused as a multi-tenant base.

### Auth / credentials
- **alex_uni — hardcoded client-side credentials** (`index.html:484-485`, student code + password compared in-browser) gating a page styled as a real Alexandria University portal — phishing-template shape; client-side auth is no auth. Should never be deployed under that branding.
- **beethoven — hardcoded `admin123` fallback** (`server.js:13`): if `ADMIN_PASSWORD` is unset in prod, admin/next/reset are open. Should fail-fast, not default.

### Prod environment in local files (deploy-safety, not commit leaks)
- **whatsapp-bulk-sender — prod env in local**, per deep audit.
- **om-hassan-menu — `.env.local` → prod-serving Neon DB** + live NEON_API_KEY + admin secrets; local migrations mutate prod schema.
- **al_assriya_landing — live PROD Neon pooler URL + plaintext weak JWT_SECRET** (`.env.local:1-2`, short/low-entropy, the prod token-signing key) on a dev `.env.local`. Local-only so not a commit leak, but treat as exposed and rotate.

### Money integrity
- **indibat-platform — webhook double-processing + non-atomic writes:** coupon `current_uses` increment is a read-then-write race (`route.ts:104-108`) with no row lock; create-charge inserts purchase + payment in separate non-transactional writes (no atomic tx / P2034 retry); webhook swallows all errors with a 200 + console.error so failed payments are silently lost.
- **whatsapp-bulk-sender — billing integrity** critical, per deep audit.
- **Force Media AI Media Buyer — unproven money-mutation safety:** the action executor changes real ad budgets / pauses campaigns with no committed test, no visible dry-run gate, and unproven idempotency on API retries — a redelivery could double-apply a budget change.

### Secrets — verified-clean evidence (PASS, no leak)
- **om-hassan-menu, digital-card, al_assriya_landing, code_tech_landing_page, legende_hm_calc, force-media-CRM:** no committed secrets — history scans return nothing; only public-by-design Supabase anon keys are exposed where present. The recurring real risk is prod creds sitting on disk in local `.env.local`, not in git.

## Readiness verdict

- **As a company, web is uneven but anchored by strong flagships.** The two deep-audited production SaaS (force-website-builder 1.05, whatsapp-bulk-sender 0.79) plus the live internal tools (Force_media_CRM 1.70, force_media_landing_page 2.00) show the Force AI standard is real where it's been applied. The fleet-wide pattern of weakness is consistent and fixable: observability = 0 on almost every live project (no Sentry, no uptime monitor, no log drain), retired neon-snapshot workflows still enabled, and prod creds living in local `.env.local` files.

- **indibat-platform is the single most dangerous codebase and must not ship as-is.** It is the lowest-graded Tier-A project (0.70) and the only one with live, trivially-exploitable holes: any student can self-promote to admin, any user can stream paid video, the Tap webhook double-processes on normal retries, and `npm audit` is 37 vulns. It is not deployed yet — that is the only thing protecting it. Treat the four criticals as launch-blockers before any deploy wiring is added.

- **whatsapp-bulk-sender is live AND carries critical RLS + billing gaps** — it is the highest-risk *deployed* project (0.79, real customers, multi-tenant, money). It should sit at the top of the remediation queue ahead of indibat precisely because it is already in production.

- **The genuinely fine projects:** force_media_landing_page, mypovonai, and the local Tier-C dev tools (whisky-wallpaper, whisky-claude, ComfyUI, voice-converter) score 2.0 with no criticals — their only gaps are backup/CI hygiene appropriate to their tier. The four spec-only repos (classifieds-marketplace, gcc-horse-market, learning-app-brainstorm, wedding_zone) carry no risk because no code exists; the standing rule for them is to apply the mobile guards + Kuwait Law 13/2023 PDPL erasure the moment scaffolding begins.
