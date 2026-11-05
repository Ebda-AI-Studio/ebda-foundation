# Standards incidents from the predecessor fleet (frozen)

The standards in `os/standard/` keep their incidents only as neutral examples. The original, product- and client-specific narratives live here. Source: tag `final-before-ebda` of the predecessor OS repo.

## unified-audit: the checkout P0 (2026-06-10)

A MyFatoorah checkout P0 showed only `Error: Invalid data` in Sentry. Reading the code alone could not say why. Triangulating Sentry (endpoint `POST /payments/create` plus the provider stack frame), the code (email is optional at checkout and flows as `''`), the existing comment ("MyFatoorah rejects empty emails") and the screenshot (no email entered) pinpointed it: a blank `CustomerEmail` sent to MyFatoorah. The Railway logs held the exact `ValidationErrors` Sentry had dropped. The provider threw only `Message` and dropped `ValidationErrors`; the fix surfaced the detail into the thrown error.

The same file named GDPR/Kuwait-Law-13 erasure in the production-reality dimension.

## real-world-sense: the horse marketplace audit (2026-10-07)

A UAE vet was offered for a horse in Kuwait. A signed-out guest was told "verify your ID" instead of "sign in". About 5,000 green tests had no opinion on either. One read-only audit with four real-world lenses then found about 75 more: a fake "price collected in KWD" under a horse price the platform never collected; ended auctions shown live; a cancel-before-payment that kept the money with no refund; per-role KYC making a verified seller re-verify to bid; a video that could not be seeked. Source PRs: gcc-horse-market #197-#203, #207, #208; lens pack in [lens-pack-marketplace-launch-2026-10.md](../lens-pack-marketplace-launch-2026-10.md).

## state-transition-integrity, navigation-integrity

Sources: gcc-horse-market PR #205 (KYC review: per-role truth, revoke, no double review/submit), PR #209 (idempotent admin actions, restore never publishes drafts), PR #206 (native-stack swipe-dismiss fix and its source-scan guard).

## docs-parity criterion 9

The stale-stack example named "Kuwait gateways / Gemini / Next.js 16".

## ai-market-doctrine: calibration against the 2026-09-08 portfolio

Rules 6-9 restated the predecessor product's positioning almost verbatim (customisable storefronts plus AI on top, Arabic-first, Kuwait/GCC sizing, the anti-pattern "generic any-market features when a Kuwait-specific shape exists"); `pecannbee -> menu fleet -> FWB` was rule 8 already executed once. Corrections: distribution trailed the build; the portfolio was wide (FWB, WBS, menus, landing pages, mypovonai, quote-studio, digital-card, ghost-gcs); pricing was tier-shaped rather than "removes N KWD/month".

## reel-lenses-2026-09 finding A2

A web search for "where to buy Pecannbee in Kuwait" answered from a separate WordPress site (pecannbee.com) with an indexed default "Hello world!" post.

## open decision: the force-audit skill

The predecessor shipped `skills/force-audit` (148 files, a Force AI-specific audit harness excluded from default skill linking). It is NOT ported. Open decision for Ahmad: whether an Ebda-branded audit skill is built on `os/standard/unified-audit.md` and `os/audit/lenses/`, or the lens probes ship only through the audit engine. Until decided, the standards and lens packs are the audit rubric and no `/force-audit` equivalent exists.

## FWB / WBS attributions

Across `os/standard/**` the labels "FWB" (Force Store, the predecessor store product) and "WBS" (the predecessor WhatsApp Business messaging product) were rewritten to "the predecessor store product" / "the predecessor messaging product". Their PR numbers (for example #2524, #1099) remain in the text as evidence pointers into those repos' history.

## Fix round 1 (2026-11-05): detail removed from standards

- aeo-integrity / reel-lenses-2026-09: the live measurements were on the pecannbee.com.kw merchant storefront (a Force AI Website Builder store); the reel A4 crawler-policy finding was on the same domain.
- reel-lenses-2026-08/09 "Fleet status": applied to force-website-builder (2026-08-31, 2026-09-04); the 2026-09-03 P0 was a gateway refund on a cash-on-delivery order that refunded an arbitrary other order (also the source of `absent-filter-matches-everything`).
- cicd (runner hook): a broken "Complete runner" hook silently blocked every PR on force-website-builder and whatsapp-broadcaster.
- agent-security: the canonical lethal-trifecta example was the whatsapp-broadcaster / whatsapp-bulk-sender bot runtime.
- data-ui-coverage: the 2026-06-09 admin deep audit of FWB scored 1.45/2 (criterion 5 split-brain: primaryColor vs page-builder palette, fonts, hero, announcement bgColor, whatsapp number x4, enable-blog x2).
- feature-flags: the managed-agency note applied to Force AI products (the operator onboards every client; default `w_enterprise`-style full access); WBS PR #38.
- skill-hygiene: FWB PR #1099 was written and AI-reviewed by the same vendor; the lens report lived in force-website-builder `docs/audits/`.
- 00-index lens rows 38/39-41: pecannbee measurement; the FWB sku/index incidents behind `migration-safety`.
- Memory-slug citations (`reference-force-ai-production-grade-standard`, `feedback-force-ai-*`) were deleted from `sources:` lines; they are memory, not repo content.
- The `/force-build` and `/force-audit` commands are not ported (no Ebda skill by those names); standards now say "an audit run".

## Playbook legacy stack (retired 2026-11-05)

The previous playbook prescribed: Prisma + Postgres on Neon (pooled and direct URLs), Postgres RLS with a per-request GUC (`app.current_store_id`, `withRlsBypass`, `runInTenantContext`, non-owner role `force_app` versus owner `neondb_owner`, the owner-to-app-role cutover trap), Redis two-tier cache and `rate-limit-redis`, Inngest or BullMQ for jobs, Socket.io with `@socket.io/redis-adapter`, Redis-lock cron leader election, Railway for the API (railpack `npm ci --omit=dev` simulation) and Vercel for frontends (`vercel env ls` isolation check), `scripts/backup-db.sh` pg_dump rotation. The playbook now carries a verified "Current stack" table (Workers, D1, Durable Objects, KV, Queues, Workflows, R2, Workers AI, Vectorize, accounts service, Telegram alerts) and keeps the legacy mechanics only as marked principles.
