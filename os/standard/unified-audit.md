# The Unified Deep Audit — the ONE audit ("Claude, audit this repo")

**Purpose (Ahmad, 2026-06-10):** when the trigger is "audit this repo", run ONE blended audit that contains EVERY audit type we have, end to end — every layer, every feature, every page, every cell, every letter — and return a single report: **what is broken, what must be fixed, WHERE exactly, and what ELSE it breaks (blast radius) so the whole system is brought to ONE level of maturity.** "You can't fix one part and leave the other unfixed — it all has to be on the same page." This is the human-grade "give my software to someone to test it A→Z" deliverable, distilled from 1.5 years of testing, traps, and fixes now living in memory + this `standard/`.

This audit IS steps 1–3 (ANALYZE → BLAST-RADIUS → AUDIT) of the self-improving loop (`feedback-os-self-improving-audit-loop`); it is followed by FIX-everything → save-memory → propagate-to-all-repos → save-memory → graphify → test+verify+REAL-test → loop.

## How it runs (the fleet)
Dispatch one focused agent per DIMENSION below (parallel), each: (a) reads `graphify-out/GRAPH_REPORT.md` first, (b) grounds findings in CODE (file:line) AND in PROD DATA (read-only managed Postgres query for the smoking-gun symptom), (c) grades against the linked `standard/` rubric (0=broken / 1=partial / 2=solid), (d) returns findings in the unified row format. Then a synthesis agent merges them into the ONE report, dedupes, builds the cross-cutting matrices, and assigns the verdict. Scale the fleet to the repo; never drop a dimension silently — if one is N/A, say so.

## LOOK EVERYWHERE — multi-source triangulation at EVERY step (2026-06-10, Ahmad)
**Reading the code is never enough. At every step of the audit AND every bug investigation, cross-reference ALL of these sources — the truth is where they intersect:**
1. **The code** (file:line, the graph, the contracts between layers).
2. **Sentry** — the live error stream. Query it for the exact error class + COUNT (2× = one user's bug; 1000× = systemic) + `lastSeen` (does it match the report's timestamp?) + the EVENT (stack frames, `transaction`/`url` tag, request body, breadcrumbs). The endpoint + frame in the stack usually names the bug.
3. **Prod logs (Railway / the runtime)** — what Sentry DROPS. A provider/integration often throws a generic message to Sentry ("Invalid data") while the SPECIFIC cause (the rejected field, the validation array) is only in the structured `logger.error(...)` on Railway. Always check the logs for the detail the thrown error swallowed.
4. **The DB (read-only) symptom** — the row that proves it (e.g. the order's empty `email`, the stuck `paymentStatus`). Read-only; never pull customer PII into the transcript without explicit approval.
5. **The alert channels** — `alert-triage` (Sentry + UptimeRobot + Railway + Gmail/CI), the synthetic monitors (`checkout-monitor`), the anomaly snapshot. The OS already aggregates these; READ them.
6. **The live surface itself** — render/curl/drive it (the VERIFY phase below).

**Proof case (the cost of looking at code alone):** a payment-checkout P0 showed only `Error: Invalid data` in Sentry. Reading the code alone could not say WHY. Triangulating — Sentry (endpoint `POST /payments/create` + the provider stack frame) + the code (email is OPTIONAL at checkout, flows as `''`) + the existing code comment ("the provider rejects empty emails") + the screenshot (no email entered) — pinpointed it: a blank customer email sent to the payment provider. The Railway logs held the exact `ValidationErrors` Sentry had dropped. **A finding is only as good as the number of independent sources that confirm it.** When sources DISAGREE (code says X, Sentry says Y), that gap IS the bug.

**Corollary — fix the diagnosability too:** if an integration throws a generic message and buries the real cause in logs (the way a provider wrapper threw only `Message` and dropped `ValidationErrors`), FIX that as part of the finding — surface the specific detail into the thrown error so the NEXT failure is one-source-diagnosable.

## The DIMENSIONS (every audit type, blended — each maps to a rubric + memory lens)
1. **Layer traversal & data flow** — client → API → DB/RLS → async(worker/webhook/cron); trace every business flow hop-by-hop GREEN/RED/UNKNOWN. → `architecture.md` + `feedback-layer-traversal-audit-and-contract-drift`.
2. **Blast radius & feature×feature interaction** — graphify kernels (shared pkgs, DB schema, RLS, auth, payment) → transitive dependents; **how a broken feature affects other features**; overlap/clobber/dead-code coexistence. → graphify + `feedback-always-remove-dead-code-and-dead-ui`.
3. **Inter-layer contract drift** — client payload ↔ server schema (field names, required-ness, `''`-vs-`undefined`, types, enums); response shape ↔ client reader; DB column nullability ↔ code assumption. (The class that broke checkout city/email + admin pagination.) → `feedback-layer-traversal-audit-and-contract-drift`.
4. **Security (OWASP ASVS)** — injection (SQL/XSS/log), authn/authz, secrets, CSRF, rate-limit, headers (CSP/HSTS/nosniff), PII masking, the AI-code failure modes (≈86% XSS, ≈88% log-injection, 2× secret-leak). → `security.md`, `auth.md` + `feedback-ai-security-checklist`.
5. **Tenancy / RLS writer-coverage** — which tables FORCE RLS; does EVERY writer (HTTP + webhook + worker + cron + script) set the tenant GUC or bypass correctly. (The class that silently broke payments.) → `rls.md` + `feedback-rls-force-coverage-breaks-async-writers`.
6. **Iceberg / production-reality (38-term)** — alerting, log drain/retention, consent gate, GDPR / local data-protection-law erasure, env isolation, external alert bridge, audit gate, etc. → `reference-iceberg-audit` + `deploy-verify.md`, `environments.md`, `event-log.md`.
7. **Scaling & money** — explicit `select`, indexed WHERE/ORDER BY, cursor pagination + hard caps, edge cache + tag invalidation, async >300ms, p95 ceiling; money = double-entry/tx integrity, idempotency, exactly-once side-effects, **plus the provider boundary** (webhook signature verified over the raw body, duplicate delivery a no-op by DB unique constraint, out-of-order cannot regress state, the PSP redirect is never confirmation, pending payments driven to terminal, ledger reconciled against the settlement report with an alert on mismatch). → `scaling.md`, `money.md`, `cache-ratelimit.md`.
8. **Reliability & observability** — idempotency, retry-safety, exactly-once (BullMQ/Inngest redelivery), Sentry, distributed tracing, SLO/error-budgets, DR/backup/rollback. → `observability.md`, `dr.md`.
9. **Save-integrity (S1–S6)** — enum-drift silent save-fail, date-422, masked-secret round-trip, optimistic-save swallow, create≠edit parity, unbounded lists; plus "saved-but-not-on-storefront". → `data-ui-coverage.md`.
10. **Data→UI coverage** — every business table has a UI surface; no dead data; no dead code/UI; canonical owner = newest system. → `data-ui-coverage.md`.
11. **UI/UX consistency & persistence** — design-system consistency PAGE×PAGE and THEME×THEME (spacing/typography/ratio/tokens), "every UI consistent + persistent with every other UI", WCAG 2.1 AA, RTL/bilingual parity, the per-page design controls. → `frontend-quality.md` + the a previous storefront product UI/UX rules.
12. **CI/CD & the 5 testing layers** — canonical workflow shape, every layer (unit/integration/E2E/load/UAT) green for touched paths, the missing-test gaps that let regressions through. → `cicd.md`, `testing.md`.
13. **Dependencies** — registry-exists, <12mo, license, `npm audit` 0/0/0/0, framework-downgrade trap. → `deps.md`.
14. **Docs / contract parity (MANDATORY every audit — "docs always match live code")** — EVERY doc type must be diffed against the live code/runtime and flagged STALE with the exact wrong lines, never skipped: README/ROADMAP/DEPLOYMENT, `docs/business/*`, `docs/merchant/*`, runbooks/architecture, the 4 client HTML contract templates, plan-feature-matrix ↔ runtime gating, CLAUDE.md ↔ code, **the Obsidian vault (`wiki/projects/*`, `wiki/_moc/*`) and the personal/identity notes (`user-profile.md` + its `_claude-memory/` vault mirror) ↔ current reality**, and the scoped memory ↔ current code. Identity/personal facts that only the user can confirm (role, title, status, portfolio) are surfaced as "VERIFY-WITH-USER", not fabricated. → `docs-parity.md` + `ops/docs-scan.sh` (cheap scheduled heuristic tier).
15. **Mobile store-readiness** (if a mobile app) — Sign-in-Apple, account-deletion, IAP, anti-steering, PrivacyInfo, ATT. → `mobile.md`.
16. **Feature-flags & environments** — 4-layer flags, preview≠prod isolation. → `feature-flags.md`, `environments.md`.
17. **Migration safety** — expand/contract (never add+drop in one migration), a rollback written WITH the migration, a current staging mirror, and the violating-row query run against PRODUCTION with the same predicate the constraint will have. Boot-time migrations mean a failed constraint is an outage, not a red pipeline. `migrate diff` is a lead, not ground truth. → `migration-safety.md`.
18. **Error-surface containment** — two layers (public message + correlation id vs private full record), enforced at EVERY boundary including jobs, webhooks, payment callbacks and cron — not just HTTP routes. No stack/driver/SQL/env text in any user-reachable response, preview included. → `error-surface.md`.
19. **AI transparency (SGI)** — visible non-removable disclosure on AI-generated output AT RENDER (not in the admin editor), affirmative consent before user input reaches a model, and an immutable generation log (timestamp, model, prompt, destination). Obligation follows the USER's location. → `ai-transparency.md`.
20. **Edge protection** — WAF in front of the whole stack including the API origin, origin not directly reachable, adaptive escalation rather than one fixed cap, tighter caps on AI/export/search endpoints, and an exercised abuse playbook. → `edge-protection.md`.
21. **Unit economics** — usage attributed by feature AND tenant, converted to currency, and JOINED to what that tenant pays. Instrumented is not measured: if nothing divides spend by revenue, the ratio does not exist. → `unit-economics.md`.

## The OUTPUT (one report → `docs/audits/<date>-unified-deep-audit.md`)
- **Findings table** — every finding as: `dimension | severity P0–P3 | EXACT location (file:line / page / field) | what's broken | the fix | BLAST-RADIUS (every other file/layer/feature that must change in lockstep) | maturity-parity note`.
- **End-to-end flow tables** — each core flow, every hop GREEN/RED/UNKNOWN with evidence.
- **Feature × feature interaction matrix** — for each feature: which other features its breakage/change impacts (the "broken future affects the other futures" map).
- **UI/UX consistency matrix** — page×page + theme×theme drift.
- **Blast-radius / maturity-parity map** — the kernels and, for the proposed fixes, the FULL set of connected parts that must be brought to the same level (a fix is INCOMPLETE until every dependent is at the same maturity — like a mind, no part left behind).
- **Single production-readiness VERDICT + 0/2 score per dimension**, ranked must-fix list (P0 first), and the exact next fixes with their blast radius.

## The VERIFY phase — MANDATORY tail of every finding's fix (2026-06-10, Ahmad)
A finding is NOT "done" when the code is written and `tsc` passes. "Theoretically working" is the trap that shipped a WhatsApp logo that didn't render. Close the loop, in order, for EVERY fix — this is the reliability contract:
1. **Reason** the real root cause(s) — they are often LAYERED (the OG-logo bug was 3 stacked bugs; only the 3rd, "Satori can't rasterize SVG", explained why it still failed).
2. **Fix.**
3. **Test on the Mac** — run the REAL thing, not just `tsc`. For a visual/render/image output, **produce the artifact and LOOK at it** (Read the `.png`). For logic, run the unit test. For an API, `curl` it and check status/content-type/body.
4. **CI** — push, let CI run, make it PASS (never admin-bypass a real failure; only a proven infra-flake).
5. **Live test AFTER deploy** — exercise the real production surface AND **render/look at the actual result**: Read the deployed image `.png`, drive the page in Chrome, curl the endpoint, re-scrape OG previews via the Facebook Sharing Debugger. Confirm with your own eyes, then it's done.

"Should work" / "tsc clean" / "the code is correct" is **NOT done.** The OS runs this loop using its own reasoning (the audit) → Mac tests → CI → live tests; findings → fix → re-run the loop → save to memory → propagate. Full rationale + the proof case: `~/.claude/.../memory/feedback-verify-by-rendering-not-reasoning`.

## The non-negotiable principle
A finding is not "fix line X." It is "fix line X **and** every layer/feature/page the blast radius touches, to the same level of maturity." The audit's job is to make that complete set visible so the FIX phase leaves no bite behind and the whole system stays connected and coherent.

**Source of truth:** this file + the linked `standard/*` rubrics + the linked `~/.claude/.../memory/*` lessons. Every run that discovers a new bug-class or lens APPENDS it here + to memory (the loop's step 10) so the next audit is stronger. This is how the Foundation makes every current + future project better every run.

Original incident narrative: [standards incidents](../../docs/history/standards/incidents.md).
