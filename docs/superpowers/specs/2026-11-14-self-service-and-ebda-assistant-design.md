# Self-service + the Ebda AI Smart Layer — design

- **Date:** 2026-11-14
- **Owner:** Ahmad Sharaf (Ebda AI Studio)
- **Status:** draft for Ahmad's approval
- **Inputs:** `business/ebda/audits/2026-11-14-self-service-and-ai-assistant-audit.md` (22 self-service gaps, builder-AI gap, AI plumbing inventory), `business/ebda/audits/2026-11-14-chat-agent-audit.md`, decisions of 2026-11-14 in `business/ebda/EBDA-PROGRAM-REGISTER.md` section 1 (both files live in Ahmad's local business folder, outside git).

## 1. Intent

Ebda AI Studio is an AI-native, self-service company. In Ahmad's words: "ابدأ chat and ابدأ store, it's all about self-service. There is no super admin controlling someone's account except for something exceptional ... build this into the foundation." A merchant signs up, picks a plan, brings their data, builds the store in the editor, connects WhatsApp, writes and submits their own Meta templates and runs everything without waiting for Ebda staff. Everything must be easy to do and easy to learn. Ahmad steps in only for real exceptions: an error he wants to look at, abuse, legal, critical incidents.

Today that is not true: 22 places need staff or have no merchant screen (4 block onboarding), the page-builder AI can only restyle what is already on the page, and there is no "how do I…" help inside the products.

**Scope of the rules (Ahmad, 2026-11-14):** the AI-native, AI-first and self-service rules, the capability registry, the help-article rule and the Smart Layer apply to EVERY existing feature, every new feature, every upcoming Ebda product (CRM, ERP, Ads, Invites, Quote Studio) and anything else Ebda ships to customers. They are binding now as the foundation standard `os/standard/ai-native-self-service.md` (lens 192), not only when projects 1-4 are built.

**Super admin keeps full override (Ahmad, 2026-11-14):** "as the super admin, I can turn off sites, I can upgrade as I want ... I can do whatever I want to any store, but still they have the self-service, and I can override". Self-service means no merchant capability is staff-only; it never limits the super admin, who can suspend or turn off any site, change any plan, grant add-ons and credits, impersonate for support and change any setting on any store. Every super-admin override is audit-logged. The Smart Layer never exercises super-admin powers (action boundary rule 4), even when the super admin is the one chatting.

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

**Big changes also confirm (Ahmad, 2026-11-14):** besides money, deletion and customer messages, an explicit "yes" is required for any change touching many items (default threshold: more than 20), anything visible at checkout, and any price change. Small single edits stay preview + undo.

**Overwriting merchant content (Ahmad, 2026-11-14), ruling on NEVER-OVERWRITE-1:** background AI (autofill, nightly jobs, anything with no merchant present) still never overwrites merchant-written content; when the merchant ASKS the assistant or the page-builder AI to change something, it may, with preview + undo.

Every action the assistant can take is declared with exactly one policy: `free` (read-only or harmless) · `preview` (show the change, apply on accept, undo available) · `confirm` (preview + an explicit "yes" step; money, deletion, customer messaging) · `forbidden` (never exposed). The policy lives next to the action definition, not in the prompt.

## 5. Approaches (chosen: A)

| | Approach | Trade-off |
|---|---|---|
| **A (chosen)** | One shared assistant engine in ebda-foundation; each product plugs in its actions (an MCP-style tools layer) and its help articles | Built once, same behaviour everywhere, future products get it free; more upfront foundation work |
| B | Separate assistants per product (Store extends its Gemini AI service, Chat extends its Workers AI agent) | Faster first version; two engines drift, two rule sets, two bug sets |
| C | Build only on the existing Store merchant MCP | Clean actions layer, but it doesn't cover Chat, so it becomes part of A anyway |

Ahmad chose A ("a is then"), with C's tools layer as the actions part.

## 6. Project 2 — the Ebda AI Smart Layer (engine in ebda-foundation)

Ahmad, 2026-11-14: "ebda ai studio is ai native and ai first and fully self service and ai is what drive it and we control the layer of inputs and outputs of this ai and this is the ebda ai smart layer". The engine below is the **Ebda AI Smart Layer**: every AI input and output in every Ebda product passes through it.

### 6.1 Shape
A shared TypeScript module in `@ebda/foundation` (new export, e.g. `./assistant`), runtime-agnostic (Cloudflare Workers), with product adapters:

- **Engine** (foundation): conversation loop, model routing, tool calling, the policy gate (section 4), preview/undo protocol, credits + rate limits, PII masking, grounding (help retrieval), audit trail, eval harness.
- **Product adapter** (Store, Chat): the list of actions (tools) with their policy, how to call them as the signed-in merchant, how to build a preview and an inverse (undo) for each `preview`/`confirm` action, the help corpus, and the product's quota hooks.
- **UI**: a side panel in Store admin and in the Ebda Chat web app (same component contract, product styling via the Ebda design tokens; RTL first). Preview cards with Apply / Undo; a distinct confirm step for `confirm` actions; "show me where" deep links into the right screen.

### 6.2 Models
Workers AI is the platform (Ahmad: "we're using Cloudflare AI, Workers AI"). The engine routes per job between Workers AI models: chat and "how do I" on the bake-off winner; heavier reasoning (complex page-builder plans, template compliance checks) on the strongest Workers AI model that wins those tasks. Model ids are configuration, never hard-coded; the Gemini alias rule (`*-latest`) applies wherever Gemini is used.

**Model decision (Ahmad, 2026-11-14: "2 and do the test in 1"):** Workers AI only, no outside providers. Before building, run a bake-off of ~150 real Egyptian Arabic / Franco / English merchant prompts across the available Workers AI models (graded on correctness, Egyptian register, tool-calling reliability, latency, cost); the winner becomes the default per job (chat, tool planning, template compliance). Re-run the bake-off when Cloudflare adds models.

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

### 6.8b Every feature has a published help article (Ahmad, 2026-11-14)
Ahmad: "every existing feature or a new one must have a help article to be shared on help site".
- **Rule (foundation standard + CI guard):** every merchant capability in any Ebda product, existing or new, has a help article in Egyptian Arabic and English, published on the help site (help.ebda.app, served from ebda-store `apps/help`). The article's front-matter names its capability id(s) and `appPath`.
- **Guard:** a PR that adds or changes a merchant capability fails unless its registry entry points to a help article that exists and is published; a `live` registry entry without one fails CI (this tightens §6.8, where help was required only to reach `live`). Planned entries get their article when they ship, in the same PR.
- **One help site for all products:** Ebda Chat's guides (`ebda-whatsapp/docs/help`) are published on help.ebda.app too (a Chat section), so merchants and the Smart Layer read one source.
- **Backfill (part of the build plan):** 71 live Store capabilities and 23 live Chat capabilities have no article today, and 5 Chat guides are wrong or stale (04, 05, 06, 07/11, 09) — all written or fixed before the guard is switched to blocking.
- Help freshness (§6.9) applies: an article older than its capability's current version is flagged.

### 6.9 The Smart Layer pipeline and hardening (worldwide research, 2026-11-14)
Source: `business/ebda/audits/2026-11-14-smart-layer-worldwide-research.md` (Salesforce Trust Layer, NeMo rails, Shopify Sidekick, Intercom Fin, Meta Business AI, Amazon seller agents, Gorgias, Cloudflare AI Gateway/Agents SDK, MCP; failures: Air Canada, Chevrolet, Cursor, EchoLeak). Gap numbers refer to that report.

**One ordered pipeline (gap 1).** Every turn runs the same stages, in this order, in the engine (adapters supply data, never their own variants):
- *Input rails:* (1) secrets detector: a pasted token/key/password is redacted and the merchant is sent to the secure screen; the assistant never asks for secrets in chat (gap 19); (2) PII masking; (3) scope + abuse check: store-related requests only, polite refusal otherwise, with Ebda's own Arabic + Franco safety classifier, because Cloudflare Guardrails / Llama Guard don't support Arabic or streaming (gap 2); (4) untrusted text (customer messages, product text, imported pages, help, merchant FAQ) enters fenced as data.
- *Planning rails:* (5) tool retrieval: only the tools relevant to this turn (≤ ~15) are exposed, chosen from the capability registry, never the whole registry (gap 7); (6) per-turn budget: max tool calls, max tokens, max turns per conversation (gap 11).
- *Execution rails:* (7) Zod validation of every tool argument plus an existence + ownership check of every referenced id (gap 22); (8) the policy gate (section 4) with the **big-change triggers** decided in section 4 (gap 8); (9) one durable approval object for `confirm`: single-use, bound to the payload hash, expires after 15 minutes and re-previews; decision, decider, time and reason are stored, including rejects and expiries (gap 12).
- *Output rails:* (10) binding-claim check: plan prices, limits, refund/billing terms, legal text and policies are quoted only from typed sources (plan catalogue, store settings, legal pages), never paraphrased by the model; the Air Canada/Cursor failure (gap 3); (11) UI-truth check: every screen name, button label and `appPath` in an answer must exist in the capability registry, otherwise it's removed (gap 4); (12) link + image allowlist: only Ebda domains and the merchant's own domains render, which closes markdown/image exfiltration (gap 5); (13) Egyptian-Arabic register check.
- *Audit:* masked prompt + masked output + rail scores + preview + decision + release id per row, retention-bounded and covered by erasure; no raw customer PII (gap 18).

**Undo classes (gap 13).** Each action declares `reversible` (undo button), `compensating` (undo = an opposite action, e.g. re-enable a product) or `irreversible` (a sent WhatsApp message, a template submitted to Meta, a payment). Irreversible actions say so in the preview and are always `confirm`.

**InstaPay hardening (gap 6).** The model only extracts fields (amount, recipient handle, date, reference) into a typed object; plain code decides. Text inside the receipt image is never an instruction.

**Rollout controls (gap 10).** Per-store flag, suggest-only mode (the assistant proposes, a person clicks), shadow mode on the golden set, and a global kill switch, all changeable without a deploy.

**Versioning (gap 24).** Prompts, tool descriptions and policies are versioned config; every journal row stores the release id, so a bad release can be rolled back.

**Handoff rules (gap 17).** Triggers: low retrieval confidence, repeated failure, frustration signals, a forbidden request, or the merchant asking for a person. After handoff the assistant goes quiet on that thread until the merchant returns.

**Help freshness (gap 15).** Each registry entry carries a capability version; a help article older than its capability, or two articles contradicting each other, is flagged in the weekly report and blocks the entry from `live` once stale past a threshold.

**Quality metrics (gap 16), defined now:** answer helpfulness (thumb + calibrated judge), task completion (checked on the final store state, not the transcript), undo rate, confirm-reject rate, handoff rate, unanswered rate, cost per completed task.

**Evaluation contract (gap 9).** Golden sets graded on the final state, a judge calibrated against human labels (agreement measured), repeated runs per task (consistency, pass^k), and a release gate: a change to the model, prompts, help or tools can't ship if the golden score drops. After launch, sampled masked conversations feed a growing ground-truth set (gap 23, later).

**Cloudflare Agents SDK (gap 21), Claude's call:** keep the pure-TypeScript engine (§10b.1); where an adapter already owns a Durable Object, it may use the Agents SDK's approval primitives underneath the engine's approval object. Recorded as a ruling.

**Later (gap 20):** an optional per-store autonomy setting (always-confirm / default) and a designated approver role.

## 7. Project 1 — self-service standard + the 4 blockers

1. **Standard** `os/standard/self-service.md` in ebda-foundation: the principle, the action boundary, and the rule "every merchant capability has a merchant screen; super-admin-only needs a written reason (abuse, legal, money dispute, platform-wide config, critical incident)". Plus a guard that fails CI when a new super-admin/operator-only route has no reason annotation (exact mechanism left to the builder; it must run in Store and Chat CI).
2. **Chat templates screen (blocker #1):** merchant creates/edits a template for their own WABA, submits, sees Meta's status and rejection reason, resubmits, and uses approved templates in campaigns. Fix help doc 04 to match.
3. **Starter templates on connect (blocker #2):** when a merchant connects a number, install the default template set and sync existing templates from Meta automatically.
4. **InstaPay auto-confirm (blockers #3 Store, #4 Chat)** — Ahmad: "yes" to AI confirming when the receipt matches:
   - The AI reads the receipt (existing receipt reader) and only EXTRACTS fields; plain code decides (§6.9): amount, Ebda's InstaPay handle as recipient, date within 48 h, a reference and image never seen before (duplicate check across all merchants).
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

## 8b. Other Ebda products (Ahmad, 2026-11-11)
Ebda CRM, Ebda ERP, Ebda Ads, Ebda Invites and Ebda Quote Studio are **separate Ebda products** (crm/erp/ads/invite.ebda.app), not features inside Ebda Store. They connect to Store and Chat through shared accounts and data, and each plugs into the same Smart Layer with its own capability registry and help articles when it is built (the capability-registry and help-article guards apply to them from day one).

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

## Appendix A — the complete self-service checklist (2026-11-14)

Ahmad: "make sure, because ... you have audited store and chat and you do already know what does need to be self service". One deduplicated list merged from the self-service audit (22 rows), the Store capability catalogue (185 capabilities) and the Chat capability catalogue (172). Sources in `business/ebda/audits/2026-11-14-*`. Every item is a task in the build plan; the plan may not drop one without a written ruling.

**Project 1 — blockers (onboarding stalls without staff)**
| # | Product | Capability | Today | Source |
|---|---|---|---|---|
| A1 | Chat | Create + submit a template on the merchant's own WhatsApp account; see Meta status + rejection reason; resubmit | API only, no screen | audit #1 · `templates.create-submit` |
| A2 | Chat | Templates list with status | API only | `templates.list` |
| A3 | Chat | Starter template set + Meta sync on number connect | no caller | audit #2 · `templates.install-defaults` |
| A4 | Chat | Edit / delete a submitted template | missing | audit #17 |
| A5 | Store | InstaPay subscription payment activates via AI auto-confirm (§7.4) | super admin confirms | audit #3 · `platform.manual-payment` · `onboarding.payment-methods-and-go-live` |
| A6 | Chat | InstaPay top-up / package via AI auto-confirm | operator confirms | audit #4 · `operator.instapay-review` |

**Project 4 — the rest (each a merchant screen and/or a Smart Layer action)**
| # | Product | Capability | Today | Source |
|---|---|---|---|---|
| A7 | Store | Activate a payment/shipping provider (sandbox-first auto check + P1 alert on first connection, decision PROVIDERS-3) | super admin | audit #5 · `platform.provider-activation` |
| A8 | Store | Buy / enable an add-on outside the plan | super admin grants | audit #6 · `platform.feature-overrides` |
| A9 | Store + Chat | Raise AI quota / buy AI credits | super admin / missing | audit #7 · `agent.credits-topup` |
| A10 | Store | VAT / tax registration verification | super admin | audit #8 |
| A11 | Store | Delete own store / close account / full data export (with guards: money in flight, billing parent) | super admin | audit #9 · `platform.store-delete` |
| A12 | Chat | Erase / export a contact (data-subject request) | no screen; operator route | audit #10 · `contacts.erase` · `operator.contact-export-erase` |
| A13 | Store | See the reason for an AUP suspension and appeal | missing | audit #11 |
| A14 | Store + Chat | In-product help and support channel (the Smart Layer + handoff) | missing | audit #12 |
| A15 | Store | Delete a custom page | super admin | audit #13 |
| A16 | Store | Claim a protected brand slug; request a higher daily store-creation cap | super admin | audit #14 |
| A17 | Store | "Scan now" for reorder / low-stock / deadstock (rate-limited) | super admin | audit #15 · `platform.scans-rollups` |
| A18 | Chat | Marketing templates for shared-number stores | missing | audit #16 |
| A19 | Store | Clear message when 3D models are switched off | missing | audit #18 |
| A20 | Docs | Super-admin playbook still describes plan change + onboarding as staff work | stale | audit #19 |
| A21 | Chat | Set who pays Meta for an own number (platform line stays operator) | operator | `operator.funding` |
| A22 | Chat | Yearly-plan refund quote shown to the merchant to confirm (card refund execution stays human) | operator | `operator.yearly-refund` |
| A23 | Store | MFA recovery | super admin script | Store catalogue (invalid super-admin) |
| A24 | Store | Store activity / audit log screen | no screen | `team.audit-log` |
| A25 | Chat | Quick replies | API only | `inbox.quick-replies` |
| A26 | Chat | Internal notes on a conversation | API only | `inbox.notes` |
| A27 | Chat | Conversation tags | API only | `inbox.conversation-tags` |
| A28 | Chat | Sending throughput and tier usage | API only | `inbox.send-throttle` |
| A29 | Chat | Edit a contact's tags | API only | `contacts.tags-edit` |
| A30 | Chat | Saved segments: create / edit / delete | API only | `segments.manage` |
| A31 | Chat | Ordering bot on/off | API only | `bot.ordering-toggle` |
| A32 | Chat | Order confirmation messages on/off | API only | `bot.order-confirmations-toggle` |
| A33 | Chat | Store-login one-time codes over WhatsApp on/off | API only | `otp.toggle` |
| A34 | Chat | Link an existing Meta catalogue | API only | `catalogue.link-existing` |
| A35 | Chat | Connect the agent to own systems (webhook / Odoo) | API only | `agent.connectors` |
| A36 | Chat | Integration tokens for calling the API from own server | API only | `access.integrator-tokens` |

(`marketing.product-feeds` is covered by ebda-store PR 756, which adds the admin "Product feeds" page.)

**Stays super-admin (valid reasons, annotated at the route):** impersonation for support, hard-deleting test stores, repair scripts (`scripts/admin-*.mjs`), executing a card refund, FX and pricing, platform kill switches, operator subscription assignment, the shared platform WhatsApp line (audit #20-22; Chat catalogue: 17 operator capabilities with valid reasons).

**Help-article backfill (§6.8b):** 71 Store + 23 Chat live capabilities without an article; 5 stale Chat guides (04, 05, 06, 07/11, 09).

**Not-built features (planned registry entries):** 20 Store + 19 Chat, listed in the two catalogues with status `planned`.
