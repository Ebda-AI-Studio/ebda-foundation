# Self-service + the Ebda assistant — design

- **Date:** 2026-11-14
- **Owner:** Ahmad Sharaf (Ebda AI Studio)
- **Status:** draft for Ahmad's approval
- **Inputs:** `business/ebda/audits/2026-11-14-self-service-and-ai-assistant-audit.md` (22 self-service gaps, builder-AI gap, AI plumbing inventory), `business/ebda/audits/2026-11-14-chat-agent-audit.md`, decisions of 2026-11-14 in `business/ebda/EBDA-PROGRAM-REGISTER.md` section 1 (both files live in Ahmad's local business folder, outside git).

## 1. Intent

Ebda AI Studio is an AI-native, self-service company. In Ahmad's words: "ابدأ chat and ابدأ store, it's all about self-service. There is no super admin controlling someone's account except for something exceptional ... build this into the foundation." A merchant signs up, picks a plan, brings their data, builds the store in the editor, connects WhatsApp, writes and submits their own Meta templates and runs everything without waiting for Ebda staff. Everything must be easy to do and easy to learn. Ahmad steps in only for real exceptions: an error he wants to look at, abuse, legal, critical incidents.

Today that is not true: 22 places need staff or have no merchant screen (4 block onboarding), the page-builder AI can only restyle what is already on the page, and there is no "how do I…" help inside the products.

## 2. Goals, non-goals, anti-goals

**Goals**
1. Every merchant capability is doable by the merchant in the product, with a learnable flow. Super-admin-only paths carry a written reason.
2. One assistant inside Ebda Store and Ebda Chat that answers "how do I…" from Ebda's own help content, and DOES the task when the merchant could do it themselves, under the action boundary (section 4).
3. The assistant writes WhatsApp message templates that Meta approves, submits them on the merchant's own WhatsApp Business account, tracks the verdict and fixes rejections.
4. The page-builder AI knows the store and every editor capability and handles complex requests (project 3).
5. The rule is enforced in ebda-foundation (a standard plus a guard), so every future Ebda product inherits it.
6. Every feature, live or planned, now or future, is known to the assistant through a capability registry enforced in CI (section 6.8).

**Non-goals**
- The shopper-facing WhatsApp agent (Ebda Chat's customer bot) — separate work, already in PRs.
- AI auto-posting in accounting — decided separately: every AI category/match needs a merchant click.
- Replacing human support entirely: a merchant can always reach Ebda; the assistant hands off with context.

**Anti-goals (a failure even if it "works")**
- The assistant claims it did something it did not do, or does something the merchant did not see first.
- It spends a merchant's money or messages their customers without an explicit "yes".
- It reaches super-admin powers or another merchant's data.
- It answers in stiff English-first copy: Ebda's voice is Egyptian Arabic in full sentences, English second.
- It burns AI credits silently: every AI cost is visible and capped.

## 3. Success

- A new merchant goes from signup to a live store with approved WhatsApp templates and an active plan without contacting Ebda (the existing register row "Timed unaided-merchant test (< 10 min)" becomes the acceptance test).
- Zero super-admin actions are needed in a normal merchant week (measured from the audit log: super-admin actions per active store).
- Assistant quality is measured before launch on a golden task set (section 6.6).

## 4. The action boundary (Ahmad, 2026-11-14, "i agree to all")

1. The AI may do anything the merchant could do themselves in the dashboard.
2. It always shows a preview first ("here's what I'll change"), with undo afterwards.
3. Anything touching money, deleting data or sending messages to customers needs an explicit "yes".
4. It never touches super-admin powers.

Every action the assistant can take is declared with exactly one policy: `free` (read-only or harmless) · `preview` (show the change, apply on accept, undo available) · `confirm` (preview + an explicit "yes" step; money, deletion, customer messaging) · `forbidden` (never exposed). The policy lives next to the action definition, not in the prompt.

## 5. Approaches (chosen: A)

| | Approach | Trade-off |
|---|---|---|
| **A (chosen)** | One shared assistant engine in ebda-foundation; each product plugs in its actions (an MCP-style tools layer) and its help articles | Built once, same behaviour everywhere, future products get it free; more upfront foundation work |
| B | Separate assistants per product (Store extends its Gemini AI service, Chat extends its Workers AI agent) | Faster first version; two engines drift, two rule sets, two bug sets |
| C | Build only on the existing Store merchant MCP | Clean actions layer, but it doesn't cover Chat, so it becomes part of A anyway |

Ahmad chose A ("a is then"), with C's tools layer as the actions part.

## 6. Project 2 — the Ebda assistant (engine in ebda-foundation)

### 6.1 Shape
A shared TypeScript module in `@ebda/foundation` (new export, e.g. `./assistant`), runtime-agnostic (Cloudflare Workers), with product adapters:

- **Engine** (foundation): conversation loop, model routing, tool calling, the policy gate (section 4), preview/undo protocol, credits + rate limits, PII masking, grounding (help retrieval), audit trail, eval harness.
- **Product adapter** (Store, Chat): the list of actions (tools) with their policy, how to call them as the signed-in merchant, how to build a preview and an inverse (undo) for each `preview`/`confirm` action, the help corpus, and the product's quota hooks.
- **UI**: a side panel in Store admin and in the Ebda Chat web app (same component contract, product styling via the Ebda design tokens; RTL first). Preview cards with Apply / Undo; a distinct confirm step for `confirm` actions; "show me where" deep links into the right screen.

### 6.2 Models
Workers AI is the default (Ahmad: "we're using Cloudflare AI, Workers AI"). The engine routes per job: chat and "how do I" on the default Workers AI model; tasks that need stronger reasoning (complex page-builder plans, template compliance checks) may route to a stronger model. Model ids are configuration, never hard-coded; the Gemini alias rule (`*-latest`) applies wherever Gemini is used.

### 6.3 Acting as the merchant
Actions run with the merchant's own session and permissions: the assistant can never do more than the signed-in user can (team roles included). The audit trail records `actor = user X via assistant` for every applied action, with the preview that was shown.

### 6.4 Grounding ("how do I…")
Store: the 44 bilingual help articles in `apps/help` (they carry `appPath`, used for deep links). Chat: `docs/help`. Indexed per product (vector search with the existing embedding setup), answered with citations and a deep link. If the help content doesn't cover a question, the assistant says so and offers a handoff; a weekly report lists unanswered questions so help articles get written.

### 6.5 Limits, cost, privacy
- Per-store daily caps (requests + tokens) through the product's existing quota (Store `assertAiQuota` / `recordUsage`; Chat credits ledger). The merchant sees usage; hitting the cap explains how to raise it (self-service top-up — a project-4 gap).
- Rate limit per user per minute; prompt-injection hardening: page content, product text, customer messages and help text enter as fenced data, never instructions.
- PII masked before any model call (reuse Chat's masking); no customer PII in logs; conversation retention bounded and covered by account erasure.

### 6.5b Credits (Ahmad, 2026-11-14)
"How do I" answers and small tasks are free within a generous per-store daily cap; heavy jobs (writing many templates, big page-builder redesigns) use the plan's AI credits, and the cost is shown before they run. The same pool the product already uses (Store `assertAiQuota`/`recordUsage`, Chat credits ledger); the assistant's usage is labelled separately in the meter.

### 6.6 Quality
A golden task set per product (Egyptian Arabic, Franco, English): "how do I connect my domain", "add a 10% discount for Eid on all abayas", "why was my template rejected", multi-step tasks, out-of-scope and super-admin requests (must refuse), money/delete/message tasks (must hit the confirm step). Run against the real model behind a flag (not in default CI), scripted in CI for structure. A launch threshold is set after the first real run.

### 6.7 The template writer (first big skill)
Merchant: "عايز رسالة أبلغ بيها العميل إن الأوردر اتشحن". The assistant:
1. Picks the right Meta category (utility vs marketing vs authentication) and language.
2. Writes the body with variables plus the example values Meta requires, buttons if useful, inside Meta's limits.
3. Checks it locally against Meta's rules before submitting (length, variable format, category heuristics, banned patterns).
4. Shows the preview → on "yes" (it is a submission to Meta on the merchant's account: `confirm`) submits to the merchant's OWN WABA via the existing `templates-api.ts`.
5. Tracks the review status (webhook or sync); on rejection explains the reason in plain Egyptian Arabic and proposes a fixed version.

This needs the project-1 template screen (the assistant and the screen share the same API), so project 1 ships first.

### 6.8 The capability registry — every feature, now and future, is in the assistant (Ahmad, 2026-11-14)
Ahmad: "there is things are not built yet so they must be counted as well so this be a part of the foundation where any new feature is included in the ai".
- Each product keeps a **capability registry** (source-controlled, machine-readable) that is the contract between the product and the assistant. One entry per merchant capability: id, area, titles (Egyptian Arabic + English), page/screen, API actions, plan gate, roles, assistant policy (`free` / `preview` / `confirm` / `forbidden`), undo, help article, example merchant questions (Arabic, Franco, English), edge cases, and a **status: `live` | `in-pr` | `planned`**.
- **Planned features count:** not-built items (from the program register and open plans) are entries with status `planned`, so the assistant can say what is coming and when it ships, and the plan tracks them. When a feature ships, its entry flips to `live` in the same PR.
- **Enforced in ebda-foundation:** a CI guard fails any PR that adds a merchant page, route or action without a registry entry, or a `live` entry without a help article and example questions. So no future feature can ship without the assistant knowing it. The registry also feeds the help index, the golden eval set (every `preview`/`confirm` entry gets a must-confirm test) and the self-service guard.
- The first registry is generated from the full Store and Chat capability catalogues (2026-11-14 audits: `business/ebda/audits/2026-11-14-store-capability-catalogue.*` and `...-chat-capability-catalogue.*`, in Ahmad's local business folder).

## 7. Project 1 — self-service standard + the 4 blockers

1. **Standard** `os/standard/self-service.md` in ebda-foundation: the principle, the action boundary, and the rule "every merchant capability has a merchant screen; super-admin-only needs a written reason (abuse, legal, money dispute, platform-wide config, critical incident)". Plus a guard that fails CI when a new super-admin/operator-only route has no reason annotation (exact mechanism left to the builder; it must run in Store and Chat CI).
2. **Chat templates screen (blocker #1):** merchant creates/edits a template for their own WABA, submits, sees Meta's status and rejection reason, resubmits, and uses approved templates in campaigns. Fix help doc 04 to match.
3. **Starter templates on connect (blocker #2):** when a merchant connects a number, install the default template set and sync existing templates from Meta automatically.
4. **InstaPay auto-confirm (blockers #3 Store, #4 Chat)** — Ahmad: "yes" to AI confirming when the receipt matches:
   - The AI reads the receipt (existing receipt reader): amount, Ebda's InstaPay handle as recipient, date within 48 h, a reference and image never seen before (duplicate check across all merchants).
   - All match → the plan / top-up activates instantly. Anything off → waits for Ahmad.
   - Guards: a cap on a merchant's first auto-confirmed payment (about one month of their plan); the duplicate-receipt check.
   - Ahmad gets one daily digest of auto-confirmed payments with a one-tap "not received" that reverts the activation.
   - **Revert (Ahmad, 2026-11-14):** "not received" puts the plan back to unpaid with a 48-hour grace: the merchant is told plainly to upload a correct receipt or pay by card before paid features pause; unused Chat top-up credits from that payment are removed. Idempotent; logged.
   - **First-payment cap (Ahmad):** the AI confirms a merchant's first payment alone only up to one month of the plan they chose (Chat top-ups: the Chat plan's monthly price); bigger first payments (e.g. a yearly plan) wait for Ahmad. After one clean payment, no cap.
   - **Duplicates (builder note):** a platform-global index of receipt reference + image hash; a hit on any merchant blocks auto-confirm.
   - **Digest channel (Claude's call):** the existing Telegram channel to Ahmad (@EbdaAIStudiobot), one message a day plus an immediate message for anything waiting on him.
   - Builder's call to confirm: whether Ebda's own bank statement can be imported for automatic reconciliation; if not available yet, the daily digest + one-tap revert is the v1 safety net.

## 8. Project 3 — page-builder AI v2 (own short design later)

Today (audit Part B): restyles, re-orders and hides existing sections with preview + undo; sees only section ids and scalar settings; Gemini flash-lite; 12 operations / 500 characters per ask; 150 requests + 200k tokens per store per day. Target: knows products, categories, brand, look, locale and viewport, and every editor capability; can add/move blocks, link products and collections, set images and links, fix mobile layouts, change the look, create pages; plans multi-step changes and shows them as one preview. Built on the project-2 engine with the Store adapter.

## 9. Project 4 — the remaining 18 gaps (own short design later)

From the audit Part A rows 5-22 (8 high, 7 medium, 3 low): provider activation, add-on grants, AI quota raise / credit top-up, VAT verification, deleting your own store, an in-product help/support channel, and the rest. Each becomes a merchant screen or an assistant action, or stays super-admin with a written reason.

## 10. Constraints

- Cloudflare-only runtime (Workers, Durable Objects, D1, R2, Vectorize, Workers AI).
- Arabic-first (RTL, Egyptian Arabic copy in full sentences), English second; Ebda brand: no orange, night + Ebda gold; product names always "Ebda <X>", never a bare "Ebda".
- Five testing layers on revenue/PII paths; tests that exercise real storage paths, not mocks that hide bugs.
- Money paths: integer piastres, idempotent, compensating rollback for external calls.
- One shared engine: no product copies its own fork.

## 10b. Claude's calls (from the builder check, 2026-11-14 — Ahmad may override)

1. **Packaging:** the engine is pure TypeScript source in `@ebda/foundation` (vendored like the existing modules, lock-hash + parity test keep it one engine); it takes its bindings (AI, vector index, storage, quota) from the product adapter, so it holds no Cloudflare bindings itself. Not a separate shared Worker (adds a network hop and a second auth boundary).
2. **State and undo:** apply and undo go through each product's existing mutation APIs; the adapter supplies the inverse for every `preview`/`confirm` action. The engine keeps a small journal (conversation, previews, applied actions, undo tokens) through an adapter storage interface (Store: the store's DO/D1; Chat: the workspace DO). Undo window 24 h. A preview carries the version/etag of what it read; if the data changed before apply, the engine re-previews instead of applying.
3. **Acting as the merchant:** the engine runs inside each product's own Worker in the merchant's request; every tool call goes through the product's normal authorization (session, role, MFA, store scoping) at execution time, with no new or delegated token. A role or MFA change takes effect on the next action.
4. **The confirm step:** a server-issued, single-use token bound to the hash of the exact previewed payload, satisfied only by the merchant pressing the confirm button in the UI. A typed "yes" in chat is not enough, and the model can never produce or satisfy it. Golden tests assert this.
5. **Sequencing:** project 1 (templates screen, starter set, InstaPay, standard) and the assistant's "how do I" answering can proceed in parallel; the template-writer skill waits for the project-1 templates API/screen. This document covers projects 1 and 2; 3 and 4 get their own short designs. Quality over date (Ahmad 2026-11-10): no fixed launch date governs the order.
6. **Help grounding:** help articles get their own namespace in each product's existing vector index (Chat `ebda-wa-kb`, Store's product-vectors index), re-embedded when help content changes (on deploy, skip-if-unchanged by content hash).
7. **Self-service guard:** recognises operator/super-admin routes by their existing middleware/role checks in each repo; existing routes go into a baseline allowlist each with a reason to fill; CI fails only on NEW unannotated routes and on a baseline that grows.

Today's Meta template path (from the audit): the owner-only API exists in Ebda Chat (`src/routes/templates.ts` submit/sync/install-defaults, `src/core/meta/templates-api.ts`), but no merchant screen calls it and help doc 04 describes a screen that doesn't exist; project 1 builds the screen on that API.

## 11. Left to the builder

- Module boundaries inside `@ebda/foundation` and how products vendor it (follow the existing foundation package pattern).
- The tools-layer schema (MCP-compatible), the preview/inverse contract, and the UI component split.
- The guard mechanism for the self-service standard.
- Which Workers AI models per job, within the routing rule.
- Exact Meta template rule checks (verify against current Meta docs).

## 12. Open items (Ahmad)

- None blocking. Project 2's launch quality threshold is set after the first real eval run.
