# 192 · AI-native, AI-first, self-service (the Ebda charter)

**Concern:** an Ebda capability that a customer cannot do themselves, that the Ebda AI Smart Layer does not know, or that has no help article.

Ahmad, 2026-11-14: "ebda ai studio is ai native and ai first and fully self service and ai is what drive it and we control the layer of inputs and outputs of this ai and this is the ebda ai smart layer" · "There is no super admin controlling someone's account except for something exceptional ... build this into the foundation" · "every existing feature or a new one must have a help article to be shared on help site".

**Scope: everything.** Every EXISTING feature, every NEW feature, every UPCOMING Ebda product (Ebda Store, Ebda Chat, and the coming Ebda CRM, ERP, Ads, Invites, Quote Studio) and anything else Ebda AI Studio ships to customers: onboarding, billing, plans, integrations, settings, data export/erasure, support. No product or feature is exempt by being new, small, internal-facing or "later".

Design: `docs/superpowers/specs/2026-11-14-self-service-and-ebda-assistant-design.md`.

**Super admin keeps full power (Ahmad, 2026-11-14):** "as the super admin, I can turn off sites, I can upgrade as I want ... I can do whatever I want to any store, but still they have the self-service, and I can override". Self-service is about what customers can do alone; it removes nothing from the super admin. The AI never uses super-admin powers, even for the super admin.

## Grading criteria

| # | Criterion | Severity |
|---|---|---|
| 192.1 | **Self-service:** every customer capability can be done by the customer in the product (a screen and a learnable flow), with no Ebda staff, operator or script in the normal path | Critical |
| 192.2 | **No customer capability is staff-only:** a capability that ONLY super admin/operator can do exists only with a written reason (abuse, legal, money dispute, platform-wide config, critical incident) annotated at the route or in its registry entry; a CI guard fails new unannotated ones and a growing baseline. This never limits the super admin: Ahmad keeps full override over every store (suspend/turn off a site, change any plan, grant add-ons/credits, impersonate for support, change any setting); every override is audit-logged | Critical |
| 192.3 | **AI-native:** every customer capability has a capability-registry entry (id, titles ar/en, page, API actions, plan gate, roles, assistant policy free/preview/confirm/forbidden, undo class, help article, example questions ar/Franco/en, edge cases, status live/in-pr/planned); a PR adding or changing a page, route or action without its entry fails CI | Critical |
| 192.4 | **Planned counts:** not-built features are registry entries with status `planned`, so the Smart Layer can say what is coming; the entry flips to `live` in the PR that ships it | High |
| 192.5 | **Help article:** every customer capability, existing or new, has a help article in Egyptian Arabic and English published on help.ebda.app, linked from its registry entry; a capability without a published article fails CI | Critical |
| 192.6 | **Through the Smart Layer only:** every AI input and output in every product passes the Ebda AI Smart Layer pipeline (input rails, tool retrieval + budgets, argument + ownership validation, policy gate with big-change confirms, durable approvals, output rails for binding claims / UI truth / link allowlist / Egyptian register, masked audit); no product calls a model around it | Critical |
| 192.7 | **Action boundary:** the AI does only what the signed-in customer could do; preview first, undo after (honest undo class); explicit "yes" (server-issued, single-use, payload-bound, 15-min) for money, deletion, customer messaging, changes to >20 items, checkout-visible changes and price changes; never super-admin powers; background AI never overwrites customer-written content | Critical |
| 192.8 | **Easy to learn:** every new flow has an empty/loading/error state, Egyptian-Arabic copy in full sentences (English second), and a "how do I…" path in the Smart Layer that is in the golden eval set | High |

## How to check
- Registry coverage: enumerate pages/routes/actions from code (glob, never a hand list) and diff against the registry; enumerate registry entries and check each help article URL resolves on help.ebda.app.
- Super-admin baseline: list role-guarded routes and verify each has a reason annotation.
- Smart Layer bypass: grep for direct model calls (Workers AI binding, provider SDKs) outside the Smart Layer module.

sources: project-ebda-self-service-ai-native, project-ebda-program-register
