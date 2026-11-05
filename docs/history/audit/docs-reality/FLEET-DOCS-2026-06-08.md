# Fleet Docs-Reality Scan (2026-06-08)

## Rollup

| project | overall | #drift | claimed stack | real stack | worst item |
|---|---|---|---|---|---|
| force-website-builder | STALE | 15 | Express 4 + Next 16 + Neon/Prisma (51 models) + Redis + R2 + Socket.io + Vitest (332+) · Vercel Pro $20/mo + Railway + Neon Launch · DR via per-commit Neon snapshots | Express 4 + Next 16 + Neon/Prisma (83 models) + Redis + R2 + Socket.io + Vitest · Vercel Hobby + Railway Hobby · DR via daily local pg_dump · dual-stack push (VAPID+OneSignal), Inngest, Resend, Sentry+Axiom+PostHog | DEPLOYMENT.md §2 Cloudflare Pages + §4 Supabase setup sections fully describe a deploy target/DB that no longer exist (real = Vercel + Neon) |
| Force_media_CRM | STALE | 18 | Next 16 + Neon/Prisma 6 + NextAuth v5 + Web Push (VAPID) + Groq + Netlify (serverless) + next-pwa SW | Next 16 + Neon/Prisma 6 + NextAuth v5 + OneSignal (react-onesignal v3 + REST) + Groq + Vercel (vercel.json crons) + OneSignal-managed SW (no next-pwa) | README + DEPLOYMENT recommend Netlify as the deploy target; real platform is Vercel (vercel.json, `vercel --prod`) |
| om-hassan-menu | STALE | 11 | Next 16 + Tailwind v4 — pure static menu, no DB/auth/payments. Data in lib/menu.ts (19 cat/108 items) | Next 16 + Tailwind v4 + Prisma 7 + Neon + Vercel Blob + jose (JWT). DB-backed admin panel, scrypt auth. 20 cat/108 items, Vercel Blob images | README "No DB, no auth — pure menu" tagline is wrong: full Neon/Prisma 7 + JWT admin + Blob storage exists |
| digital-card | STALE | 7 | Static Next 16, content-as-code in data/cards/*.ts, photos in public/photos/, no DB/auth | Next 16 + ISR + Prisma 7 + Neon + Vercel Blob + scrypt+JWT admin CRUD, jose, Zod | README "Adding a card" instructs editing data/cards/*.ts + public/photos/ — both directories were deleted in v2; cards now via /admin panel |
| force_media_landing_page | STALE | 13 | USER_GUIDE: pure static HTML, no backend/DB, localStorage-only, save by downloading HTML | Vanilla HTML/CSS/JS + Vercel Serverless Functions + Neon Postgres (14+ tables, admin_sessions) + Cloudinary CDN, server-side session tokens | USER_GUIDE claims "no database or server, all changes in localStorage" — reality is a full Neon-backed CMS with 14 tables |
| wedding_zone_landingpage | STALE | 6 | Next 14+ + Tailwind RTL + Postgres 14+ + NextAuth + MyFatoorah + SendGrid + Twilio — full booking platform | Static HTML only — no app, no DB, no payments. One Vercel static file `legacy-template/index.html` = a personal marriage proposal page ("For Miss Asma") | PROJECT_DOCUMENTATION documents a full Next.js tree, 11-table schema, payment wrappers — none of it exists; only a proposal page is deployed |
| whisky-wallpaper | STALE | 10 | Swift 6, macOS 13+, AppKit+AVFoundation, 6 Swift files, no private frameworks, no App Support writes | Swift 5.0, macOS 26.0+ (Tahoe), + private Wallpaper.framework, 7 Swift files, writes to ~/Library/Application Support/com.apple.wallpaper/aerials/ | SECURITY.md claims "no private frameworks, no App Support writes" — app links private Wallpaper.framework via @_silgen_name and writes video copies/thumbnails to App Support |
| whatsapp-bulk-sender | MINOR-DRIFT | 8 | Next 16 (Vercel) + Express (Railway) + Neon/Prisma + BullMQ/Redis + R2 + Resend + Gemini | + Railway services whatsapp-broadcaster + vigilant-peace, Prisma 5, Resend via nodemailer-shim, OneSignal push, Axiom drain, Sentry | DEPLOYMENT claims "GitHub Actions blocked by billing" — workflows live since 2026-05-22; also per-commit Neon snapshot claim is retired |
| indibat-platform | MINOR-DRIFT | 7 | Next 15 + React 18 + Tailwind v4 + shadcn (New York/Zinc) + Supabase (auth+DB+Storage) + Tap + Bunny + Resend + Plausible | Next 16.1.6 + React 19.2.3 + shadcn (base-nova/neutral) + Supabase (auth+DB only, no Storage) + Tap + Bunny + Resend, Vercel Analytics only | README is boilerplate create-next-app (Geist font); real font is Tajawal — entire README needs replacement |
| mypovonai | MINOR-DRIFT | 8 | Next 16 + Prisma/SQLite + @anthropic-ai/sdk (API key) + shadcn + HyperFrames transcribe (Whisper) | Next 16 + Prisma 7 + better-sqlite3 adapter + claude CLI (subscription, no SDK/key) + no shadcn + openai-whisper CLI direct + Telegram notify | Plan/spec claim @anthropic-ai/sdk + ANTHROPIC_API_KEY; real impl shells out to claude CLI via subscription (no API key) |
| al_assriya_landing | MINOR-DRIFT | 7 | Next 16 + Tailwind v4 + Framer Motion + Neon + Drizzle + jose JWT + local FS storage + Vercel | + `motion` ^12 (standalone, not framer-motion); local FS write path incompatible with Vercel ephemeral FS | README claims Framer Motion (installed pkg is `motion`); also local-FS uploads silently lost on Vercel deploys |
| code_tech_landing_page | MINOR-DRIFT | 9 | Vanilla HTML/CSS/JS + Supabase (PG+Auth+Storage) + FA 6.4 + Vercel static + PWA — no build/npm | Same stack; creds hardcoded in config.js (not env), Storage bucket `media` | README lists 18 DB tables but migration 001 defines only 10; 11 actively-queried tables have no source-controlled schema |
| beethoven | MISSING-DOCS | 10 | Audit files describe a bare Express app with NO auth/headers/rate-limit/Dockerfile/.env.example | Node 22 / Express 5 / in-memory + SSE + OneSignal + QRCode + helmet + cors + express-rate-limit, Docker (node:22-alpine), Basic+Bearer admin auth | No README exists at all; and FIXES.md marks FIX-001/002/003 as not-done (`[ ]`) when auth/helmet/rate-limit are all already implemented |
| whisky-claude | MINOR-DRIFT | 11 | Swift 6 macOS (Notchy fork), double-clap trigger, BotFace SF Symbol, .mp3 sounds, 4 settings tabs, Notch/Terminal source files | Swift 6, single-slap detector (SharedMicCapture+SoundAnalysis), GIF mascot, .wav sounds, 3 settings tabs, 14 actual Swift files (no Notch/Terminal) | ARCHITECTURE.md source tree lists NotchWindow/BotFaceView/SessionStore/TerminalManager etc. — none exist; trigger is single-slap not double-clap |

## Drift by project

### force-website-builder (STALE)
- README.md Tech Stack table — "Prisma ORM (51 models)" — STALE — schema has 83 models; update to "83 models".
- README.md Tech Stack table — "Vitest (332+ tests)" — DRIFT — DEPLOYMENT.md pre-push hook says 497 tests; unify to current passing count (`vitest run --reporter=verbose | tail -1`).
- README.md Neon CLI section — "per-commit Neon snapshots in neon-snapshot.yml use NEON_API_KEY" — STALE — CLAUDE.md (2026-06-08) marks the workflow RETIRED (branch cost); DR is now daily local pg_dump. Remove or point to CLAUDE.md rollback section.
- README.md Tech Stack table — no mention of Inngest/OneSignal/Resend/Sentry/Axiom/PostHog/Pino — MISSING — add rows: Async Jobs=Inngest; Push=OneSignal+Web Push (VAPID); Email=Resend; Errors=Sentry; Logging=Pino+Axiom; Analytics=PostHog (ROADMAP already lists these).
- DEPLOYMENT.md architecture box (L26) + Cost Summary (L395) — "Vercel Pro ($20/mo)" — DRIFT — same file's Account Ownership table (L552) and global CLAUDE.md say Hobby; change to "Vercel Hobby" (free at current scale).
- DEPLOYMENT.md architecture box (L50) — "per-commit snapshot brs" shown as active Neon component — STALE — retired 2026-06-08; replace with "daily local pg_dump (launchd com.forceai.neon-backup)".
- DEPLOYMENT.md §2 Cloudflare Pages Setup (~L136-196) — prod storefront/admin deployed to force-web.pages.dev / force-admin.pages.dev — STALE — has a ⚠️ banner but full instructions remain; delete the body (keep banner), real target is Vercel.
- DEPLOYMENT.md §4 Supabase Configuration (~L239-268) — prod DB is Supabase, upgrade to Supabase Pro $25/mo — STALE — has ⚠️ banner but full instructions remain; delete body (keep banner), prod DB is Neon.
- DEPLOYMENT.md §1.4 Env Variables — DATABASE_URL example is a Supabase pooler URL — STALE — replace with a Neon pooled URL example + add DIRECT_URL (non-pooled, required in prod).
- DEPLOYMENT.md §5 DNS Configuration — store/admin CNAME = *.pages.dev; cdn = r2.cloudflarestorage.com — STALE — targets are Vercel (store./app.forcemediakw.com); CDN is *.r2.dev public bucket. Rewrite DNS table.
- DEPLOYMENT.md §6.5 SLA table (L280) — "Staging→main promotion gate (every feature deploys to staging first)" — STALE — same file states "there is no separate staging Railway service"; replace with the real gate (CI green via pre-push hook before push to main).
- DEPLOYMENT.md §6.5 SLA table (L280) + docs/business/04-pricing-tiers.md §6.5 (L280/283) — "per-commit Neon DB snapshots, 9-deep retention" / "Neon WAL + prod-<sha> branch per commit" backing 99.5% uptime — STALE — retired; replace both with "daily local pg_dump (30-day retention at ~/Desktop/projects/_backups/force-website-builder/)".
- docs/ROLLBACK.md L3 header — "Neon Postgres (51 models, RLS via AsyncLocalStorage)" — STALE — 83 models.
- docs/ROLLBACK.md §C Migration rollback (L79-138) — "every push to main creates prod-<short-sha> branch via neon-snapshot.yml" — STALE — workflow retired; the file still has `on: push: [main]`. Disable workflow/remove trigger; replace §C with the daily pg_dump restore procedure.
- docs/business/04-pricing-tiers.md §4 objections table (L235) — "per-commit Neon snapshots so any deploy reverts in <5min" — STALE — update to reference daily local pg_dump; restore = pull latest dump from _backups/ and pg_restore.

### whatsapp-bulk-sender (MINOR-DRIFT)
- DEPLOYMENT.md (root L3-21) — "GitHub Actions blocked by billing; using local pre-push gate instead" — STALE — production-deploy.yml + 9 workflows are live (restored 2026-05-22); remove the billing-suspended section. Pre-push hook remains as a fast local gate but GH Actions is not blocked.
- DEPLOYMENT.md (root L45) — "neon-snapshot.yml creates prod-<short-sha> on push to main" — STALE — RETIRED 2026-06-08 (cost, stale branches piled up); DR is daily local pg_dump (launchd com.forceai.neon-backup).
- DEPLOYMENT.md (root L52) — "Log drain: configure in Railway settings" — DRIFT — Axiom (@axiomhq/winston) already wired in backend/src/utils/logger.js via AXIOM_TOKEN + AXIOM_DATASET; update to "Axiom (set AXIOM_TOKEN + AXIOM_DATASET in Railway)".
- README.md (L38) — "per-commit Neon snapshots in neon-snapshot.yml use NEON_API_KEY" — STALE — remove; workflow retired 2026-06-08, DR is local daily pg_dump.
- backend/WORKER.md (L58, 75) — services named whatsapp-saas-backend-production / whatsapp-saas-worker-production — STALE — correct names are whatsapp-broadcaster (API) and vigilant-peace (worker).
- backend/WORKER.md (L34-44) — worker requires SMTP_HOST/PORT/USER/PASS/SECURE/FROM_EMAIL/FROM_NAME — STALE — email migrated to Resend (emailService.js is a shim); replace with RESEND_API_KEY + RESEND_FROM_EMAIL.
- backend/WHATSAPP_2025_UPGRADE.md (L51-54, 140) — "execute the SQL migration in your Supabase dashboard / Supabase SQL Editor" — STALE — DB migrated Supabase→Neon (2026-04); use `npx prisma migrate deploy` (or Neon SQL editor / psql with DIRECT_URL).
- backend/README.md (L91-110) — auth endpoints listed as only /login, /me, /change-password; clients include GET /api/clients/:id/qr — DRIFT — ~14 auth routes missing (/register, /refresh, /logout, /logout-all, /verify, /preferences GET+PUT, /forgot-password, /reset-password, /me/export, /me/erase, /mfa/* added 2026-06-08); GET /api/clients/:id/qr has no matching router.get() — remove or mark internal-only.

### Force_media_CRM (STALE)
- README.md L21 — Hosting = "Netlify (serverless)" — STALE — change to "Vercel" (vercel.json present, `npm run deploy` = `vercel --prod`).
- README.md L18 — Notifications = "Web Push API" — STALE — change to "OneSignal (react-onesignal v3 + REST API)"; no web-push package exists.
- README.md L22 — PWA = "next-pwa with service worker" — STALE — remove next-pwa (not in package.json); OneSignal injects/manages the SW.
- README.md L115-117 — push env vars NEXT_PUBLIC_VAPID_PUBLIC_KEY / VAPID_PRIVATE_KEY / VAPID_EMAIL — STALE — replace with NEXT_PUBLIC_ONESIGNAL_APP_ID, ONESIGNAL_REST_API_KEY, NEXT_PUBLIC_ONESIGNAL_SAFARI_WEB_ID.
- README.md L94/98 — build "(Prisma generate + Next build + push handler injection)"; deploy = Netlify — STALE — build is "prisma generate && next build" only (add-push-to-sw.js removed); deploy = `vercel --prod`.
- README.md L184-191 project structure — lists netlify/functions/, netlify.toml, scripts/add-push-to-sw.js, api/push/, api/updates/, src/lib/push.ts, hooks/use-polling-updates.ts — STALE — none exist; replace: api/push/→api/onesignal/, src/lib/push.ts→src/lib/push-helpers.ts, use-polling-updates.ts removed.
- README.md L208 DB schema table — model "PushSubscription" — STALE — model is OneSignalSubscription; reflect OneSignal player_id semantics.
- README.md L53 Neon CLI — per-commit snapshots in neon-snapshot.yml active, use NEON_API_KEY — STALE — RETIRED 2026-06-08 (CLAUDE.md Rule 3); DR is local pg_dump via scripts/backup-db.sh. Note the workflow is disabled.
- DEPLOYMENT.md L64-88 §"1. Netlify Deployment (Recommended)" — Netlify one-click + netlify-cli — STALE — replace entire section with Vercel as the only target (`vercel --prod`).
- DEPLOYMENT.md L34, 309 — "Add these to Netlify/Vercel" / "Required Headers (configured in netlify.toml)" — STALE — L34 say Vercel only; L309 netlify.toml doesn't exist, headers are in next.config.ts async headers().
- DEPLOYMENT.md L178-193 push troubleshooting — VAPID keys, browser push subscription, SW registration — STALE — push is OneSignal SDK; replace VAPID verification with OneSignal App ID/REST key check, drop the VAPID JS snippet.
- DEPLOYMENT.md L253-255 build-failure troubleshoot — "Ensure scripts/add-push-to-sw.js exists" — STALE — file removed; delete the step.
- DEPLOYMENT.md L389 — `npm run deploy` = "Test, build, and deploy to Netlify" — STALE — change to Vercel.
- docs/ROLLBACK.md L41-93 §C — every push creates prod-<sha> Neon branch via neon-snapshot.yml; restore from it — STALE — retired (Rule 3); rewrite §C to local pg_dump (scripts/backup-db.sh, ~/.claude/scripts/backup-all-neon.sh).
- SECURITY.md L20 (rule 4) — "E2E tests use ephemeral Neon branches forked from prod-<sha>, NOT a postgres service container" — STALE — invert: E2E uses a postgres:16 service container seeded via db:seed:ci (ci.yml e2e: job); also fix item 5 + the L60 orphan-service-container note.
- .env.example / .env.production.example — list VAPID push creds, no OneSignal vars — STALE — replace VAPID entries with NEXT_PUBLIC_ONESIGNAL_APP_ID, ONESIGNAL_REST_API_KEY, NEXT_PUBLIC_ONESIGNAL_SAFARI_WEB_ID.
- README.md (no section) — no mention of OneSignal, rate-limit.ts, SystemState model, command-palette — MISSING — add integration note: push via OneSignal (react-onesignal v3); SSE uses SystemState Postgres table for multi-instance safety; in-memory rate limiter at src/lib/rate-limit.ts (5 auth attempts/15 min).

### om-hassan-menu (STALE)
- README.md — "No DB, no auth, no payments — pure menu" — STALE — remove tagline; now Neon (Prisma 7), JWT admin auth (jose+scrypt), Vercel Blob.
- README.md — "19 categories and 108 items" — DRIFT — 20 categories (15 root + 5 beverage sub: fresh-juices, cocktails, milkshakes, soft-drinks, hot-beverages), 108 items.
- README.md — lib/ lists menuHelpers.ts (getCategoryBySlug, getPrevNextCategory) — STALE — file doesn't exist; both functions are in lib/menu-server.ts.
- README.md — "npm run build # production build (Next.js 16, Turbopack)" — DRIFT — build is "prisma generate && next build", no --turbopack flag; remove parenthetical.
- README.md — project layout omits lib/admin-actions.ts, admin-auth.ts, categoryGlyphs.ts, db.ts, menu-server.ts, site-server.ts — MISSING — add all six lib files.
- README.md — layout omits components/Ankh/Dove/Lotus/Moon/Pyramid/Star/Sun.tsx — MISSING — add the seven Egyptian-motif glyph SVG components.
- README.md — layout omits components/admin/ (AdminShell, BulkUploadGrid, HiddenToggle, ImageField, ReorderButtons, StatusBanner, SubmitButton) — MISSING — add a components/admin/ subsection.
- docs/ADMIN_SETUP.md — "Set NEON_API_KEY + NEON_PROJECT_ID so the per-push snapshot workflow runs" — DRIFT — workflow still active here but global pattern (FWB/WBS) retired snapshots for cost; either disable + reference daily local backups, or document it's intentionally kept.
- docs/ROLLBACK.md — Path C Neon snapshot restore via prod-<good-sha> branch — DRIFT — workflow still active but prune-to-9 loses old snapshots fast under active dev; cross-reference scripts/backup-db.sh as the reliable fallback.
- docs/plans/2026-05-17-admin-panel.md — "Install bcryptjs; loginAction bcrypt-compare against ADMIN_PASSWORD_HASH" — STALE — implemented auth uses node:crypto scryptSync (no bcryptjs); add a note or update to scrypt.
- docs/plans/2026-05-17-admin-panel.md — schema omits hidden (Category/Item), parentId (Category), SiteSettings model — STALE — shipped schema added hidden booleans on both models, parentId/parent/children hierarchy, and a SiteSettings singleton.

### Force_media_CRM, om-hassan-menu listed above. indibat-platform (MINOR-DRIFT)
- README.md — Geist font boilerplate ("uses next/font to load Geist") — STALE — replace boilerplate README; actual font is Tajawal (Arabic) via next/font/google in src/lib/fonts.ts.
- docs/plans/2026-03-09-kaigen-platform-design.md + implementation-plan.md — Next.js 15 throughout (diagram, table, setup commands) — STALE — update all to 16; package.json has next 16.1.6.
- docs/plans/...implementation-plan.md — shadcn "New York style, Zinc color" — STALE — actual components.json: style=base-nova, baseColor=neutral.
- docs/plans/...platform-design.md — Supabase Storage for PDFs/images; certs to "certificates table + Supabase Storage" (L49/285/303) — STALE — no storage bucket calls anywhere; cert PDFs rendered on-the-fly via @react-pdf/renderer streamed inline from /api/certificates/generate; images from Bunny CDN.
- docs/plans/...design.md + implementation-plan.md — Analytics: Vercel + Plausible, marked [x] complete (L462) — DRIFT — only @vercel/analytics + @vercel/speed-insights installed; plan's own tracking table (L492) says Plausible "NOT SET UP"; not in package.json.
- CLAUDE.md (L78) — DB tables list — DRIFT — add 'volunteer_signups' (defined in supabase/migrations/001_initial_schema.sql:308, used in src/lib/actions/volunteers.ts; graph shows the Admin Consultations & Volunteers community).
- README.md (entire) — boilerplate create-next-app, no project info — MISSING — replace with project README: purpose (Arabic RTL online learning for Kuwait), real stack (Next 16, Supabase, Tap, Bunny, Resend), quick-start, pointer to docs/DEPLOYMENT.md.

### mypovonai (MINOR-DRIFT)
- docs/superpowers/plans/2026-06-01-slice-0-1-foundation-ideas-scripts.md — lists @anthropic-ai/sdk; .env.example has ANTHROPIC_API_KEY; env.ts defaults shown as full model IDs — STALE — pivoted to claude CLI (spawn, no SDK); remove SDK, drop ANTHROPIC_API_KEY, update env defaults to CLI aliases sonnet/sonnet.
- ...slice-0-1...md — Tech Stack includes shadcn/ui — STALE — shadcn/@radix-ui absent from package.json; remove.
- docs/superpowers/specs/2026-06-01-mypovonai-dashboard-design.md §4.3 step 2 — transcription via "hyperframes transcribe" — STALE — src/lib/studio/transcribe.ts drives openai-whisper CLI directly (large-v3, --output_format json); update to "openai-whisper CLI (large-v3, --language ar)".
- ...dashboard-design.md §3 data model — videos.renderSettings json field — STALE — Video model has no renderSettings; remove or mark deferred.
- README.md — modules listed as only Ideas+Kanban, Daily Brief, Scripts; "Studio (HyperFrames) and Growth (Instagram) are later slices" — DRIFT — Studio (src/app/studio, src/lib/studio/*, worker/studio.ts) and Growth (src/app/growth, src/lib/growth/) fully implemented with 20+ test files; update modules list.
- ...slice-0-1...md Task 2 Step 3 — Prisma singleton uses plain new PrismaClient() — STALE — src/lib/db.ts uses PrismaBetterSqlite3 adapter from @prisma/adapter-better-sqlite3 with explicit file URL; update the snippet.
- ...dashboard-design.md §2 External calls — "Claude API (scripts), keys in .env.local" — DRIFT — shells out to local claude CLI via subscription auth (no ANTHROPIC_API_KEY); update to "claude CLI via subscription auth (no API key)".
- ...dashboard-design.md — Telegram integration not mentioned in any doc — MISSING — src/lib/notify/telegram.ts exists + tested (tests/telegram.test.ts); document the Telegram bot integration + TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID.

### digital-card (STALE)
- README.md L3 — "Static Next.js 16" headline (SSG, no DB/auth) — STALE — change to "Next 16 · Prisma 7 · Neon · Vercel Blob · admin CRUD. ISR (revalidate=3600) for public routes, force-dynamic for /admin".
- README.md L14-18 (Adding a card) — create data/cards/<slug>.ts, register in index.ts, drop photo in public/photos/ — STALE — both dirs deleted in v2; cards now via /admin (ADMIN_PASSWORD_HASH login), no TS editing.
- README.md L11 — "npm run build # static export verification" — DRIFT — no output:'export' in next.config.ts; standard server-bundle build; remove the comment.
- README.md L25 (Rollback) — "Three paths: Vercel-instant · rollback.sh · content backup" — DRIFT — update to "Four paths"; ROLLBACK.md adds Neon snapshot restore.
- docs/ROLLBACK.md §3 (Content backup) — "content in data/ + public/photos/; local snapshots keep last 30 commits" — STALE — dirs deleted; content is Neon + Vercel Blob; DB backups are the data store, photos in Blob (not in content snapshots).
- docs/ROLLBACK.md §4 (Neon snapshot restore) — push to main creates prod-<sha> branch, auto-prunes to 8 — DRIFT — per 2026-06-08 cross-project policy snapshots are retired (cost); workflow still active in .github/workflows/neon-snapshot.yml — disable it and update §4 to point at local pg_dump (~/.claude/scripts/backup-all-neon.sh).
- README.md (entire) — no mention of admin panel, admin auth, Vercel Blob — MISSING — add admin section: URL /admin, set ADMIN_PASSWORD_HASH (npx tsx scripts/hash-password.ts), ADMIN_JWT_SECRET, photos in Vercel Blob (BLOB_READ_WRITE_TOKEN).

### beethoven (MISSING-DOCS)
- FIXES.md (FIX-001 `[ ]`) + .claude/audits/AUDIT_INFRA.md (INFRA-005) — "admin panel has ZERO auth; /admin, /api/next, /api/reset unauthenticated" — STALE — already implemented: requireAdminBasic (HTTP Basic on GET /admin) + requireAdminAPI (Bearer on POST /api/next, /api/reset). Mark FIX-001 [x].
- FIXES.md (FIX-001) description — proposes x-admin-key header + ADMIN_KEY env — DRIFT — reality uses ADMIN_PASSWORD + Bearer scheme; update the description.
- FIXES.md (FIX-002 `[ ]`) + AUDIT_INFRA (INFRA-004) — "no helmet/CSP/HSTS/X-Frame-Options" — STALE — helmet installed + configured with full CSP (incl. OneSignal CDN allowlist). Mark FIX-002 [x].
- FIXES.md (FIX-003 `[ ]`) + AUDIT_INFRA (INFRA-009, INFRA-011) — "no rate limit on /api/join, no SSE cap, no queue cap" — STALE — express-rate-limit applied (joinLimiter 5/min/IP), MAX_SSE_CLIENTS=200, MAX_QUEUE_SIZE=500. Mark FIX-003 [x].
- FIXES.md (FIX-003) — suggests MAX_QUEUE_SIZE=100 — DRIFT — actual is 500 (server.js L18); update.
- AUDIT_INFRA.md (INFRA-001) — "no .env.example" — STALE — exists with PORT, HOST, ADMIN_PASSWORD, ONESIGNAL_APP_ID, ONESIGNAL_API_KEY; resolved.
- AUDIT_INFRA.md (INFRA-002) — "no .gitignore" — STALE — exists; resolved.
- AUDIT_INFRA.md (INFRA-003) — "no health check endpoint" — STALE — GET /api/health implemented (server.js L130); resolved.
- AUDIT_INFRA.md (INFRA-012) — "no Dockerfile; suggests FROM node:20-alpine" — STALE — Dockerfile exists using node:22-alpine; deploy = Docker/Railway (trust proxy set); resolved + base image in fix is outdated.
- (README absent) — no README, no setup/env/deploy/API docs, no in-memory warning — MISSING — create README: description (restroom queue for Beethoven coffee shop), prereqs (Node 22, optional Docker), env table, quick start, Docker run, API endpoint list, admin access, and a prominent "all queue state is in-memory, lost on restart" warning.

### al_assriya_landing (MINOR-DRIFT)
- README.md Tech Stack table — "Animations: Framer Motion" — STALE — installed pkg is `motion` (^12.34.0); imports are from 'motion/react' / 'motion'; change row to "Animations | Motion (motion/react) ^12".
- README.md Tech Stack + Deployment — "File Storage: Local filesystem (/public/images/uploads/)" + "Hosting: Vercel" — DRIFT — Vercel FS is ephemeral; src/app/api/admin/upload/route.ts writes there and files are lost on deploy/cold-start. Document the limitation or move to Vercel Blob/R2/S3.
- README.md Getting Started — "cp .env.example .env.local" — STALE — no .env.example exists; create it (DATABASE_URL, JWT_SECRET) or list the two vars manually.
- README.md Getting Started — "npx drizzle-kit push" — DRIFT — package.json has `npm run db:push`; use that for consistency.
- README.md Admin CMS — "Searchable icon picker with 25 SVG icons" — DRIFT — IconPicker.tsx has 26; update count.
- README.md Project Structure (src/lib/) — lists only auth.ts, admin-auth.ts, rate-limit.ts, types.ts — MISSING — add src/lib/crud-routes.ts, src/lib/i18n.ts, src/lib/db/queries.ts.
- README.md Landing features — omits Manager Word + Facility/Equipment sections — MISSING — add Manager Word (كلمة المدير العام, driven by site_settings) and Facility (reuses equipment table, separate section w/ brand strip).

### code_tech_landing_page (MINOR-DRIFT)
- README.md DB Tables (L132-153) — lists 18 tables — DRIFT — migration 001_initial_schema.sql defines only 10 (admin_roles, leads, partners, products, faq, services, site_config, contact_info, blog_posts, audit_log); the 11 runtime-queried tables (hero, about, trust_badges, stats, process_steps, testimonials, portfolio, portfolio_settings, contact_form, footer, footer_links) have NO migration. Separate "in migrations" vs "expected in Supabase" + add the missing CREATE TABLE statements.
- CLAUDE.md DB section (L44) — table list — DRIFT — missing the 11 actively-queried tables above; also lists products/blog_posts/contact_info which are never queried; align to what supabase-content.js / admin.js query.
- README.md Admin CMS (L33) — "15 manageable sections" — DRIFT — navConfig has 13 entries (12 ex-Dashboard); Trust Badges, Portfolio Settings, Contact Form are sub-sections; change to "12 top-level sections (...3 are sub-sections)".
- README.md Admin CMS (L41) — "icon picker — 170+ Font Awesome icons" — DRIFT — fontAwesomeIcons array has 125; change to 125 or add the missing ~45.
- README.md Contact (L208) — "WhatsApp: +965 69698803" — DRIFT — config.js WHATSAPP_NUMBER is 96560033835 (+965 60033835), used by the live CTA; align/clarify which is company vs personal.
- README.md Admin CMS (L35) — "Audit log — track all admin actions" — STALE — audit_log table exists but admin.js never writes to it (no INSERT/call anywhere); implement or remove the claim.
- README.md Dev/Env (L169-175) + Structure (L111) — "create .env from .env.example with SUPABASE_URL + SUPABASE_ANON_KEY" — DRIFT — config.js hardcodes both literals (static site, no process.env); the .env instructions have no effect; clarify creds are edited in config.js and the anon key is public by design (RLS secures access).
- README.md + CLAUDE.md — no Storage bucket name documented — MISSING — admin.js uploads to bucket 'media' (L576, 589); add a Storage Setup step: create a public 'media' bucket before using admin upload.
- README.md Security (L54) — "CSP restricts resource loading" implies server header — DRIFT — CSP is set via <meta http-equiv> tags, not vercel.json HTTP headers; clarify it's meta-based and consider moving to vercel.json for full coverage.

### force_media_landing_page (STALE)
- USER_GUIDE.md — "does not use a database or server; all changes in localStorage, downloadable as HTML" / "No Backend... No server or database needed" — STALE — full Neon Postgres backend (14 tables) + Vercel Serverless Functions; admin changes persist to DB via api/admin/update.js. Rewrite Saving/Important Notes to describe the live DB-backed CMS.
- USER_GUIDE.md — Step 4 "Click Save & Download HTML → downloads force-media-export-YYYY-MM-DD.json" — STALE — no download-HTML flow; saves go to api/admin/update.js. Remove/replace.
- USER_GUIDE.md — Customization: "Open styles-super.css / index-super.html" — STALE — those files don't exist; actual files are styles.css / index.html.
- USER_GUIDE.md — Support: "Check docs_archive/ folder" — STALE — no docs_archive/ directory; remove.
- USER_GUIDE.md — "Last Updated: October 2024 / Version 2.0" — STALE — DB-backed CMS, Neon snapshots, security hardening all shipped after that; update version/date footer.
- README.md — Admin access "Add ?admin=1 to URL" — STALE — admin panel is a separate admin.html at /admin, not ?admin=1; correct to forcemediakw.com/admin.
- README.md — Auth "Custom token + sessionStorage (constant-time comparison)" — DRIFT — DB-backed: api/admin/auth.js issues opaque tokens stored in admin_sessions Neon table (sliding refresh via validateAdminToken); sessionStorage only holds the obfuscated client token. Note the server-side session layer.
- README.md — api/admin/ listed as auth/query/insert/update/delete/leads (6 files) — DRIFT — also contains logout.js; add it.
- README.md — Neon CLI: "per-commit snapshots in neon-snapshot.yml use NEON_API_KEY" — DRIFT — per global rule (2026-06-08) snapshots are RETIRED (cost, broken auto-prune); workflow file exists but should be disabled; state daily local pg_dump is the backup mechanism.
- docs/ROLLBACK.md §C — "every push to main creates prod-<sha> via neon-snapshot.yml" as primary DB rollback — STALE — retired 2026-06-08; replace with daily local pg_dump restore (backup-all-neon.sh).
- certification/forcemediakw_ssl_certificates.md — "Expires: March 21, 2026" documented as valid — STALE — expired ~79 days ago as of 2026-06-08; add renewal notice; site is on Vercel (auto-TLS) so manual cert mgmt is irrelevant.
- certification/forcemediakw_ssl_certificates.md — entire doc describes uploading the cert to Netlify — STALE — deployed on Vercel (auto-provisioned TLS); replace Netlify instructions with a note that Vercel manages TLS.
- README.md — no mention of husky pre-commit (secretlint) or .github/workflows/gitleaks.yml — MISSING — add a Security CI/pre-commit note (secretlint on pre-commit via husky, gitleaks in CI per package.json + workflows).

### wedding_zone_landingpage (STALE)
- PROJECT_DOCUMENTATION.md §Technology Stack (L48-75) — recommends Next 14+, Tailwind, Postgres 14+, NextAuth, Prisma/pg, SendGrid, Twilio, MyFatoorah — STALE — these are planning recommendations, not reality (no app code built); retitle "Proposed Stack" or add a prominent STATUS banner.
- PROJECT_DOCUMENTATION.md §Hosting & Infrastructure (L80-129) — recommends DigitalOcean/Railway/Render/Vercel — STALE — only `legacy-template/index.html` (Vercel project marry-me-asma, a personal proposal page) is deployed; note no application is deployed.
- PROJECT_DOCUMENTATION.md §Project Structure (L1759-1917) — describes a full Next.js tree (src/components/, pages/, api routes, lib/, database/schema.sql, docs/*) — STALE — none exists; actual repo: PROJECT_DOCUMENTATION.md/.html, convert_to_html.py, graphify-out/, legacy-template/, CLAUDE.md. Mark as "planned structure".
- PROJECT_DOCUMENTATION.md §System Architecture (L1664-1708) + all code samples (lib/myfatoorah.js, pages/api/payment/callback.js, DatePicker.jsx, lib/notifications.js) — STALE — none exist; add a top-level disclaimer that all code samples are design specs, no app code implemented.
- legacy-template/.vercel/project.json — Vercel project named marry-me-asma — MISSING — no doc acknowledges what's actually deployed; the deployed index.html is a personal marriage proposal page ("For Miss Asma"), unrelated to the booking platform; add a note in CLAUDE.md.
- PROJECT_DOCUMENTATION.md §Database Schema (L1252-1568) — documents 11 tables (ballrooms, setups, additional_services, customers, bookings, booking_services, payment_transactions, blocked_dates, admin_users, settings, admin_notifications) — STALE — no DB exists; mark header "Proposed Database Schema (not yet implemented)".

### whisky-claude (MINOR-DRIFT)
- docs/ARCHITECTURE.md — source tree lists NotchWindow, BotFaceView, MascotAnimator, SessionStore, TerminalManager, TerminalPanel, TerminalSession, TerminalSessionView, PanelContentView, SessionTabBar — STALE — none exist; replace with the actual 14 files (AppDelegate, ClapDetector, ClawdMascot, EventWatcher, KeywordRecognizer, MascotWindow, MenuBarIcon, SettingsManager, SettingsWindow, SharedMicCapture, SleepBlocker, SoundPlayer, Uninstaller, WhiskyClaudeApp).
- docs/ARCHITECTURE.md — ClapDetector "two hits within 100-600ms fire onDoubleClap; threshold 0.5..0.9; labels clapping/applause" — STALE — now single-slap: broad percussive label set (knock, thump, drum, tap), one hit above threshold + 1.5s cooldown, sensitivity 0.35..0.80, via SharedMicCapture (not direct AVAudioEngine tap).
- docs/ARCHITECTURE.md — "SettingsWindow has 4 tabs: About, General, Integrations, Voice" — STALE — 3 tabs (About, General, Voice); no Integrations tab.
- docs/ARCHITECTURE.md — "AppDelegate owns NSStatusItem, TerminalPanel, NotchWindow" — STALE — owns NSStatusItem (via MenuBarIcon), MascotWindow, EventWatcher, ClapDetector, KeywordRecognizer, SleepBlocker; no TerminalPanel/NotchWindow.
- docs/ARCHITECTURE.md — sounds waitingForInput.mp3 / taskCompleted.mp3; "Task 5 pending: swap waitingForInput.mp3" — STALE — sounds are .wav (taskCompleted.wav, waitingForInput.wav); custom sound picker implemented, Task 5 done.
- docs/ARCHITECTURE.md — "onDoubleClap fires SessionStore.createQuickSession() + showPanelBelowStatusItem()" — STALE — callback routes to AppDelegate.openClaudeInTerminal() (opens Terminal.app via AppleScript); no SessionStore/embedded panel.
- docs/ARCHITECTURE.md — Open items: "Voice keyword detection (hey claude) via Speech framework — not wired" — STALE — fully implemented + wired (KeywordRecognizer.swift, SettingsManager.wakeWordEnabled, AppDelegate); remove from open items.
- CLAUDE.md — item 6 "Opt-in double-clap voice trigger (AVAudioEngine)" + double-clap architecture — DRIFT — shipped as single-slap via SoundAnalysis/SharedMicCapture; update item 6 and remove double-clap language.
- README.md — link to docs/STABLE_CODESIGN.md "(TBD; see commit history)" — MISSING — file doesn't exist; create it (OpenSSL + security import recipe) or inline the procedure.
- README.md — "Plus:" feature list mentions "Hey Claude / Hey Whisky wake words" but never the slap trigger — MISSING — add a bullet for the slap trigger (Settings → Voice → Slap the Mac).

### whisky-wallpaper (STALE)
- README.md badge — ![Swift 6] — STALE — SWIFT_VERSION=5.0 in Debug+Release; change badge to Swift 5.
- README.md badge + Requirements — "macOS 13 (Ventura) or later" — STALE — MACOSX_DEPLOYMENT_TARGET=26.0; update to macOS 26+ (Tahoe).
- README.md Architecture — "Six Swift files, ~625 lines" — STALE — 7 files; v2 added AerialInstaller.swift + WallpaperBridge.swift (CLAUDE.md already lists 7).
- README.md Architecture — file tree ends at WallpaperWindowController.swift — STALE — add AerialInstaller.swift + WallpaperBridge.swift to match CLAUDE.md.
- README.md Menu structure — no "Lock-screen sync: On/Off" item — MISSING — add it (Cmd+L), present in AppDelegate.swift L190-199.
- SECURITY.md "What Whisky Wallpaper touches" — states "No ~/Library/Application Support/" — STALE — add ~/Library/Application Support/com.apple.wallpaper/aerials/ row; AerialInstaller.swift writes video copies, PNG thumbnails, manifest/entries.json, Store/Index.plist on each activation when lock-screen sync is On.
- SECURITY.md "No network access" — "links only AppKit, AVFoundation, ServiceManagement, UniformTypeIdentifiers" — STALE — add Wallpaper.framework (private); project.pbxproj links /System/Library/PrivateFrameworks/Wallpaper.framework, WallpaperBridge.swift uses @_silgen_name for wp_setLegacyDesktopPicture.
- README.md Requirements — "No entitlements beyond the default unsandboxed app" — DRIFT — entitlements plist is empty but app links private Wallpaper.framework + writes to com.apple.wallpaper App Support; clarify the footprint.
- README.md "What it doesn't do" — "Lock-screen video... not implemented, roadmap item" — STALE — v2 ships a partial solution (AerialInstaller registers videos in System Settings → Wallpaper; WallpaperBridge sets a still frame so lock screen matches desktop); update to describe what v2 does + what remains.
- scripts/install.sh — INSTALLER_VERSION=1.2.1 — DRIFT — Xcode MARKETING_VERSION=1.2.0; installer is ahead, align them.

## Top fixes

The ten highest-impact corrections across the fleet — stale stack/deploy/pricing lies first:

1. **wedding_zone_landingpage** — PROJECT_DOCUMENTATION.md documents an entire Next.js booking platform (full file tree, 11-table schema, MyFatoorah/Twilio/SendGrid code) that does not exist. The only deployed artifact is a personal marriage proposal page (Vercel `marry-me-asma`). Add a top STATUS banner: "no application code implemented; all code/schema are design specs," and note in CLAUDE.md what `legacy-template/` actually is.
2. **force_media_landing_page** — USER_GUIDE claims "no database or server, changes saved in localStorage." Reality is a full Neon Postgres CMS (14 tables, admin_sessions) + Vercel Serverless Functions. Rewrite the Saving / Important Notes / architecture sections — this is the most dangerous lie (a maintainer following it would lose all DB-persisted changes).
3. **Force_media_CRM** — README + DEPLOYMENT recommend **Netlify** as the deploy target; the project deploys to **Vercel** (`vercel --prod`, vercel.json crons). Fix every Netlify reference (README L21/94/98, DEPLOYMENT §1, L34/309/389).
4. **Force_media_CRM** — Push is documented as Web Push / VAPID across README + DEPLOYMENT + .env examples; real implementation is **OneSignal** (react-onesignal v3 + REST). Swap all VAPID env vars and debug steps to OneSignal (APP_ID, REST_API_KEY, SAFARI_WEB_ID).
5. **digital-card** — README's "Adding a card" tells users to edit `data/cards/*.ts` + `public/photos/` — both directories were deleted in v2; cards are now created via the `/admin` CRUD panel. Rewrite the headline ("static, no DB") and the add-a-card flow; the current instructions are unfollowable.
6. **om-hassan-menu** — README's "No DB, no auth, no payments — pure static menu" tagline is false: Neon + Prisma 7 + jose/scrypt JWT admin + Vercel Blob all shipped. Remove the tagline and document the admin stack.
7. **Fleet-wide Neon-snapshot retirement (FWB, WBS, Force_media_CRM, digital-card, force_media_landing_page; om-hassan-menu still active)** — Every repo's README/ROLLBACK/DEPLOYMENT still documents per-commit `prod-<sha>` Neon snapshots via neon-snapshot.yml as the DR path. Per the 2026-06-08 cost decision these are RETIRED; DR is daily local pg_dump (launchd com.forceai.neon-backup / backup-all-neon.sh). Disable the workflows in code and rewrite every rollback/backup section to the pg_dump restore procedure.
8. **force-website-builder** — DEPLOYMENT.md still carries full §2 Cloudflare Pages and §4 Supabase setup sections (deploy target + DB that no longer exist — real = Vercel + Neon), and claims **Vercel Pro $20/mo** when the account is Hobby. Delete the bodies of §2/§4 (keep stale banners), fix the cost table and DNS/env examples to Vercel + Neon.
9. **whisky-wallpaper** — SECURITY.md claims "no private frameworks, no ~/Library/Application Support writes." The app links Apple's private **Wallpaper.framework** (@_silgen_name) and writes video copies/thumbnails/manifests to com.apple.wallpaper App Support. Correct both security claims plus the Swift-6/macOS-13 → Swift-5/macOS-26 version drift.
10. **beethoven** — No README exists, and FIXES.md / AUDIT_INFRA.md mark admin-auth, helmet/CSP, and rate-limiting as **not-done (`[ ]`)** when all three are already implemented (plus Dockerfile, .env.example, health check). Mark the resolved findings done and write a README with the env table, Docker run, API list, and the critical "all state is in-memory, lost on restart" warning.
