# feature-flags — Feature Flags & Plan Gating Rubric

tags: [BOTH]
sources: PLAYBOOK §3.6, CLAUDE.md (source-of-truth = plan-baselines.ts + features.ts), reference-iceberg-audit.md (term 30: Feature flags)

## What "solid" looks like
Every plan-gated feature is enforced at FOUR layers — UI hide + API gate (`requireFeature → 503`) + async-job gate + service-level dual-gate — never UI-hide alone (that is a billing leak). A single resolver computes `enabled = override ?? PLAN_BASELINE[plan].includes(key)`; plan changes never mutate per-store override rows; super-admin bypasses every gate consistently; and the plan→feature map lives in one code file that is the source of truth for docs.

## Criteria
| # | Criterion | Solid (grade 2) | Gap detection | Severity |
|---|---|---|---|---|
| 1 | API gate exists | Every plan-gated mutation/route passes through a `requireFeature(key)` guard that returns `503` when off | grep route/handler files for `requireFeature`/`requirePlan`; list plan-gated endpoints with no feature guard | Critical |
| 2 | Not UI-only (no billing leak) | A feature hidden in the UI is ALSO blocked at the API — UI hiding alone never gates billing-relevant features | grep frontend for feature-flag conditional rendering, then confirm the matching backend route has a `requireFeature` guard; any UI-gated-only feature is a leak | Critical |
| 3 | Async-job gate | Background/queue handlers re-check the flag at handler start (not just at enqueue time) | grep worker/job/cron/queue handlers for a feature/flag check at the top of the handler body | High |
| 4 | Service-level dual-gate | The service-layer method also enforces the flag, so internal callers bypassing the route can't reach a gated feature | grep service/`*.service.*` methods for an in-service feature check on plan-gated operations | High |
| 5 | Plan-baseline source of truth | One file maps plan→feature keys (e.g. `plan-baselines.ts` + `features.ts`); docs are generated FROM it | file-exists check for a `plan-baseline`/`features` map module; grep for hardcoded plan-string comparisons (`plan === '...'`) scattered outside it | High |
| 6 | Override resolution shape | Resolver computes `enabled = override ?? PLAN_BASELINE[plan].includes(key)` in ONE place | grep for the resolver function; confirm a single `?? PLAN_BASELINE`/`includes(key)` resolution, not per-call-site re-derivation | High |
| 7 | Plan change never touches overrides | Changing a store's plan does NOT write/delete per-store override rows | grep plan-update code path for writes to the override table; SQL/Prisma: plan-update tx must NOT `UPDATE`/`DELETE` the `*override*` table | High |
| 8 | Super-admin bypass consistent | Super-admin bypasses every gate via the SAME bypass path across all four layers | grep the gate/resolver for a single super-admin/`isSuperAdmin` bypass branch; flag any layer that re-implements its own bypass or omits it | Medium |

## Evidence (filled during audit, per repo)
- a previous storefront product: …
- an earlier messaging product: …

## Managed-agency products

Where a product is onboarded by the operator rather than self-serve (no signup, no self-serve plan), do NOT grade this lens as "ungated premium routes = billing leak." Grade instead that the gate enforces at all 4 layers, that the default is full access so a newly-onboarded client is not locked out, and that onboarding sets the client's access bundle. Report a gap as "no default access / onboarding doesn't set the bundle," not "billing leak." Origin: [incidents](../../docs/history/standards/incidents.md).
