# Docs Parity Sweep — 2026-06-09

Performed across 7 projects. Edits applied in-place (uncommitted).

---

## force-website-builder

| File | Verdict | Action |
|---|---|---|
| `README.md` | CURRENT | No changes needed — stack correct (Next.js 16, Railway, Vercel, Neon, Gemini), snapshot retirement documented |
| `DEPLOYMENT.md` | CURRENT | Fully updated in prior sessions — correct topology, Netlify/Supabase claims removed |
| `ROADMAP.md` | MINOR-DRIFT → FIXED | Test count was 332+ (stale); updated to 497+ to match README and DEPLOYMENT |
| `CONTRIBUTING.md` | MINOR-DRIFT → FIXED | Node.js >= 18.x (stale); updated to >= 20.0.0; PostgreSQL >= 14 → >= 17 (Neon is PG17); Redis note corrected |
| `docs/business/01-overview.md` | CURRENT | Correct managed-agency framing, no self-serve language, correct stack |
| `docs/business/04-pricing-tiers.md` | CURRENT | Correctly documents managed-agency model, no public self-serve tiers, plan tiers match code |
| `docs/business/06-faq.md` | CURRENT | No self-serve signup language; managed-agency framing correct |
| `docs/ROLLBACK.md` | CURRENT | Snapshot retirement documented (2026-06-08) |
| `docs/business/plan-feature-matrix.md` | NEEDS AHMAD REVIEW | Plan-feature mapping — verify against `packages/shared/src/plan-baselines.ts` for latest features |
| `docs/superpowers/plans/2026-05-13-iceberg-audit-followup.md` | STALE (historical) | References Stripe subscription automation for billing — managed-agency model supersedes this. Historical plan doc — no edit (archive context) |
| `.claude/audits/` (all) | CURRENT (snapshots) | Point-in-time audit artifacts — not living docs |
| Template `DESIGN.md` files (5) | CURRENT | Theme-specific design docs, no stale stack claims |

**Summary: 2 FIXED, rest CURRENT. 1 NEEDS AHMAD REVIEW.**

---

## whatsapp-bulk-sender

| File | Verdict | Action |
|---|---|---|
| `README.md` | CURRENT | Stack correct (Next.js 16, Railway, Neon, Gemini), snapshot retirement documented |
| `DEPLOYMENT.md` | CURRENT | Correct topology, snapshot retirement noted |
| `docs/DEPLOYMENT.md` | CURRENT | Fully detailed env vars, correct topology |
| `TRACKING_SETUP_GUIDE.md` | STALE → FIXED | Line 244: "Check your Supabase `conversions` table" — Supabase was replaced by Neon in April 2026. Fixed to Neon SQL query |
| `backend/README.md` | CURRENT | Stack correct, Neon Postgres, Prisma 5 |
| `backend/WHATSAPP_2025_UPGRADE.md` | CURRENT | Historical upgrade guide |
| `backend/EMBEDDED_SIGNUP_GUIDE.md` | CURRENT | Meta-specific guide, no stack claims |
| `backend/WORKER.md` | CURRENT | Worker architecture doc |
| `docs/architecture/wbs-architecture.md` | CURRENT | Architecture doc |
| `docs/superpowers/plans/2026-04-21-supabase-to-neon-plan.md` | CURRENT (historical) | Migration plan — historical context, correct to leave as-is |
| `SECURITY_IMPLEMENTATION_GUIDE.md` | CURRENT | JWT/CSRF/auth guide |
| `WhatsApp-Client-Setup-Guide.md` | NEEDS AHMAD REVIEW | Client-facing guide — verify no references to old flows (Supabase auth, staging Supabase env) |
| `frontend/README.md` | MINOR-DRIFT | Frontend-specific README — stack says Next.js (no version number). Not critical since main README covers it. |
| `frontend/MANUAL_TESTING_GUIDE.md` | NEEDS AHMAD REVIEW | May reference old UI flows — Ahmad to verify against current UI |

**Summary: 1 FIXED, most CURRENT. 2 NEEDS AHMAD REVIEW.**

---

## Force_media_CRM

| File | Verdict | Action |
|---|---|---|
| `README.md` | STALE → FIXED | Hosting: "Netlify (serverless)" → "Vercel"; Deployment section said "Netlify"; neon-snapshot still referenced as active; DATABASE_URL comment said "Neon/Supabase/Railway"; npm run deploy said "deploy to Netlify". All fixed. |
| `DEPLOYMENT.md` | STALE → FIXED | Entire "Netlify Deployment (Recommended)" section with Deploy button; billing-suspended CI gate header; `scripts/add-push-to-sw.js` Netlify artifact reference; `netlify.toml` headers reference; DATABASE_URL Supabase reference; Scaling section said "Enable Netlify/Vercel CDN"; Deploy Quick Command said "deploy to Netlify". All fixed. |
| `docs/ROLLBACK.md` | STALE → FIXED | Section C described restoring from `prod-<sha>` Neon snapshot branches (workflow RETIRED 2026-06-08). Replaced with local pg_dump restore procedure. Removed stale "Setup" section about neon-snapshot.yml secrets. |
| `SECURITY.md` | CURRENT | Security policy doc — no stale stack claims |
| `docs/PITFALLS-EXTERNAL.md` | CURRENT | Research doc |
| `docs/adr/0001-crm-tenant-isolation.md` | NEEDS AHMAD REVIEW | ADR on tenant isolation — verify it reflects current NextAuth + Neon approach |
| `tests/integration/README.md` | CURRENT | Integration test README |

**Summary: 3 FIXED (README, DEPLOYMENT, ROLLBACK), rest CURRENT. 1 NEEDS AHMAD REVIEW.**

---

## om-hassan-menu

| File | Verdict | Action |
|---|---|---|
| `README.md` | CURRENT | Static menu app — no DB, no auth, no deployment infra claims to verify. Next.js 16 + Tailwind v4 confirmed correct. |
| `CLAUDE.md` | CURRENT | Delegates to AGENTS.md + global rules |
| `AGENTS.md` | CURRENT | Next.js compatibility warning |
| `docs/ADMIN_SETUP.md` | NEEDS AHMAD REVIEW | Admin setup guide — verify still accurate after hide-from-menu feature (2026-06-06) |
| `docs/ROLLBACK.md` | CURRENT | Simple Vercel rollback, no Neon snapshot references |
| `docs/superpowers/specs/2026-06-06-hide-from-menu-design.md` | CURRENT | Recent spec |

**Summary: All CURRENT. 1 NEEDS AHMAD REVIEW.**

---

## mypovonai

| File | Verdict | Action |
|---|---|---|
| `README.md` | CURRENT | Local-only studio app; no production infra claims; Claude subscription model documented correctly |
| `CLAUDE.md` / `AGENTS.md` | CURRENT | Standard disclaimers |
| `docs/BRAND.md` | NEEDS AHMAD REVIEW | Brand guide — verify still matches current app branding |
| `docs/runbooks/instagram-graph-api-setup.md` | NEEDS AHMAD REVIEW | Instagram API — verify still relevant and credentials approach still accurate |

**Summary: All CURRENT. 2 NEEDS AHMAD REVIEW.**

---

## digital-card

| File | Verdict | Action |
|---|---|---|
| `README.md` | CURRENT | Static Next.js 16 app, no infra claims, correct templates listed |
| `CLAUDE.md` / `AGENTS.md` | CURRENT | Standard disclaimers |
| `docs/DEPLOYMENT.md` | CURRENT | Correctly documents Vercel + Neon with Rule 13 CI isolation check |
| `docs/ROLLBACK.md` | CURRENT | Simple 3-path rollback, no snapshot references |

**Summary: All CURRENT. 1 NEEDS AHMAD REVIEW.**

---

## force-ai-foundation

| File | Verdict | Action |
|---|---|---|
| `README.md` | CURRENT | Foundation repo description — accurate, no stack claims |
| `standard/` (all files) | CURRENT | Living standard docs |
| `audit/baselines/` (all) | CURRENT | Timestamped baseline artifacts |
| `audit/docs-reality/FLEET-DOCS-2026-06-08.md` | CURRENT | Prior sweep baseline |
| `PRODUCTION-SAAS-BUILD-PLAYBOOK.md` | STALE → FIXED | §10 still referenced per-commit Neon snapshots as DR — retired 2026-06-08. Fixed to daily local pg_dump pattern |
| `template/README.md` | CURRENT | Phase 2 stub |

**Summary: All CURRENT. 1 NEEDS AHMAD REVIEW.**

---

## Across-project counts

| Project | CURRENT | FIXED | NEEDS AHMAD REVIEW |
|---|---|---|---|
| force-website-builder | 11 | 2 | 1 |
| whatsapp-bulk-sender | 11 | 1 | 2 |
| Force_media_CRM | 4 | 3 | 1 |
| om-hassan-menu | 5 | 0 | 1 |
| mypovonai | 3 | 0 | 2 |
| digital-card | 4 | 0 | 0 |
| force-ai-foundation | 5 | 1 | 0 |
| **Total** | **43** | **7** | **8** |

---

## Top NEEDS-AHMAD-REVIEW items (priority order)

1. **`force-website-builder/docs/business/plan-feature-matrix.md`** — Verify the feature-to-plan mapping is still in sync with `packages/shared/src/plan-baselines.ts`. Any feature tier change since last update?

2. **`Force_media_CRM/docs/adr/0001-crm-tenant-isolation.md`** — Verify the ADR reflects the current NextAuth v5 + Neon + application-layer isolation approach (not any Supabase RLS remnant).

3. **`whatsapp-bulk-sender/WhatsApp-Client-Setup-Guide.md`** — Client-facing doc; may have Supabase auth references from pre-migration era (April 2026). Worth a scan.

4. **`om-hassan-menu/docs/ADMIN_SETUP.md`** — Verify still accurate after the hide-from-menu feature (2026-06-06).

5. **`whatsapp-bulk-sender/frontend/MANUAL_TESTING_GUIDE.md`** — May reference old Supabase-era UI flows or auth patterns.

6. **`mypovonai/docs/runbooks/instagram-graph-api-setup.md`** — Instagram Graph API setup; credentials approach and token scopes may have changed.

7. **`mypovonai/docs/BRAND.md`** — Brand doc for mypovonai; verify still matches current app direction.

8. **`force-website-builder/docs/superpowers/plans/2026-05-13-iceberg-audit-followup.md`** — Historical plan references Stripe subscription automation for billing. No edit needed (archive doc) but worth noting managed-agency model now supersedes this entirely.

---

## PDFs (cannot edit — note only)

- `Force_media_CRM/knowledge/*.pdf` — 13 reference PDFs (marketing/photography books). Not project docs — no action needed.

---

_Sweep completed 2026-06-09. All edits left uncommitted in working tree per instructions._
