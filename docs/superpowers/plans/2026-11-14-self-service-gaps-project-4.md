# Self-service gaps (Project 4) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every merchant capability that today needs a super admin or operator (or has only an API) becomes a merchant screen or action in Ebda Store and Ebda Chat; super admin keeps a full override, used only for critical cases.

**Architecture:** Each gap is a thin merchant route on the existing service (the service already holds the rule), a screen in the merchant app, and a capability-registry entry plus help article in the same PR. Tenant id always comes from auth, never the body; Zod at every edge; the action boundary of the spec (section 4) decides the policy: money, deletion, customer messaging, more than 20 items, checkout-visible and price changes are `confirm` (server-issued single-use token bound to the previewed payload hash); the rest is `preview` or `free`. Super-admin routes stay and get a written reason annotation (section 10b.7).

**Tech Stack:** Hono on Cloudflare Workers, Durable Objects, D1/Postgres (Store uses Prisma), Next.js admin (Store), React web (Chat), Zod, Vitest.

**Spec:** `docs/superpowers/specs/2026-11-14-self-service-and-ebda-assistant-design.md` (sections 4, 7, 9, 10, 10b, Appendix A). Audit: `business/ebda/audits/2026-11-14-self-service-and-ai-assistant-audit.md` (local, outside git) plus the two capability catalogues in the same folder.

## Scope and what is already done (measured 2026-11-14)

- **Excluded:** InstaPay (A5, A6; ebda-store#765, ebda-whatsapp#87) and the AI assistant (A14's assistant half; plan `2026-11-14-smart-layer-engine-and-adapters.md`).
- **Already shipped, not duplicated:** A1, A2, A4 (ebda-whatsapp#81 templates screen, create/edit/delete, rejection reason). **A3 is also built** (ebda-whatsapp `src/core/numbers/numbers.ts:112-113` calls `installStarterOnConnect`, `src/core/starter-templates.ts` installs the set and syncs from Meta); the register row "first template set auto-installed" is stale and Task 0 only corrects it with evidence.
- **In this plan:** A7-A13, A15-A36 (A14 = support-request channel only).

## Global Constraints

- Cloudflare-only runtime; Arabic-first RTL, Egyptian Arabic copy in full sentences, English second; Ebda brand: no orange, night + Ebda gold; product names always "Ebda <X>", never a bare "Ebda".
- Money paths: integer piastres, idempotent, compensating rollback for any external call after a DB write. Money-touching PRs carry the label `risky` and stop at PR.
- Every merchant action: tenant id from the session, role check at execution, audit-log row, explicit confirm token where the boundary requires it.
- Documentation parity: each task ships a capability JSON (`capabilities/<id>.capability.json`, shape of `ebda-whatsapp/capabilities/contacts.erase.capability.json`) and a help article (EN + AR) in the same PR; old super-admin copy ("contact support") is replaced.
- Super-admin override stays on every route and is annotated with its reason.
- Never merge; PR body sections `## Verified`, `## Not verified`, `## Cost-if-wrong`.

## Review Focus

- Merchant triggers an action twice (double click, retry): idempotent, one effect, one charge.
- Merchant of store A names store B's id in path or body: 404, nothing read or written.
- Staff member below owner calls an owner-only action (delete, add-on purchase): 403.
- Confirm token replayed, or used with an edited payload: refused.
- Action in flight with money pending (open order, unpaid invoice, wallet balance): refused with a plain sentence, not a 500.

## Task 0: Register hygiene

**Files:** `business/ebda/EBDA-PROGRAM-REGISTER.md` (local), no repo change.
- [ ] Update rows "first template set auto-installed" (evidence above), "9 super-admin-only Store", "4 operator-only Chat" with this plan's task ids; recount summary.

## Store tasks (repo `ebda-store`, worktree branch `feat/self-service-<theme>`)

### Task 1 (A15, Medium): merchant deletes a custom page
**Theme:** `pages-and-scans`. **Files:** `apps/api/src/routes/pages.routes.ts:156-160` (replace `requireSuperAdmin` with store_admin; keep legal-page guard), `apps/admin/src/app/stores/[id]/pages` (delete button + confirm dialog), `capabilities/store.pages-delete.capability.json`, help `apps/help/content/{en,ar}/` article.
**Test first:** `pages.delete.test.ts`: store_admin deletes own custom page 200; legal page 403 `legal_page_protected`; other store's page 404; staff below store_admin 403. Fails on old code (403 for store_admin).
**Policy:** `confirm` (deletion). **Override:** super_admin still deletes any page.
- [ ] write failing test, run, implement route + UI + registry + help, run touched tests, commit.

### Task 2 (A17, Medium): "Scan now" for reorder, low-stock, deadstock
**Theme:** `pages-and-scans`. **Files:** `apps/api/src/routes/smart-layer.routes.ts:344-401` (store-scoped route, rate limit 1 per scan type per store per hour via existing limiter), inventory screen button, registry `platform.scans-rollups` split into `inventory.scan-now`, help.
**Test first:** store_admin triggers scan for own store only; second call within the hour 429; other store 404. **Policy:** `free` (read/derive only, no customer messages). **Override:** super_admin runs for any store.

### Task 3 (A19, Medium): 3D models gate matches the registry
**Theme:** `pages-and-scans`. **Files:** `apps/api/src/routes/product-model.routes.ts:104` (`requireFeature('product_3d')` -> tier core to match `packages/shared/src/features.ts`), i18n `products.model3d.disabled` (replace "contact support" with the real reason and upgrade link).
**Test first:** core-tier store uploads a model 200 (fails on old code when no override exists). **Policy:** `preview`. **Override:** super_admin feature override unchanged.

### Task 4 (A20, Medium): playbook drift
**Theme:** `docs`. **Files:** `docs/runbooks/SUPER-ADMIN-PLAYBOOK.md` (Roles, "How to onboard", plan change, delete store, providers, add-ons, VAT, scans now describe the merchant path and the override). **Test:** docs guard (`scripts/check-docs-parity.*` if present, else grep test that the playbook no longer says plan is read-only for merchants).

### Task 5 (A11, High): delete own store, close account, full-data export
**Theme:** `store-lifecycle`. **Files:** `apps/api/src/routes/store.routes.ts:830-837` (owner route `DELETE /stores/:id` behind confirm token + typed store slug + password/MFA step-up), `services/account-closure.service.ts` (guards money in flight, billing-parent refusal already coded; add 14-day cooling-off mirroring Chat offboarding), `apps/admin` settings danger zone + export button, `apps/accounts` closure screen. Registry `account.export-erase-close`, `platform.store-delete`.
**Test first:** owner with open orders/unpaid invoice refused with named reason; owner of clean store gets 202 scheduled + cancel within cooling-off; staff 403; token replay refused; export returns only own store data. **Policy:** `confirm`, `irreversible` after cooling-off. **Override:** super_admin delete stays (support/test stores), annotated. **Label:** `risky` (deletion).

### Task 6 (A13, High): see the reason for an AUP suspension and appeal
**Theme:** `trust-and-support`. **Files:** `store.routes.ts:869-874` (store a `suspensionReason` and `suspendedAt` the merchant can read at `GET /stores/:id/suspension`), `POST /stores/:id/suspension/appeal` (Zod `{message<=1000}`, one open appeal per store, writes audit + emails support), admin banner + form. Decision stays super admin (KEEP).
**Test first:** suspended store reads reason; second appeal 409; non-suspended 404. **Policy:** `preview`.

### Task 7 (A14, High): in-product support request (non-assistant half)
**Theme:** `trust-and-support`. **Files:** `apps/api/src/routes/support.routes.ts` (new: `POST /stores/:id/support-requests` Zod `{topic, message, pageUrl}`; rate limit 5/day; emails the support inbox and stores the row), admin "Contact Ebda Store" dialog linked from every "contact support" string (grep `apps/admin/src/i18n/messages/*.json`; the 8+ strings point to the dialog). The assistant handoff reuses this route later.
**Test first:** valid request stored + emailed once; 6th in a day 429; no cross-store read. **Policy:** `confirm` (sends a message to Ebda, not to customers; preview + submit).

### Task 8 (A16, Medium): protected brand slug claim and daily store-creation cap request
**Theme:** `trust-and-support`. **Files:** `onboarding.routes.ts:47`, `services/onboarding.service.ts:106,222-297` (a `POST /onboarding/slug-claims` with evidence upload id; super admin reviews: KEEP for abuse/brand), screen in onboarding. **Test first:** claim stored pending; duplicate 409; unauthenticated 401. **Policy:** `preview`.

### Task 9 (A10, High): VAT registration change request + AI pre-check
**Theme:** `tax`. **Files:** `platform-tax.routes.ts:21-24,94`, new `POST /stores/:id/tax/change-request` (Zod, document keys), AI pre-check extracts fields only; plain code compares against the entered number; flags go to super admin (legal stays human). Replace "contact Ebda Store support" i18n `taxVerification.verifiedNote`. **Test first:** change request creates pending row, merchant stays on the old verified state meanwhile; mismatch flagged not approved. **Policy:** `confirm`. **Override:** super admin approve/reject/revoke stays (legal).

### Task 10 (A23, Low-Medium): MFA recovery codes
**Theme:** `tax` is wrong place; **Theme:** `account-security`. **Files:** `apps/accounts` (generate 10 single-use recovery codes at MFA enrolment, hashed; use one at login; regenerate with step-up), `docs/runbooks/mfa-recovery.md` (staff script stays as last resort, annotated). **Test first:** code works once then fails; hashed at rest; regenerate invalidates old set. **Policy:** `confirm`. **Label:** `risky` (auth).

### Task 11 (A24, Medium): store activity / audit log screen
**Theme:** `account-security`. **Files:** existing audit-log API filtered to the store, `apps/admin/src/app/stores/[id]/activity` read-only table (who, what, when, cursor pagination, explicit select). **Test first:** merchant reads only own store rows; PII fields masked. **Policy:** `free`.

### Task 12 (A7, High): provider activation without a super admin
**Theme:** `providers` (money-adjacent: checkout-visible; **label `risky`**). **Files:** `apps/api/src/routes/provider-activation.routes.ts:11-27,121`, `services/provider-activation.service.ts:1-12`: when the merchant's own Test connection passes (sandbox-first), auto-activate; failures return an AI-triaged plain sentence (extract-only, code decides); first connection of a provider raises a P1 alert to Ahmad (decision PROVIDERS-3). **Test first:** passing test activates; failing test does not and returns reason; test result cannot be forged in the body (server runs the check); other store 404. **Policy:** `confirm` (checkout-visible). **Override:** super admin can deactivate and force-activate.

### Task 13 (A8, High): add-on purchase and automatic entitlement
**Theme:** `billing-addons` (**money, label `risky`**). **Files:** `feature.routes.ts:25-29,96-100,145-149,207-211`, billing service (card path through the existing Kashier flow in `routes/billing.routes.ts`), admin add-ons screen replacing "A super admin must enable it" (`floatingWidget.featureNotEnabledBody`, `wallet.checkoutOff`). **Test first:** successful card payment webhook grants the entitlement exactly once (replayed webhook = no second grant); failed payment grants nothing; cancel removes at period end; staff below owner 403. **Policy:** `confirm`. **Override:** super admin grant/revoke stays (goodwill).

### Task 14 (A9, High): AI quota raise and credit top-up, Store side
**Theme:** `billing-addons` (**money, `risky`**). **Files:** `lib/ai-quota.ts` (`DEFAULT_STORE_DAILY_REQUEST_CAP = 150`), `services/ai.service.ts:153` (error text names the self-service path), plan-tied allowance read from `plan-baselines.ts`, paid top-up pack through Task 13's checkout, remaining shown in the AI settings screen. **Test first:** top-up raises the store cap for the day/month purchased, idempotent per payment id; the global platform cap still applies. **Policy:** `confirm`.

## Chat tasks (repo `ebda-whatsapp`)

### Task 15 (A12, High): erase and export a contact from the inbox
**Theme:** `contacts-data`. **Files:** web contact panel (`web/src/...`) calls the existing owner route `DELETE /stores/:storeId/contacts/:waId` and export; help 13 gets the erasure section; registry `contacts.erase` gaps closed. **Test first:** component test: erase needs typed confirmation, calls the route once, removes the row; server test: non-owner 403, other workspace 404. **Policy:** `confirm`, irreversible. **Override:** operator route stays on the written-request path, annotated.

### Task 16 (A29, A25-A27, A30, Medium): inbox and contacts screens for API-only features
**Theme:** `inbox-tools` (one PR). Quick replies (A25), internal notes (A26), conversation tags (A27), contact tags edit (A29), saved segments create/edit/delete (A30): each is a small panel over the existing route (`src/routes/contacts.ts:38-66` and siblings); no server change except missing Zod. **Test first:** one component test per panel (create, edit, delete, error state) plus a server 404 cross-workspace test. **Policy:** `preview`; segment delete `confirm`.

### Task 17 (A28, A31-A33, Medium-Low): toggles and throughput
**Theme:** `bot-settings`. Sending throughput and tier usage panel (A28); ordering-bot, order-confirmation and store-login-code toggles (A31-A33) in settings. **Test first:** toggle persists, audit row written, owner-only; throughput shows the tier from the existing throttle. **Policy:** `preview`; A32 `confirm` (sends customer messages).

### Task 18 (A34-A36, Medium): connect and integrate screens
**Theme:** `integrations`. Link an existing Meta catalogue (A34), agent connectors webhook/Odoo (A35, secret encrypted with `AGENT_SECRETS_KEY`, never echoed), integration tokens create/revoke (A36, shown once, hashed). **Test first:** token shown once and hash-only at rest; connector secret never in a GET response; non-owner 403. **Policy:** `confirm` for token creation and connector save.

### Task 19 (A21 and A22, Medium): number funding and yearly-refund quote
**Theme:** `money-surfaces` (**money, `risky`**). **Files:** `src/routes/operator.ts` funding, `executeYearlyRefund` quote half. Merchant sets who pays Meta for an own number (platform line stays operator); merchant sees a read-only yearly-refund quote (shortened months, debt settled, cash refund) and confirms the request; card refund execution stays human. **Test first:** quote equals what the operator route would execute for the same order; confirm creates a request, never moves money; platform line refused to merchants. **Policy:** `confirm`.

### Task 20 (A18, Medium): shared-number stores see why marketing is off
**Theme:** `integrations`. **Files:** campaigns screen `web/src/components/CampaignForm.tsx` shows "campaigns need your own number" with the connect link (rule WA-SHARED-NOCAMP-1 stays). **Test first:** shared workspace sees the notice and no submit; own-number workspace does not.

### Task 21 (A9, Chat half, High): Chat AI credits top-up screen
**Theme:** `money-surfaces`. **Files:** existing `agent.credits-topup` route and credits ledger (`src/core/ai/credits.ts`), low-credit warning links to a top-up screen using the wallet card checkout (`routes/wallet.ts:57`). **Test first:** top-up adds credits once per payment id. **Policy:** `confirm`. **Label:** `risky`.

## Order of PRs (one per repo per theme, never stacked, high severity first)

1. ebda-whatsapp `contacts-data` (Task 15) and Store `pages-and-scans` (Tasks 1-3), both safe and independent
2. Store `store-lifecycle` (5), `trust-and-support` (6-8), `tax` (9), `account-security` (10-11)
3. Money themes, `risky`, stop at PR: Store `providers` (12), `billing-addons` (13-14); Chat `money-surfaces` (19, 21)
4. Chat `inbox-tools` (16), `bot-settings` (17), `integrations` (18, 20); Store `docs` (4)

## Self-review

Coverage: A7-A13, A15-A36 each map to a task (A14 = Task 7; assistant half excluded); A1-A6 excluded with evidence. Types: confirm-token and policy names follow spec section 4 and 10b.4. The Store capability registry and guards arrive with ebda-store#760; Store PRs add `capabilities/*.json` files (no conflict) and pass the guard once #760 merges.
