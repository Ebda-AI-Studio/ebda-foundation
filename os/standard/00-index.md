# Ebda Foundation — Standard Index

The canonical, **gradeable** Ebda AI Studio production standard: one file per concern, merged from the 6 scattered sources. Used as the rubric for BOTH building and auditing every Ebda AI Studio product.

> **🔭 `unified-audit.md` is THE entry point for "audit this repo".** It blends ALL audit types (layers + blast-radius + feature×feature interaction + security + RLS-writer-coverage + iceberg-38 + scaling/money + reliability/observability + save-integrity S1–S6 + data→UI + UI/UX consistency + CI/testing + deps + docs-parity + mobile) into ONE report: what's broken, WHERE exactly (file:line / page / field), and the **blast radius** that must be fixed in lockstep so the whole system reaches one level of maturity. The 42 lenses below are its rubric. It is steps 1–3 of the self-improving loop (`~/.claude/.../memory/feedback-os-self-improving-audit-loop`).

## Concern taxonomy (the rubric)

The numbered lenses below each become one file `standard/<id>.md`. `mobile` is N/A for web-only repos (previous products) and is authored but not graded in Phase 1.

| # | id | Concern | Primary source |
|---|---|---|---|
| 1 | `architecture` | Monorepo shape, stack decisions, money-as-integer | Playbook §2 |
| 2 | `auth` | authn/authz middleware chain, ownership guard, auth rate limit | Playbook §3.1 |
| 3 | `rls` | Multi-tenant RLS, non-owner role, GUC, bypass vs tenant-context, cutover sweep | Playbook §3.2 |
| 4 | `money` | Integer minor units, tx maxWait, SAVEPOINT idempotency, deterministic orderBy | Playbook §2/§3.3 |
| 5 | `event-log` | Append-only `<entity>_events` with raw payloads for money/trust | Playbook §3.4 |
| 6 | `cache-ratelimit` | Redis rate-limit, two-tier cache, TTL floor, replica-safe | Playbook §3.5 |
| 7 | `feature-flags` | 4-layer enforcement, plan-baseline + override resolution | Playbook §3.6 |
| 8 | `scaling` | Vertical sliders, replica prereqs (socket adapter, cron leader-election) | Playbook §4 |
| 9 | `testing` | 5 layers, CI gating, teardown discipline | Playbook §5; Rule 14 |
| 10 | `cicd` | Canonical workflow shape, timeouts, audit split, notify-failure, runner routing | Playbook §6; Rule 15 |
| 11 | `deploy-verify` | Simulate target commands, lockfile 4-dimensions | Playbook §7 |
| 12 | `observability` | Sentry, uptime, ≥30-day logs, SLO, queue-depth, alert bridge | Playbook §8 |
| 13 | `security` | XSS, injection, secrets 0/0/0/0, PII mask, CSV-formula, consent, erasure, headers | Playbook §9; Rules 1,2 |
| 14 | `dr` | Snapshot/backup, rollback, additive-only migrations, restore re-verify RLS | Playbook §10 |
| 15 | `environments` | Local/staging never prod, queue prefix, CI-enforced isolation | Playbook §11 |
| 16 | `docs-parity` | All docs updated same session (local + pushed) | Playbook §12 |
| 17 | `data-ui-coverage` | Every meaningful table has a viewer; admin-endpoint connection; redundancy | Playbook §3.7/§14 |
| 18 | `deps` | Registry-exists, <12mo, license-compat, `npm audit` 0/0/0/0, override-the-leaf | Rule 1 |
| 19 | `frontend-quality` | i18n/RTL parity, a11y/WCAG, perf/CWV, SEO | iceberg + grading matrix |
| 20 | `mobile` | Store compliance, MASVS, push, OTA staged rollout (N/A for previous products) | reference-mobile-* methodology |
| 21 | `migration-safety` | Expand/contract, rollback-with-migration, staging mirror, constraint pre-checks, boot-time migration risk | Reel fleet 2026-08-08 + a previous storefront product sku/index incidents |
| 22 | `error-surface` | Public vs private error layers, every boundary, correlation ids, redacted log pipeline | Reel fleet 2026-08-08 |
| 23 | `ai-transparency` | EU AI Act SGI labelling, consent gate, immutable generation log, jurisdictional reach | Reel fleet 2026-08-08 (Act live 2026-08-02) |
| 24 | `edge-protection` | WAF in front of the whole stack, adaptive rate limiting, abuse playbook | Reel fleet 2026-08-08 |
| 25 | `unit-economics` | Cost per feature AND per tenant, revenue:cost ratio, margin alerting | Reel fleet 2026-08-08 |
| 26 | `skill-hygiene` | Installed-skill expiry (apply/verify/dispose), reviewer-vendor rotation — grades the AGENT's config, not its output | Reel fleet 2026-08-31 |
| 27 | `gate-integrity` | A gate's PASS must be reachable only by reading the artifact: receipt-bound verdicts, empty-input fails, exit codes are not evidence, `=== true` at injected seams | Corpus-pipeline session 2026-09-02 |
| 28 | `mutation-proof` | Every defence carries a recorded mutation that made its named test go red, plus a byte-identical restore | Session 2026-09-02 (4 false-green defences) |
| 30 | `absent-filter-matches-everything` | A query filter built from an optional value must be proven present before the query runs — a dropped condition widens the result set, it does not narrow it | Reel lens pack 2026-09 L6 + a storefront P0 2026-09-03 |
| 29 | `enumeration-integrity` | Counts reconcile against an independent total, NUL-safe iteration, path-not-basename ids, score-not-first-match classification | Corpus-census session 2026-09-02 |
| 31 | `supply-chain` | Action refs pinned to SHAs, no branch refs, consumers pin our reusable workflows, `npm audit signatures`, vendored-source provenance | Harness extraction 2026-09-04 (223/229 refs mutable) |
| 32 | `agent-containment` | Hook-bypass and gate-config-weakening blocked in code, every declared hook registered, credentials scrubbed before spawn | Harness extraction 2026-09-04 (a shipped hook that had never fired) |
| 33 | `rsc-payload-exposure` | Server→client props serialise in full: explicit `select`, a DTO at every boundary, sensitive fields never on the wire | Reel lens pack 2026-09 L16 |
| 34 | `psp-account-survival` | Policy pages, support contact, statement descriptor, dispute-ratio alerting, ToS as dispute evidence — the account, not the payment path | Reel lens pack 2026-09 L17 |
| 35 | `model-currency` | One source per product, vendor alias over a versioned pin, verified against the vendor's list, loud failure on an unknown id | Reel lens pack 2026-09 L18 + CLAUDE.md model-routing rule |
| 36 | `auth-token-lifecycle` | Session id regenerated on login/privilege change, reset token expires ≤15min + single-use + invalidated on any password change + rate-limited issuance | Reel lens pack 2026-09 L21, L23 |
| 37 | `api-schema-exposure` | Introspection/Swagger/Playground disabled in prod, query depth limited, no exposed source maps — the self-describing-endpoint sibling of `rsc-payload-exposure` | Reel lens pack 2026-09 L24 |
| 38 | `aeo-integrity` | Locale-matched meta content per URL (not just present), canonical on every page, single canonical brand entity, deliberate+documented AI-crawler policy, rendered-text substance floor | Reel lens pack 2026-09 A1-A5 (live measurement, a live merchant domain, 2026-09-19/22) |
| 39 | `navigation-integrity` | Native-stack dismiss vetoed only via `usePreventRemove`, never a raw `beforeRemove`+`preventDefault` (ignored by iOS swipe-dismiss → ghost route, dead navigation); explicit close on every blocked screen | a marketplace launch device audit 2026-10-07 (memory `feedback-native-stack-beforeremove-swipe-dismiss`) |
| 40 | `state-transition-integrity` | Approve/review/revoke/publish/restore/grant/suspend are conditional on the current state (`updateMany where status = expected`), a repeat is a no-op/409 with one audit row, resubmission blocked while settled, undo derives its target, UI shows per-entity status | a marketplace launch sense audit 2026-10-07 (PRs #205, #209) |
| 41 | `real-world-sense` | Location pairing, gate order (guest → signed-in → verified → owner), money + lifecycle (no 0-for-unknown, no live-when-ended, Range/206 video), identity reuse — "nothing is logical until it makes sense" | a marketplace launch sense audit 2026-10-07 (memory `feedback-sense-audit-real-world-logic`) |
| 42 | `disk-discipline` | Worktree deps ONLY via `wt-deps.sh` APFS clones for every tool that creates a worktree (global post-checkout dispatcher + Claude hooks), 30 GB hard floor, hygiene auto-prunes the Umbra CI VM before the host fills | 3 disk-full incidents 2026-10 (memory `feedback-umbra-sparse-disk-host-full-corrupts-guest`) |
| 43 | `bearer-in-localstorage` | Access token stored in localStorage. Pack: security, frontend; probe S | Ebda audit 2026-10-26 SEC-4 |
| 44 | `bulk-export-permission` | Bulk export route without a dedicated permission. Pack: security, privacy; probe S+J | Ebda audit 2026-10-26 SEC-14 |
| 45 | `capability-url-expiry` | Capability URL token with no expiry. Pack: security, privacy; probe S+J | Ebda audit 2026-10-26 SEC-15 |
| 46 | `cf-dns-mail-hygiene` | DMARC p=none or no CAA record. Pack: cloudflare, security; probe H | Ebda audit 2026-10-26 OPS-17, OPS-20 |
| 47 | `cors-credentials-any-origin` | CORS reflects any origin while allowing credentials. Pack: security; probe S | Builder-reality reel pack (reel-lenses-2026-09) + playbook sec 14, L10 |
| 48 | `csp-unsafe-inline-eval` | Script CSP allows unsafe-inline or unsafe-eval. Pack: security, frontend; probe S | Ebda audit 2026-10-26 SEC-4 |
| 49 | `dependabot-ecosystem-coverage` | Dependabot covers only GitHub Actions. Pack: cicd, security; probe S | Ebda audit 2026-10-26 OPS-22 |
| 50 | `headers-live` | Security headers missing on a live host. Pack: security; probe H | Ebda audit 2026-10-26 SEC-7, OPS-21 |
| 51 | `llm-moderation-fail-open` | AI moderation that approves when the moderator errors. Pack: ai-safety, security; probe S | Ebda audit 2026-10-26 SEC-2 |
| 52 | `lockout-by-victim-key` | Account lockout keyed only by the victim's identifier. Pack: security; probe S | Ebda audit 2026-10-26 SEC-3 |
| 53 | `og-fetch-ssrf` | Server fetches a request-supplied URL without a host guard. Pack: security; probe S | Ebda audit 2026-10-26 SEC-6 |
| 54 | `open-redirect` | Redirect target taken from the request without validation. Pack: security; probe S | Builder-reality reel pack (reel-lenses-2026-09) + playbook sec 14, L5 |
| 55 | `prompt-injection-unfenced` | Untrusted text interpolated into a prompt without fencing. Pack: ai-safety, security; probe S | Ebda audit 2026-10-26 SEC-2, SEC-11 |
| 56 | `secret-in-url-path` | Webhook secret carried in the URL path. Pack: security; probe S | Ebda audit 2026-10-26 SEC-8 |
| 57 | `third-party-script-integrity` | Third-party script tag without Subresource Integrity. Pack: security, frontend; probe S | Builder-reality reel pack (reel-lenses-2026-09) + playbook sec 14, L1 |
| 58 | `upload-trusts-declared-mime` | Upload type decided by the client-declared MIME. Pack: security, meta-whatsapp; probe S | Ebda audit 2026-10-26 SEC-12 |
| 59 | `webhook-persist-before-verify` | Webhook body persisted or queued before its signature is verified. Pack: security, money; probe S | Ebda audit 2026-10-26 SEC-5 |
| 60 | `live-state-beats-token-claims` | Elevated token claim, tenant status, caller-supplied derived key or response-body URL trusted without a live check. Rule: re-check live role, one suspended-status middleware, recompute derived ids, https + host allow-list before credentials | backfill audit 2026-11-12 |
| 60 | `analytics-pixel-present` | Marketing site has no analytics or ad pixel. Pack: business, privacy; probe S | Ebda audit 2026-10-26 BIZ-26 |
| 61 | `legal-pending-markers` | Legal page published with unreviewed or placeholder markers. Pack: docs, privacy; probe S+J | Ebda audit 2026-10-26 DOC-3 |
| 62 | `platform-db-shared-tenant-bodies` | Raw tenant payloads kept in one shared database with no purge. Pack: tenancy, privacy; probe J | Ebda audit 2026-10-26 DB-13 |
| 63 | `privacy-processor-parity` | A processor the code uses is missing from the privacy policy. Pack: privacy, docs; probe S+J | Ebda audit 2026-10-26 DOC-2, DOC-11 |
| 64 | `privacy-promise-vs-product` | Legal text promises deletion the product does not perform. Pack: privacy, docs; probe S+J | Ebda audit 2026-10-26 DOC-1 |
| 65 | `retention-sweeper-missing` | Append-only table with no retention job. Pack: privacy, data; probe S | Ebda audit 2026-10-26 DB-10 |
| 66 | `third-party-llm-egress` | Customer data sent to an LLM endpoint the tenant chooses. Pack: privacy, ai-safety; probe S | Ebda audit 2026-10-26 SEC-9 |
| 67 | `wa-optin-recorded` | Outbound WhatsApp with no recorded opt-in. Pack: meta-whatsapp, privacy; probe S+J | Meta WhatsApp Business policy (opt-in) + PDPL consent |
| 68 | `failure-branch-overwrites-paid` | Failed/expired transition with no guard on the current status. Pack: money; probe S | Ebda audit 2026-10-26 BUG-6 |
| 69 | `idempotency-key-reuse` | Idempotency key that cannot change after a failed attempt. Pack: money; probe S+J | Ebda audit 2026-10-26 BUG-4 |
| 70 | `llm-output-controls-flags` | Model output decides whether a warning flag is raised. Pack: ai-safety, money; probe S+J | Ebda audit 2026-10-26 SEC-11 |
| 71 | `month-anchor-drift` | Billing anchor advanced by adding a month to the previous date. Pack: money, reliability; probe S | Ebda audit 2026-10-26 BUG-11 |
| 72 | `post-money-writes-in-tx` | Audit writes after the money moved, inside the same transaction. Pack: money; probe S+J | Ebda audit 2026-10-26 BUG-14 |
| 73 | `pricing-cost-model-exists` | Pricing documented with no cost or margin model. Pack: money, business; probe J | Ebda audit 2026-10-26 BIZ-11..16 |
| 74 | `refund-bound-in-schema` | Refunded amount not bounded by the charge in the schema. Pack: money, data; probe S | Ebda audit 2026-10-26 DB-9 |
| 75 | `report-silent-truncation` | Report query with a hard row cap and no truncation signal. Pack: money, reliability; probe S | Ebda audit 2026-10-26 BUG-9 |
| 76 | `rmw-without-lock` | Read-then-overwrite on shared state with no lock or atomic update. Pack: money, reliability; probe S | Ebda audit 2026-10-26 BUG-2, BUG-5 |
| 77 | `tz-utc-windows` | Business-day windows built on UTC midnight. Pack: reliability, money; probe S | Ebda audit 2026-10-26 BUG-10 |
| 78 | `unknown-outcome-sweeper` | Pending charge with no reconciliation job. Pack: money, reliability; probe S+J | Ebda audit 2026-10-26 BUG-3 |
| 79 | `wa-wallet-fx-buffer` | Prepaid wallet exposed to FX with no buffer. Pack: meta-whatsapp, money; probe J | Ebda audit 2026-10-26 BIZ-16 |
| 80 | `webhook-miss-acked` | Verified webhook for an unseen row is acknowledged and dropped. Pack: money, data; probe S | Ebda audit 2026-10-26 BUG-8, DB-2 |
| 81 | `rls-proof-nightly-red` | RLS strict-policy proof is failing. Pack: tenancy, cicd; probe H | Ebda audit 2026-10-26 OPS-10 |
| 82 | `d1-hot-lookup-index` | Tenant-keyed table with no index on the tenant column. Pack: data; probe S | Ebda audit 2026-10-26 DB-8 |
| 83 | `down-migration-coverage` | Most migrations have no down path. Pack: data; probe S | Ebda audit 2026-10-26 DB-11 |
| 84 | `n-plus-one` | Database query inside a loop over rows. Pack: reliability, data; probe S | Builder-reality reel pack (reel-lenses-2026-09) + playbook sec 14, L9; playbook sec 14 N+1 |
| 85 | `reader-without-writer` | A model is read everywhere and written nowhere. Pack: data; probe S | Ebda audit 2026-10-26 CODE-8 |
| 86 | `rollup-loads-all-rows` | Nightly rollup loads a tenant's whole history into memory. Pack: data, reliability; probe S | Ebda audit 2026-10-26 DB-6 |
| 87 | `async-checkpoint` | Bulk job with a single checkpoint step. Pack: reliability; probe S | Iceberg term 40 (2026-07-11) |
| 88 | `cf-hyperdrive-pool` | Many cron triggers on one small database. Pack: cloudflare, reliability; probe S+J | Ebda audit 2026-10-26 OPS-19 |
| 89 | `guest-401-console` | Guest page load logs 401 errors. Pack: frontend, reliability; probe H | Ebda audit 2026-10-26 UI-8 |
| 90 | `health-liveness-only` | /health proves liveness only. Pack: reliability, observability; probe S | Ebda audit 2026-10-26 OPS-12 |
| 91 | `iceberg-multi-region` | Single-region dependency not named. Pack: reliability; probe J | Iceberg Audit term gap (no mechanical lens before 2026-10-26) 20 |
| 92 | `module-timer-leak` | Module-level timer that is never cleared. Pack: reliability; probe S | Playbook sec 14 Memory-leak (setInterval CI hang) |
| 93 | `provider-error-wrapping` | Direct provider SDK call outside the safe-error wrapper. Pack: reliability, observability; probe S | Iceberg term 39 (2026-07-11) |
| 94 | `public-api-latency` | Public read API slow under a light client. Pack: perf, reliability; probe H | Ebda audit 2026-10-26 SEO-3 |
| 95 | `redirect-loop` | Redirect loop on a policy or deep URL. Pack: seo, reliability; probe H | feedback-a-control-that-cannot-generalise (2026-09, 50-hop loop on two live policy pages) |
| 96 | `unbounded-memory-cache` | Module-level Map cache with no eviction. Pack: reliability; probe S | Ebda audit 2026-10-26 BUG-13 |
| 97 | `activation-instrumented` | Activation is defined but never emitted as an event. Pack: business, observability; probe S | Ebda audit 2026-10-26 BIZ-18 |
| 98 | `alert-reaches-human` | Deploy workflow has no failure notification. Pack: observability, cicd; probe S | Ebda audit 2026-10-26 OPS-5, BIZ-22 |
| 99 | `dead-control-matrix` | UI controls wired to nothing. Pack: observability, frontend; probe S+J | Ebda audit 2026-10-26 CODE-5 |
| 100 | `iceberg-escalations` | Support has no escalation path. Pack: business, observability; probe J | Iceberg Audit term gap (no mechanical lens before 2026-10-26) 34 |
| 101 | `iceberg-incident-response` | No runbook, on-call owner or postmortem path. Pack: observability; probe J | Iceberg Audit term gap (no mechanical lens before 2026-10-26) 25 |
| 102 | `log-cost-sampling` | Workers logs at 100% sampling with Logpush. Pack: observability, cloudflare; probe S | Ebda audit 2026-10-26 OPS-23 |
| 103 | `status-uptime-claim` | Public status page shows uptime below target. Pack: business, observability; probe H | Ebda audit 2026-10-26 BIZ-24 |
| 104 | `cf-token-scope` | CI Cloudflare token used for D1 with no D1 permission noted. Pack: cloudflare, cicd; probe S+J | Ebda audit 2026-10-26 OPS-4 |
| 105 | `deploy-red-on-main` | Deploy workflow failing on main. Pack: cicd; probe H | Ebda audit 2026-10-26 OPS-2, OPS-3, OPS-4 |
| 106 | `duplicate-impls` | The same helper implemented in several files. Pack: cicd; probe S | Ebda audit 2026-10-26 CODE-7, CODE-10 |
| 107 | `env-example-parity` | .env.example does not list the env names the code reads. Pack: cicd, docs; probe S | Ebda audit 2026-10-26 OPS-14, DOC-13 |
| 108 | `giant-revenue-file` | Source file over 1500 lines. Pack: cicd; probe S | Ebda audit 2026-10-26 CODE-3, CODE-18 |
| 109 | `iceberg-governance` | No decision record (ADR / rulings). Pack: business, cicd; probe J | Iceberg Audit term gap (no mechanical lens before 2026-10-26) 8 |
| 110 | `required-checks-unenforced` | No required status checks on the default branch. Pack: cicd; probe H | Ebda audit 2026-10-26 OPS-11 |
| 111 | `retired-provider-mentions` | Docs or config still name a retired provider. Pack: docs, cicd; probe S | Ebda audit 2026-10-26 DOC-15, OPS-15 |
| 112 | `secret-gate-list` | Deploy secret gate list needs checking against the code. Pack: cicd; probe J | Ebda audit 2026-10-26 OPS-13 |
| 113 | `source-text-tests` | Tests that assert on source text, not behaviour. Pack: cicd; probe S | Ebda audit 2026-10-26 CODE-9 |
| 114 | `stale-compiled-in-src` | Compiled .js committed beside its .ts source. Pack: cicd; probe S | Ebda audit 2026-10-26 CODE-14 |
| 115 | `test-tier-gating` | Integration/RLS/E2E tier runs only on a schedule. Pack: cicd; probe S | Ebda audit 2026-10-26 CODE-1, CODE-2 |
| 116 | `type-escape-density` | Type-safety escape hatches concentrated in one file. Pack: cicd; probe S | Ebda audit 2026-10-26 CODE-17 |
| 117 | `brand-forbidden-color` | A brand-forbidden colour class is in use. Pack: frontend; probe S | Ebda audit 2026-10-26 UI-14 |
| 118 | `color-only-link` | Inline link told apart from text by colour alone. Pack: frontend; probe S | Ebda audit 2026-10-26 UI-5 |
| 119 | `hardcoded-year-epoch` | Footer year computed from an unset date or hard-coded. Pack: frontend; probe S | Ebda audit 2026-10-26 UI-2 |
| 120 | `rtl-physical-properties` | Physical left/right utilities in RTL-served UI. Pack: frontend; probe S | Ebda audit 2026-10-26 UI-13, UI-1 |
| 121 | `skip-link-target` | Skip link points at an id that does not exist. Pack: frontend; probe S | Ebda audit 2026-10-26 UI-4 |
| 122 | `target-blank-signup` | Primary signup CTA opens in a new tab. Pack: frontend; probe S | Ebda audit 2026-10-26 UI-15 |
| 123 | `tiny-text` | Text set below 12px. Pack: frontend; probe S | Ebda audit 2026-10-26 UI-11 |
| 124 | `touch-target-24` | Interactive element smaller than 24px. Pack: frontend; probe S | Ebda audit 2026-10-26 UI-10 |
| 125 | `viewport-overflow-360` | Page wider than a 360px phone. Pack: frontend; probe H | Ebda audit 2026-10-26 UI-1, UI-3 |
| 126 | `hreflang-locale-url` | Locale held in a cookie only: no URL, no hreflang. Pack: seo; probe S | Ebda audit 2026-10-26 SEO-9 |
| 127 | `jsonld-minimal` | Structured data missing key fields or marking plans PreOrder. Pack: seo; probe S | Ebda audit 2026-10-26 SEO-8, SEO-11, BIZ-31 |
| 128 | `meta-length` | Meta description outside 50-160 characters. Pack: seo; probe S | Ebda audit 2026-10-26 SEO-10 |
| 129 | `redirect-hops` | Deep link needs more than one redirect. Pack: seo, perf; probe H | Ebda audit 2026-10-26 SEO-12 |
| 130 | `social-cards-subsites` | Pages with a title but no Open Graph / social card. Pack: seo; probe S | Ebda audit 2026-10-26 SEO-7 |
| 131 | `font-weight-budget` | Render-blocking Google Fonts stylesheet. Pack: perf; probe S | Ebda audit 2026-10-26 SEO-5 |
| 132 | `html-edge-cache` | HTML never served from the edge cache. Pack: perf; probe H | Ebda audit 2026-10-26 SEO-2 |
| 133 | `immutable-hashed-assets` | Hashed assets served with max-age=0. Pack: perf; probe H | Ebda audit 2026-10-26 SEO-4 |
| 134 | `lcp-field` | Largest Contentful Paint above 2.5 s. Pack: perf; probe H | Ebda audit 2026-10-26 SEO-1, SEO-6 |
| 135 | `help-coverage` | Shipped features without a help article. Pack: docs, business; probe S+J | Ebda audit 2026-10-26 DOC-8, BIZ-23 |
| 136 | `legal-entity-missing` | Legal notice names no registered entity. Pack: docs, business; probe S | Ebda audit 2026-10-26 DOC-12, BIZ-1 |
| 137 | `marketing-claim-vs-feature` | Marketing promises a capability gated elsewhere. Pack: docs, business; probe J | Ebda audit 2026-10-26 DOC-4 |
| 138 | `openapi-route-coverage` | Published OpenAPI covers a small fraction of the routes. Pack: docs; probe S | Ebda audit 2026-10-26 DOC-9 |
| 139 | `refund-policy-published` | No refund or cancellation policy for the product's own subscriptions. Pack: docs, business; probe S | Ebda audit 2026-10-26 BIZ-25 |
| 140 | `unsold-plan-names` | UI or docs name a plan the registry does not sell. Pack: docs, business; probe S | Ebda audit 2026-10-26 DOC-6, DOC-7 |
| 141 | `cf-account-ownership` | Cloudflare config tied to a personal mailbox. Pack: cloudflare, business; probe J | Ebda audit 2026-10-26 BIZ-28, BIZ-29 |
| 142 | `eliminated-cost-on-home` | Home page states no eliminated cost in the buyer's currency. Pack: business; probe J | Ebda audit 2026-10-26 BIZ-7, BIZ-9 |
| 143 | `iceberg-ab-testing` | No way to run an experiment without a deploy. Pack: business; probe J | Iceberg Audit term gap (no mechanical lens before 2026-10-26) 37 |
| 144 | `iceberg-churn` | No cancellation reason, dunning or win-back path. Pack: business; probe J | Iceberg Audit term gap (no mechanical lens before 2026-10-26) 14 |
| 145 | `named-buyer-evidence` | Buyer persona with no interview evidence. Pack: business; probe J | Ebda audit 2026-10-26 BIZ-8 |
| 146 | `support-sla-published` | Support hours or response times not published. Pack: business; probe S+J | Ebda audit 2026-10-26 BIZ-21 |
| 147 | `vendor-concentration` | No continuity plan for the one provider everything runs on. Pack: business, cloudflare; probe J | Ebda audit 2026-10-26 BIZ-28, BIZ-29 |
| 148 | `wa-verification-chain` | WhatsApp launch with no verification plan documented. Pack: meta-whatsapp, business; probe J | Ebda audit 2026-10-26 BIZ-5, BIZ-20 |
| 149 | `llm-reply-no-guard` | Model reply sent to a customer with no URL/price/promise guard. Pack: ai-safety, meta-whatsapp; probe S+J | Ebda audit 2026-10-26 SEC-10 |
| 150 | `wa-brand-name` | Product name begins or ends with WhatsApp. Pack: meta-whatsapp; probe S+J | Ebda audit 2026-10-26 BIZ-6 |
| 151 | `wa-window-template` | Free-form WhatsApp send with no 24-hour window or template path. Pack: meta-whatsapp; probe S | Meta WhatsApp Business policy (24 h customer service window) |
| 152 | `cf-compat-date` | Worker compatibility_date older than 18 months. Pack: cloudflare; probe S | Cloudflare workers-best-practices skill |
| 153 | `cf-for-saas-config` | Custom hostnames used with no Cloudflare-for-SaaS setup. Pack: cloudflare; probe S+J | Ebda audit 2026-10-26 OPS-18 |
| 154 | `bearer-staleness-undocumented` | Stateless bearer verified with no stated staleness window. Pack: security; probe J | Ebda master catalogue 2026-10-26 sec.7 L32 |
| 155 | `pr-lane-builds-deployables` | PR workflow does not build every app the deploy workflow builds. Pack: cicd, security; probe S | Ebda master catalogue 2026-10-26 sec.7 L01 |
| 156 | `consent-evidence-incomplete` | Consent row stores no wording, version or attestor. Pack: privacy; probe S | Ebda master catalogue 2026-10-26 sec.7 L80 |
| 157 | `erasure-not-replayed-on-restore` | Erasure leaves no durable record that a restore re-applies. Pack: privacy, data; probe S+J | Ebda master catalogue 2026-10-26 sec.7 L36 |
| 158 | `personal-table-no-retention-row` | Table with personal columns missing from every retention/erasure doc. Pack: privacy, data; probe S+J | Ebda master catalogue 2026-10-26 sec.7 L34 |
| 159 | `r2-prefix-without-erasure` | Object-storage key prefix written with no erasure owner or lifecycle. Pack: privacy, cloudflare; probe S | Ebda master catalogue 2026-10-26 sec.7 L37 |
| 160 | `wa-optout-text-only` | Opt-out keyword checked on text bodies only. Pack: meta-whatsapp, privacy; probe S | Ebda master catalogue 2026-10-26 sec.7 L74 |
| 161 | `create-order-no-idempotency-key` | Order/payment create endpoint without a client idempotency key. Pack: money; probe S | Ebda master catalogue 2026-10-26 sec.7 L15 |
| 162 | `external-contract-unproven` | External API integration with no recorded live proof. Pack: meta-whatsapp, money; probe J | Ebda master catalogue 2026-10-26 sec.7 L86 |
| 163 | `worker-first-money-routes` | Static assets config without run_worker_first for money/entitlement routes. Pack: cloudflare, money; probe S | Ebda master catalogue 2026-10-26 sec.7 L77 |
| 164 | `backup-offsite-copy` | Backups never leave the machine or account that holds the data. Pack: data; probe S | Ebda master catalogue 2026-10-26 sec.7 L08 |
| 165 | `backup-restore-drill` | Backups exist but nothing restores and compares them. Pack: data, reliability; probe S | Ebda master catalogue 2026-10-26 sec.7 L07 |
| 166 | `control-claim-without-config` | Docs claim a control (PITR window, 3-2-1 backup) with no config key behind it. Pack: docs, data; probe J | Ebda master catalogue 2026-10-26 sec.7 L06 |
| 167 | `index-create-not-concurrent` | CREATE INDEX on Postgres without CONCURRENTLY. Pack: data; probe S | Ebda master catalogue 2026-10-26 sec.7 L83 |
| 168 | `migration-deploy-no-approval` | Workflow runs migrations with no approval environment. Pack: cicd, data; probe S | Ebda master catalogue 2026-10-26 sec.7 L59 |
| 169 | `rollback-discards-writes` | Backend flip/rollback with no check for writes made since the flip. Pack: data, reliability; probe S+J | Ebda master catalogue 2026-10-26 sec.7 L09 |
| 170 | `trigger-removed-no-backstop` | Database trigger dropped with no replacing assertion. Pack: data; probe S+J | Ebda master catalogue 2026-10-26 sec.7 L11 |
| 171 | `ai-turn-cap-missing` | Model calls with no per-customer turn cap or quota. Pack: ai-safety, reliability; probe S | Ebda master catalogue 2026-10-26 sec.7 L76 |
| 172 | `killswitch-env-only` | Tenant-level kill switch held in an environment variable. Pack: reliability; probe S | Ebda master catalogue 2026-10-26 sec.7 L75 |
| 173 | `load-baseline-missing` | No load test for the current architecture. Pack: perf, reliability; probe S | Ebda master catalogue 2026-10-26 sec.7 L49 |
| 174 | `alert-transport-single-channel` | Alert transport that silently no-ops when its secret is missing. Pack: observability; probe S | Ebda master catalogue 2026-10-26 sec.7 L04 |
| 175 | `framework-error-swallowed` | Hono app without onError, so errors never reach Sentry. Pack: observability; probe S | Ebda master catalogue 2026-10-26 sec.7 L78 |
| 176 | `queue-dlq-no-consumer` | Dead-letter queue configured with no consumer or alert. Pack: observability, cloudflare; probe S | Ebda master catalogue 2026-10-26 sec.7 L79 |
| 177 | `contract-version-unpinned` | Cross-product contract package on a floating version. Pack: cicd; probe S | Ebda master catalogue 2026-10-26 sec.7 L81 |
| 178 | `deploy-partial-failure-skips-verify` | A failing deploy step can skip the verify and rollback steps. Pack: cicd; probe S | Ebda master catalogue 2026-10-26 sec.7 L02 |
| 179 | `dormant-code-marker` | Code marked dormant or retired but still shipping. Pack: cicd; probe S | Ebda master catalogue 2026-10-26 sec.7 L46 |
| 180 | `e2e-hand-built-app` | 'E2E' test that builds its own mini-app instead of using the real entry point. Pack: cicd; probe S | Ebda master catalogue 2026-10-26 sec.7 L42 |
| 181 | `evidence-pointer-dangling` | fn-map / control matrix points at test files that do not exist. Pack: cicd; probe S | Ebda master catalogue 2026-10-26 sec.7 L12 |
| 182 | `expired-dated-todo` | A dated TODO whose date has passed. Pack: cicd; probe S | Ebda master catalogue 2026-10-26 sec.7 L47 |
| 183 | `response-envelope-drift` | Two response envelope shapes in one API. Pack: cicd; probe S | Ebda master catalogue 2026-10-26 sec.7 L48 |
| 184 | `unpushed-work` | Local branches with commits that exist on no remote. Pack: cicd; probe H | Ebda master catalogue 2026-10-26 sec.7 L13 |
| 185 | `dimmed-state-contrast` | Text dimmed with opacity below contrast. Pack: frontend; probe S | Ebda master catalogue 2026-10-26 sec.7 L55 |
| 186 | `competitor-claim-undated` | Competitor claim with no verification date. Pack: business, docs; probe J | Ebda master catalogue 2026-10-26 sec.7 L85 |
| 187 | `price-literal-duplicated` | The same price literal is hard-coded on many surfaces. Pack: docs, business; probe S | Ebda master catalogue 2026-10-26 sec.7 L40 |
| 188 | `launch-checklist-missing` | No dated launch-day checklist with owners. Pack: business; probe J | Ebda master catalogue 2026-10-26 sec.7 L72 |
| 189 | `wa-quality-not-gating` | Sender quality / account events do not gate sending. Pack: meta-whatsapp; probe S | Ebda master catalogue 2026-10-26 sec.7 L73 |
| 190 | `umbra-guest-integrity` | Hard-killed CI guest => disk marked dirty, offline e2fsck (block device, two clean passes) before it may start; job semaphore fails closed with a light lane; prune idle guard treats any slot-*/light-* as busy | CI guest emergency_ro 2026-10-26 (memory `feedback-umbra-unclean-stop-fsck-before-runners`) |
| 191 | `job-per-store-isolation` | A sweep over stores aborts on one store's error or visits them in a fixed order. Pack: reliability; probe S | Ebda issue #619, P1s 2026-11-11 |

## Source lens packs

The rubric above is the graded form. The **source packs** the lenses were derived from —
original claims, verbatim, with the concrete scenario attached — live in
[`audit/lenses/`](../audit/lenses/00-index.md), along with per-repo fleet status so a pack
re-runs against repos it has not been applied to yet. Lenses 21–25 came from the
2026-08-08 reel fleet; lens 26 from 2026-08-31. Lenses 27–29 came from a single
engineering session on 2026-09-02 and are sourced from memory files rather than a lens pack.
Lenses 33–35 came from three reels watched 2026-09-19 (pack L16–L18); L18's source claim was
false on verification, and the lens is the first-party rule that survived it. Lenses 36–38 came
from a second `@mattmurphyai` batch watched 2026-09-22 (pack L21/L23, L24) plus five live AEO
findings (pack A1–A5) measured the same day against a real merchant store; three other
claims in that batch (L19 clickjacking, L20 Redis-as-a-database, L22 open redirect) extended
existing docs (`security.md` crit 14, `cache-ratelimit.md` crit 10, `auth.md` crit 11) instead
of becoming new lenses, and two (L25 compliance docs, L26 vendor sovereignty) were ruled
process-only and are recorded in the pack without a graded doc.
Lenses 39–41 came from a marketplace launch-readiness day, 2026-10-07 (pack [lens-pack-marketplace-launch-2026-10](../../docs/history/lens-pack-marketplace-launch-2026-10.md): device test + four-lens sense audit); the fourth lesson of that day, the lockfile written by a different npm major than CI, extended `deploy-verify.md` criterion 8 instead of becoming a lens.

## Grade scale

- `0` = absent · `1` = partial · `2` = solid (matches the previous products reference).
- Layer grade = rounded mean of its criteria; any **Critical-severity FAIL caps the layer at 0**.

## Cross-cutting standard docs

Beyond the 29 per-concern lenses above, twelve docs describe HOW the standard is applied rather than a single concern:

- `unified-audit.md` — THE entry point for "audit this repo"; blends all lenses + blast-radius into one report (see the 🔭 callout above).
- `lens-calibration.md` — a new audit lens is not done until it has been wrong on a real repo: five artifacts (probe, manifest, rubric, known-bad fixture, CLEAN TWIN), a per-finding REAL/FALSE-POSITIVE verdict against a real repository, and a mutation proof. Severity follows reachability; zero is a claim that needs a measurement.
- `audit-gating.md` — per-PR scoped (blast-radius) audit vs full nightly/on-demand fleet; what blocks a merge (P0/P1) vs what's tracked (P2/P3).
- `closed-loop-audit.md` — a finding without a rerun is half an audit: identify → fix →
  verify by RERUN. Every finding names the check that would prove it fixed; prefer a
  gate in the target repo to a one-time result; the rerun runs against the CHANGED
  commit; declined findings close via a ruling, not silence.
- `dreaming-cycle.md` — the daily autonomous LEARN→SCAN→ACT loop (CVE/dep research → scan all repos → auto-fix safe tier / propose the rest).
- `worktree-lifecycle.md` — per-task worktree birth→merge→teardown; delete the local worktree+branch right after a merge, behind 4 safety gates (`ops/post-merge-cleanup.sh`), so zombie branches / root-owned leftovers never pile up.
- `agent-security.md` — agent-RUNTIME security (lethal trifecta, prompt-injection→tool-exec, MCP Top-10) applied to an earlier messaging product/Zero/dream-fix; the code-security gates live in `security.md`.
- `self-healing.md` — the OS medic: auto-remediation (railway redeploy / vercel rollback) on confirmed-down, heal-immediately-then-notify, with anti-flap + cooldown + escalation. The action layer atop the detect+alert monitors.
- `verify-before-assert.md` — check ground truth before calling anything stale/unused/violating; an instruction describes the world, it is not evidence about it. The 60-second checks (curl the `server:` header, `gh api` every repo, `git ls-remote` not push output, confirm a gate's binary exists). Born from 4 false assertions in one session, 2026-07-20.
- `coding-hygiene.md` — Karpathy universal LLM-coding-pitfall guardrails (think-before-coding, simplicity, surgical changes, goal-driven); the always-on hygiene layer in the operator CLAUDE.md.
- `merge-gate.md` — never merge on "no checks": `ops/merge-gate.sh` (head pinned, >=1 check, explicit required list derived from the repo's workflows, 3 consecutive polls); plus PR-range secret scans, same-job-baseline perf gates, seeded-resource probes. Born from a destructive migration merged with zero CI (2026-10-25).
- `host-capacity.md` — one heavy test suite at a time host-wide (`ops/host-lock.sh`, re-entrant), lock layering, agent fan-out cap, never prune/fstrim a busy Umbra guest, forensics before rebuild (2026-10-25: guest ext4 corrupted 3x in 2 days).
- `worktree-process-hygiene.md` — empty start commit in every new worktree, kill only PIDs you started, subagent handoff role files + `block-handoff-clobber.sh`, Remote Control `!` does not run.
- `test-isolation.md` — tests running mutating git use a sanitised env (`ops/test-git-env.sh`, `ops/check-test-git-env.sh`); a hook-exported `GIT_DIR` turned a test `git init` into a mutation of the real repo; runtime-built secret fixtures.
- `session-handoff.md` — lossless session continuity: a **per-session** handoff (`<repo>/.handoff/<session-id>.md`, else `~/.claude/handoff/<session-id>.md`) with Goal/State/Done/In-progress/Left, surfaced on SessionStart + flushed before compaction, with a `⚑HANDOFF` statusline badge at 40% context remaining so clearing the chat stays cheap. Per-session since 2026-08-26: one shared path let two parallel sessions silently destroy each other's state. (`ops/handoff.sh` + `ops/lib/handoff-paths.sh` + hooks.)
- `rules/` — per-language/framework rule packs (typescript, react-nextjs, node-express, prisma-postgres, bash-ops) auto-relevant by file type; distilled from real incidents. `rules/enforcement-map.md` is the rule → enforcer table kept by the `correct` skill.
- `migrations-backward-compatible.md` — a migration must work for the release running now AND the one a rollback returns to: expand only before the deploy, new code tolerates old values, rejecting triggers/constraints/drops one release later (parked, gate in a ruling), rollback works, the previous release's backups load, applied migrations are never edited. Born from Ebda Store D1 0009 (audit 2026-11-12 P2-2).
- `rulings.md` — the dispatch record: every decision that overrides a plan, rejects a finding or accepts a residual is written down with its evidence and **what it costs if it is wrong**, at decision time, in a tracked ledger. Stops re-litigation and makes a declined finding traceable. From the course-platform build's 32 rulings (2026-09-04).
- `common-test-files.md` — the shared test-infra (prod-guards + setup) every repo and every worktree must always keep + propagate; the registry teardown gate 4 confirms.

## Memory lessons folded into this standard

Cross-reference so `dream-standard-drift.sh` (which matches the memory-file slug verbatim) sees each cross-cutting lesson as covered, and a human can trace lesson → standard doc. The **concept** was already in the standard for the first group; the last two were newly folded into `deps.md` (crit 10–11) on 2026-07-01.

| memory lesson (slug) | lives in |
|---|---|
| `feedback-blast-radius-sweep-on-every-change` | `audit-gating.md`, `unified-audit.md`, `dreaming-cycle.md` (+ `ops/blast-radius.sh`) |
| `feedback-migrate-before-deploy-and-force-dynamic` | `deploy-verify.md`, `cicd.md` |
| `feedback-workers-no-module-env-secrets` | `security.md`, `environments.md` |
| `feedback-cf-workers-builds-autonomous-cicd` | `cicd.md`, `deploy-verify.md` |
| `feedback-cf-migration-platform-host-drift` | `deploy-verify.md`, `environments.md` |
| `feedback-audit-severity-by-deployment-scope` | `audit-gating.md` |
| `reference-php-laravel-lens-pack` | `lens-calibration.md` |
| `feedback-parallel-test-shared-db-truncate-race` | `testing.md`, `common-test-files.md` |
| `feedback-react19-form-action-resets-uncontrolled-inputs` | `frontend-quality.md` |
| `feedback-subagent-pnpm-pollution-dual-react` | `deps.md` (crit 10) — **new 2026-07-01** |
| `feedback-pnpm-react18-19-types-coexistence` | `deps.md` (crit 11) — **new 2026-07-01** |
| `feedback-session-handoff-and-context-hygiene` | `session-handoff.md` — **new 2026-07-14** |
| `ci-merge-gates-never-merge-on-no-checks` | `merge-gate.md`, `cicd.md` — **new 2026-10-25** |
| `host-capacity-one-heavy-suite-and-guarded-umbra` | `host-capacity.md`, `disk-discipline.md` — **new 2026-10-25** |
| `worktree-process-and-handoff-hygiene` | `worktree-process-hygiene.md`, `session-handoff.md` — **new 2026-10-25** |
| `feedback-hook-exported-git-dir-turns-a-test-git-init-into-a-repo-mutation` | `test-isolation.md` — **new 2026-10-25** |
| `privacy-placeholders-and-erasure-ordering` | `erasure-export-endpoints.md` — **new 2026-10-25** |
| `feedback-jsonparse-any-poisoning` | `rules/typescript.md` (Must Always + Traps) — **new 2026-07-14** |
| `feedback-gate-that-cannot-fail-reports-success` | `gate-integrity.md` (lens 27) — **new 2026-09-02** |
| `feedback-test-that-passes-for-the-wrong-reason` | `mutation-proof.md` (lens 28) — **new 2026-09-02** |
| `feedback-enumeration-is-a-measurement` | `enumeration-integrity.md` (lens 29) — **new 2026-09-02** |
| `feedback-a-record-of-proof-can-be-false` | `mutation-proof.md` (§2) — **new 2026-09-04** |
| `feedback-fake-that-reimplements-what-it-verifies` | `testing.md` (crit 14–16) — **new 2026-09-04** |
| `feedback-gate-ships-a-different-build` | `cicd.md` (gate↔artifact section) + `gate-integrity.md` (§2) — **new 2026-09-04** |
| `feedback-ruling-form-cost-if-wrong` | `rulings.md` — **new 2026-09-04** |
| `feedback-security-fix-claims-about-who-it-does-not-affect` | `auth.md` (crit 8-10) — **new 2026-09-05** |
| `feedback-csrf-guard-method-aware` | `auth.md` (crit 7) — **new 2026-09-04** |
| `feedback-never-run-gate-is-the-deadest-gate` | `gate-integrity.md` + `common-test-files.md` (crit 6) — **new 2026-09-04** |
| `feedback-monitor-alert-measures-the-monitor` | `observability.md` + `common-test-files.md` (shape-aware gate 4) — **new 2026-09-04** |
| `feedback-test-truncate-wiped-prod-db` | `common-test-files.md` (crit 1-3; it is that doc's `sources:` line) — **new 2026-09-04** |
| `feedback-umbra-unclean-stop-fsck-before-runners` | `umbra-guest-integrity.md` — **new 2026-10-26** |

> The drift detector's exact-slug match is why concepts already covered (e.g. blast-radius) still flagged as "gaps" — this mapping is the canonical fix; add a row here whenever a new cross-cutting lesson lands so the detector stays accurate.

## Tag legend

- `[BUILD]` — used when scaffolding/guiding a new product.
- `[AUDIT]` — used as a grading criterion against an existing repo.
- `[BOTH]` — both (most items).

## Sources merged into this standard

- `~/.claude/CLAUDE.md` — the 15 code-quality rules
- `~/.claude/PRODUCTION-SAAS-BUILD-PLAYBOOK.md` — 16-section playbook
- `~/.claude/projects/-Users-ahmadsharaf/memory/reference-iceberg-audit.md` — 38-term audit
- `~/.claude/projects/-Users-ahmadsharaf/memory/reference-audit-fleet-and-build-playbook.md`
- `~/.claude/projects/-Users-ahmadsharaf/memory/` — 15-layer grading matrix
- `storefront-locale-routes.md` — every storefront route keeps the locale prefix (cart/checkout/account/search too, never a redirect to the unprefixed path); sitemap = all public pages x locales with hreflang + lastmod, robots names it. Born from the Amelia QA store 2026-11-11.
