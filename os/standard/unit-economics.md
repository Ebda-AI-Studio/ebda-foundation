# 25 · Unit economics & cost attribution

**Concern:** knowing what it costs to serve one customer, one tenant, and one feature — before scale makes the answer expensive.

The playbook's §14 fleet lists "Cost — per-tenant compute/storage/API spend" in a single row. In practice teams instrument *usage* (tokens, requests) and never take the second step: dividing that usage by the revenue it was serving. Usage telemetry answers "how much are we spending". Unit economics answers "is this customer profitable" — a different question, and the one that decides pricing, plan limits, and which features survive.

This matters most on **AI-in-the-loop products with flat subscriptions**: revenue per tenant is fixed, cost per tenant scales with how hard they use it. A heavy tenant can cost more to serve than they pay, and nothing in the product will tell you.

## Grading criteria

| # | Criterion | Severity |
|---|---|---|
| 25.1 | Model/API usage is attributed by **feature** — not one global counter | High |
| 25.2 | Usage is attributed by **tenant**, so per-customer cost is derivable | Critical |
| 25.3 | A cost model converts usage → currency (per-model rates, kept current), so spend is money not tokens | High |
| 25.4 | Revenue per tenant is joinable to cost per tenant — the ratio exists somewhere, not just the two halves | Critical |
| 25.5 | Non-model infra cost (DB, storage, egress, queue, image processing) is attributable to a tenant at least approximately | Medium |
| 25.6 | Per-tenant and per-feature caps exist and are enforced, so a single tenant cannot run unbounded spend | Critical |
| 25.7 | A margin view is surfaced in the product's own admin — not a spreadsheet someone updates by hand | High |
| 25.8 | An alert fires when a tenant's cost crosses a share of their revenue, before the invoice does | High |

## Traps

**Instrumented ≠ measured.** Having a `usage` table with a `feature` column and daily caps is the *input* to this lens, not a pass. If nothing divides spend by tenant revenue, the ratio does not exist and 25.4 fails.

**Caps protect availability, not margin.** A daily request cap stops runaway spend; it does not tell you the feature your customers love most is the one destroying your margin.

**Flat pricing hides the distribution.** Average cost per tenant looks fine while the top decile is underwater. Look at the distribution, not the mean.

**Managed/agency models absorb the cost silently.** When the operator pays infra on the merchant's behalf, there is no invoice signal at all — the loss shows up only in aggregate at month end.

**Attribution has to happen at write time.** Tenant and feature must be recorded on the usage row when the call is made; they cannot be reconstructed later.

**Cost per feature drives product decisions, not just finance ones** — it is the input to plan-tier design, rate limits (`edge-protection.md`), and whether a feature ships to the cheapest tier at all.

## Verify

Pick the heaviest tenant for the last full month. Produce: their model spend, their attributable infra spend, and what they paid. If that takes more than a query or two — or cannot be produced at all — this lens fails regardless of how much telemetry exists.
