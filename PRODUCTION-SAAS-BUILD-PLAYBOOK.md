# Production SaaS Build Playbook — A to Z

> **Authority:** The canonical reference for building a new multi-tenant SaaS product (or bringing an MVP to production-grade) at Ebda AI Studio. Derived from the audit and remediation history of the predecessor products (kept in `docs/history/`) and from the Ebda stack. Follow it end-to-end when building anything new or hardening an existing project.
>
> Created 2026-06-01, ported into ebda-foundation 2026-11-05. Pair with the standards in `os/standard/` (start at `os/standard/00-index.md`). Where this file and a project's own docs disagree, the project's docs (newer, specific) win. Brand rules come from `@ebda/foundation/brand` (night + Ebda gold, no orange); user-facing copy says "Ebda AI Studio" or the product name, never a bare "Ebda".

---

## 0. How to use this document

- **Greenfield (new product):** read top-to-bottom, run §1 (ecosystem research) → §2 (architecture decisions) → §3 (foundations) BEFORE writing features. Then build features through the §4–§13 gates.
- **MVP → production (the common case):** run **§15 The Gap Audit Fleet** first to find where the MVP is below bar, then close gaps in priority order using §3–§13 as the target state.
- **Every section is a checklist.** A line is "done" only when it is landed on `main`, verified, and (if it touches data a human reads) has a UI surface.

The iceberg metaphor: an MVP that "works in the demo" is ~10% of a production product. The other 90% — auth edges, RLS, idempotency, observability, rate-limiting, DR, scaling, compliance, CI, the five test layers — is below the waterline and is what this playbook makes explicit.

---

## 1. Before any code — ecosystem research + positioning

1. **Run `/ecosystem-research <domain>`** (mine 20 GitHub repos + HN + StackOverflow for production failures in the domain). The `PITFALLS-EXTERNAL.md` output is a required input to the plan doc.
2. **Write the positioning** — what are the 3–4 pillars this product competes on? (Example pillars: customization granularity, AI-as-default, Arabic-first locality, right-sized for the Egyptian market.) Every later feature decision is judged against these. Generic table-stakes features get the minimum bar; on-pillar features get investment.
3. **Write the plan** in `docs/plans/<date>-<slug>.md` (use the `superpowers:writing-plans` skill for anything bigger than one file). Include a "Prior art + known traps" section seeded from step 1.

---

## 2. Architecture decisions (lock these on day 1)

| Decision | Default that has worked | Why |
|---|---|---|
| **Monorepo** | npm workspaces: `apps/{api,admin,web}` + `packages/{database,shared,ui,config}` | Shared types/Zod across API + both frontends; one source of truth for contracts. |
| **API** | Express + TypeScript (or NestJS for bigger teams) | Explicit middleware chains for auth/tenancy. |
| **Frontends** | Next.js App Router (admin + storefront separate apps) | Per-app auth, per-app deploy, independent scaling. |
| **ORM + DB** | Cloudflare D1 (SQLite) + Durable Objects for per-tenant coordination; Postgres (via Hyperdrive) where relational scale demands it | Migrations as committed SQL; one source of truth per tenant; no cross-tenant query path. |
| **Multi-tenancy** | Postgres **RLS** with a per-request GUC (`app.current_store_id`) set via AsyncLocalStorage middleware | Defense-in-depth: even a missing `WHERE storeId` can't leak across tenants. **See §3.2 — the single highest-leverage + highest-risk decision.** |
| **Cache** | Redis (two-tier: Redis → in-memory bounded map → CDN s-maxage) | TTL floor ≥120s to protect DB compute on cache-miss. |
| **Async / jobs** | Inngest (or BullMQ) for anything >300ms or 3rd-party | Retries, dedup, self-register-on-boot. |
| **Real-time** | Socket.io **with `@socket.io/redis-adapter` from day 1 if you'll ever scale** | In-process adapter breaks the moment you run >1 replica. |
| **Auth** | Custom JWT in HTTP-only cookies, `SameSite=None; Secure` cross-origin | API + frontends on different domains → all route protection is client-side; never put cookie auth in Next.js middleware (redirect loops). |
| **Deploy** | Cloudflare Workers for API and frontends (wrangler config per app; check which Cloudflare account it targets before deploying) | Migrations apply in the deploy job; a merge is not a deploy, so verify the live commit. |
| **Money** | integers in the smallest unit (fils/cents), never floats | No rounding drift. Centralize all money math in one tested helper module. |

---

## 3. Foundations (build these before features)

### 3.1 Auth + authorization
- One auth provider per frontend (`AuthProvider`) — the ONLY auth checker. No page re-checks `/auth/me`.
- Standard middleware chain on every protected route: `authenticate → authorize(...roles) → requireResourceAccess → handler`. Pick ONE role-check helper name and use it everywhere (mixing `authorize()` and `requireRole()` causes drift).
- Every endpoint with a tenant-id param MUST have the ownership guard (`requireStoreAccess`). Public endpoints must NOT.
- Auth rate limit: 5 attempts / 15 min / IP+email.
- JWT lifetime documented; stale-role-requires-relogin is acceptable but documented.

### 3.2 Multi-tenant RLS (the load-bearing decision)
- Enable RLS + `FORCE ROW LEVEL SECURITY` on every tenant-scoped table.
- **Connect the app as a NON-owner role** (e.g. `force_app`) — the owner role (`neondb_owner`) has `rolbypassrls` and silently bypasses every policy, so if you develop as owner, RLS is never actually exercised until the cutover, and then everything breaks at once.
- Policy shape matters: a policy with an `IS NULL`-escape (`current_store_id() IS NULL OR store_id = current_store_id()`) **allows all** when the GUC is unset; a policy without it (`store_id = current_setting(...) OR bypass_rls`) **blocks** when unset. Standardize on ONE shape per table class and know which.
- **Two escape hatches, never confused:**
  - `withRlsBypass(fn, {maxWait:10000,timeout:30000})` — sets `app.bypass_rls='true'`. ONLY for genuinely cross-tenant super-admin reads, on super-admin-guarded routes. Wrongly bypassing a tenant query = cross-tenant leak.
  - `runInTenantContext(storeId, fn)` — sets `app.current_store_id`. For single-store work outside the request middleware.
- **The cutover trap (learned the hard way):** flipping prod from owner→app-role silently breaks (a) EVERY super-admin cross-tenant read and (b) EVERY Inngest/cron job query (jobs have no request → no GUC). Both fail as *empty results or throw-on-empty*, not a permission error, so `/health` stays green. **Before the cutover, sweep every `authorize('super_admin')` handler + every job and classify each DB access** (cross-tenant→bypass / single-store→tenant-context / behind-middleware→leave). See `feedback-rls-owner-cutover-breaks-superadmin-reads.md`.

### 3.3 Money + transactions
- All money in integer minor units. One `discount.ts`/`money.ts` helper module with unit tests (round, clamp, apply).
- Prisma `$transaction` defaults `maxWait` to **2s** — under burst load on a pooled Postgres this throws P2028 → 500. Always pass `{maxWait:10000, timeout:30000}` via a `withMoneyTx` wrapper. **When you add such a shared wrapper, add it to every test mock factory in the SAME commit** (mocks that don't export the new symbol → `undefined` → throws; typecheck won't catch it, only the test run will).
- The `create + catch(P2002)` idempotency pattern BREAKS inside a transaction (Postgres aborts the outer tx on the unique violation). Use a Postgres `SAVEPOINT` instead.
- Any `findFirst` with an `OR` that can match multiple rows MUST have an explicit `orderBy` (heap order is non-deterministic and drifts with VACUUM).

### 3.4 Append-only event log for money/trust state
- Every business-critical state machine (payment, order, subscription, payout, loyalty tier) writes to an append-only `<entity>_events` table at every mutation, preserving the raw 3rd-party webhook payload. `entity.status` = current state; the events table = how it got there. Non-negotiable for anything touching money.

### 3.5 Caching + rate-limiting (replica-safe from the start)
- Redis-backed rate limiting (`rate-limit-redis`) so limits are shared across instances — an in-process limiter is meaningless with >1 replica.
- Two-tier cache with tag invalidation; TTL floor ≥120s; sub-2-min needs go to in-memory bounded map, not Redis.

### 3.6 Feature flags — enforce at FOUR layers
UI hide + API gate (`requireFeature → 503`) + async-job gate (check flag at handler start) + service-level dual-gate. UI-only hiding is a billing leak. Super-admin bypasses every gate consistently. Plan-baseline + per-store override resolution: `enabled = override ?? PLAN_BASELINE[plan].includes(key)`; plan changes never touch override rows.

### 3.7 Every-data-needs-a-UI
Every table whose rows mean something to a human (merchant/admin/customer) MUST have a UI to view them. Backend-only data with no viewer is a defect. Exempt: pure infra tables (`_prisma_migrations`, rate counters). Enforce at plan time and PR time.

---

## 4. Scaling — vertical + horizontal

- **Vertical** = host CPU+RAM (or Worker CPU-time and DO limits). Cheap first lever. Set sane production values (e.g. 1 vCPU / 1 GB) and validate against real `process.memoryUsage().rss` from `/health`.
- **Horizontal** = replicas > 1. Code prerequisites BEFORE flipping the slider:
  1. **Socket.io redis-adapter** (else cross-instance events break — a client on replica A misses an emit from replica B).
  2. **Cron leader-election** — every module-level `setInterval`/recurring timer must be gated by a Redis lock (`SET key val NX PX ttl`) so only one replica runs each tick (else 2 replicas = double emails/double scans). Inngest crons are exempt (Inngest dedups centrally). Queue workers using atomic `RPOP` are exempt (each pops distinct items).
  3. Redis rate-limit + shared cache + pooled DB (already from §3.5).
  4. Provide a Redis-absent fallback (in-process adapter + "this instance is leader") so local single-instance dev still runs everything.
- Document it all in `docs/SCALING.md`: prerequisites checklist, dashboard steps, and what to watch after scaling (DB connection count vs pool limit, Redis memory).

---

## 5. The five testing layers (every revenue/PII/ops project)

| Layer | Tool | CI status | Minimum bar |
|---|---|---|---|
| **Unit** | vitest/jest | hard gate | pure logic, mocked deps, runs <10s |
| **Integration** | real DB + service + API | hard gate (NOT `continue-on-error`) | `TRUNCATE ... RESTART IDENTITY CASCADE` in `beforeAll` per table written |
| **E2E / automation** | Playwright | on every PR (not just local) | golden-path flows |
| **Load** | k6 | manual, re-run before each merchant launch | documented p95 ceiling; fix p95>500ms before ship |
| **UAT** | `docs/uat/<feature>.md` checklist | per feature | golden-path + edge-case steps |

Static marketing pages are exempt from integration+load+UAT (still need unit + E2E-smoke). **No feature ships to a paying customer without all 5 green for the touched paths.**

Jest/vitest + Prisma teardown discipline (or CI hangs 30–45 min): every module-level `setInterval`/`setTimeout` exported + cleared in `afterAll`; every Prisma singleton `$disconnect()` in teardown; `testTimeout: 30000` for Neon cold starts; never `--forceExit` (it masks the leak).

---

## 6. CI/CD standard (every repo converges to this)

`.github/workflows/ci.yml` with:
- **Top-level concurrency group** (`cancel-in-progress: true`) so superseded pushes don't pile up.
- **`timeout-minutes` on EVERY job** (anti-hang: lint=5, typecheck=10, build=15, unit=10, integration=15, E2E=20, audit=5).
- **Prisma `db:generate` BEFORE typecheck** (else tsc reports hundreds of phantom errors from missing client types).
- **Audit split:** prod zero-tolerance (`npm audit --audit-level=low --omit=dev`), dev gated at high (unfixable transitive vulns in tooling).
- **`notify-failure` job** firing Telegram (`TELEGRAM_BOT_TOKEN` + `TELEGRAM_ALERT_CHAT_ID`) on `failure() && main && push` — sleep-proof, this job STAYS on cloud even if everything else is self-hosted (fail-open).
- **gitleaks** workflow paired with `.gitleaks.toml` (allowlist) + `.gitleaksignore` (documented false positives), scanning ALL branches with `fetch-depth: 0`.
- **Branch hygiene:** only `main` (+ `preview` if staging). No `test-*`/`staging`/`vercel/*` orphans (orphan branches with old creds trip the gitleaks all-branch scan even after main is scrubbed).
- **Pre-push hook** mirrors a CI subset (lockfile drift + prisma generate + lint + typecheck + unit) to catch issues 90s before burning runner minutes.

**Runner routing (self-hosted-with-cloud-override):** the reliable pattern is `runs-on: ${{ (inputs.force_cloud || vars.USE_SELF_HOSTED != 'true') && 'ubuntu-latest' || fromJSON('["self-hosted","linux","wsl2"]') }}` — **defaults to cloud**, set repo var `USE_SELF_HOSTED=true` to route to a self-hosted box, `workflow_dispatch force_cloud` overrides per-run. **Trap:** keying runner choice on `inputs.force_cloud` ALONE means push/PR events (where `inputs` is empty) always fall through to self-hosted — so every CI run silently lands on your dev machine. Always include a non-input default (a repo `vars.*`). `notify-failure`/rescue jobs stay on `ubuntu-latest` unconditionally.

---

## 7. Deploy-time verification (before every risky push)

Before pushing anything touching deps / build config / migrations / env-var usage / service config, simulate the deploy target's EXACT commands locally (90s vs 30-min mean recovery on a failed deploy):
- Workers: `npm ci && npm run build && npx wrangler deploy --dry-run` (mirrors the deploy job).

Lockfile regen must match the deploy target on FOUR dimensions: Node/npm version (`engines.node`), platform (macOS skips Linux-only optional deps — pin explicit `@emnapi/*` etc.), scope (prod deps not dev, so `--omit=dev` doesn't drop them), and service rootDirectory (fix the right `package.json`).

Script-injected plain JS must be `node -c <file>` checked (typecheck doesn't catch malformed JS → container crash-loop).

---

## 8. Observability + alerting (before first customer)

- Error monitoring (Sentry) wired day 1 — on every job failure, every webhook, every money mutation.
- Uptime monitor + a P0 notification channel (Telegram/PagerDuty) before any customer goes live.
- Log drain with ≥30-day retention, documented in `docs/DEPLOYMENT.md` (verified, not assumed).
- External-alert bridge token set in prod with a boot-time warning if missing.
- SLO defined (p95 latency, error rate); queue-depth watch on async jobs.

---

## 9. Security gates (every commit)

- XSS, log injection, secret scanning (gitleaks pre-commit + CI), PII masking, Zod/Yup at EVERY API edge, CSP+HSTS+nosniff in prod.
- **CSV/export formula injection:** any value written to a CSV cell that starts with `= + - @` or a control char must be prefixed with `'` (else it executes when opened in Excel/Sheets). Guard inside the `csvField` serializer.
- Dependency discipline: registry-exists check, <12mo release, license-compat, `npm audit` 0/0/0/0, framework-downgrade `fixAvailable` is a trap (override the leaf).
- GDPR / local-law erasure on any auth system: `/auth/me/erase` + `/auth/me/export`.
- Cookie/tracking consent gate before any pixel fires.
- Secrets: never in git; rotate on any leak; history-scrub (filter-repo) + delete orphan branches if a real leak landed.

---

## 10. Data lifecycle + DR

- **DR = scheduled export of every datastore to a location outside the one that can fail**: for D1/R2, `os/ops/backup-ebda-cloudflare.sh` (retention set in the script); for any Postgres, a daily local `pg_dump` (needs `pg_dump` at or above the server major: an older client silently produces empty dumps). Restore is rehearsed (`os/ops/dr-drill.sh`), not assumed.
- Keep a `scripts/rollback.sh` (git revert + push, blocks on migrations), an on-demand backup script, and `docs/ROLLBACK.md` with the recovery paths (redeploy previous Worker version / git revert / restore export).
- Migrations are committed SQL that auto-apply on next boot — by the time you notice a schema bug it's already live, so additive-only by default (nullable columns, new tables); destructive changes need a written plan + backup.
- After any DB restore, re-verify RLS policy state (the runtime depends on policy shape).
- Branch hygiene on any branching database: only `production` (+ `preview` when staging is active); no per-commit auto-snapshots; never create branches without explicit instruction.

---

## 11. Environments

- Local dev points at a **scratch/preview DB branch**, NEVER prod. (Repeated trap: `.env` left pointing at prod as owner → RLS never exercised + risk of mutating prod.) Verify the host in `.env` before any `migrate`/`db push`.
- Preview/staging env points at staging API + staging DB, never prod. CI-enforced isolation check (`vercel env ls --json`).
- Shared queue broker between staging + prod needs a `QUEUE_PREFIX=<project>-staging` on every staging service, or staging jobs get processed by the prod worker against prod data.

---

## 12. Documentation parity

Every feature ships with ALL relevant docs updated in the SAME session (local + pushed): README, DEPLOYMENT, runbooks, architecture, merchant/client-facing, plan docs. No "docs follow later." When dispatching a subagent for a multi-file feature, include docs in that subagent's scope (don't dispatch docs as a follow-up — context is lost).

---

## 13. Working discipline (process rules that prevent rework)

- **Plan-before-code** for anything bigger than a one-file edit / multi-subsystem / cross-project.
- **Isolated worktrees for parallel work:** parallel fixers on the same repo share the working tree and corrupt each other — each subagent gets `git worktree add ../<repo>-<scope> origin/main -b <branch>` + an explicit out-of-scope guard. Integrate the branches **sequentially yourself** with a full typecheck gate; don't let N subagents push in parallel.
- **Push BEFORE pinging/opening PR** — GitHub's merge button snapshots origin at click time; commits pushed after the click silently orphan (true for Merge/Squash/Rebase).
- **Verify branch reality, not your mental model** — never claim "fixed/linter-fixed/subagent-fixed" without grepping the LIVE file on the branch about to be pushed (`git show <branch>:<path>`). Mental model drifts from branch state across long sessions.
- **One authoritative verification, not grep theatre** — "is the build clean?" = ONE `tsc` against a deps-backed tree, once. Don't claim done, re-check, un-claim.
- **Fix directly, no workarounds** — done = landed on main + verified, not patched around with a temp script or "works in CI."
- **macOS:** no `timeout` command; use background + read the output file. UTF-8/Arabic edits via Python or the Edit tool, never `perl -CSD` (silently fails on Arabic).
- **Memory pipeline after every commit** (auto). Scoped memory = source of truth; global MEMORY.md = one-line index.

---

## 14. The audit fleet — what to run and why

A production audit is not one pass; it's a fleet of focused lenses. Run the relevant subset at MVP→first-customer, quarterly, and after any P0. Each lens, why it matters, and what it caught on the predecessor products:

| Audit type | What it checks | Why it makes the product better |
|---|---|---|
| **STRIDE / threat model** | Spoofing, tampering, repudiation, info-disclosure, DoS, elevation per surface | Systematic security coverage instead of ad-hoc. |
| **Multi-tenant isolation** | Every query is tenant-scoped or intentionally + safely cross-tenant | The #1 SaaS catastrophe is cross-tenant leakage. Caught the owner→app-role RLS regression (13 super-admin endpoints + 2 job scans returning empty). |
| **PII / DPIA** | What PII is stored, masked, exportable, erasable | Compliance (GDPR / local law) + breach blast-radius. |
| **N+1 / query** | Loops issuing per-row queries | The "works at 100, dies at 1000" cliff. |
| **Index coverage** | WHERE/ORDER BY columns are indexed | p95 latency under real data volume. |
| **FK / cascade** | Delete/!update integrity | Prevents orphan rows + accidental mass-delete. |
| **Event-log / mutate-in-place** | Money/trust state changes are append-only with raw payloads | Auditability + dispute resolution. Found 8 mutate-in-place gaps on a predecessor product. |
| **Idempotency** | Retried webhooks/jobs don't double-apply | Double-charges / double-emails. Found the in-tx P2002 SAVEPOINT bug. |
| **Scaling-cliff** | Cursor pagination, take caps, edge cache, job offload | Survives traffic growth without a rewrite. |
| **Race conditions** | Concurrent mutations on shared state | Double-send, stale-cart, lost updates. |
| **Memory-leak** | Module-level timers, unbounded maps, undisconnected clients | CI hangs + prod OOM. Found the setInterval CI-hang. |
| **Rate-limit** | Every public + auth + expensive endpoint is limited, Redis-backed | Abuse + cost control + replica-correctness. |
| **Observability / SLO** | Sentry, alerting, log retention, queue-depth watch | You learn about failures before customers do. |
| **DR-drill** | Snapshot + rollback + restore actually work | Recovery is rehearsed, not discovered during an incident. |
| **Code-quality** | Patterns, complexity, consistency, no `any` leaks | Maintainability; lowers future bug rate. |
| **Type-safety** | Strict-ish tsc, no implicit any at edges | Catches whole bug classes at compile time. |
| **a11y / WCAG** | Keyboard, contrast, aria, RTL | Reach + legal + quality signal. |
| **Perf / CWV** | Bundle size, LCP/CLS/INP, image optimization | Conversion + SEO. |
| **i18n / RTL** | Bilingual parity, RTL-correct admin + storefront | Locality pillar; Arabic is not an afterthought. |
| **SEO** | Meta, OG, sitemap, structured data, hreflang | Discoverability for storefronts. |
| **CI/CD** | Concurrency, timeouts, audit split, notify-failure, runner routing | Reliable, sleep-proof pipeline. |
| **Deps / license** | Outdated, vulnerable, license-incompatible, unused | Supply-chain + legal. |
| **Cost** | Per-tenant compute/storage/API spend | Unit economics before scale. |
| **Feature-enforcement coverage** | Every flag enforced at all 4 layers | Billing leaks. |
| **Auth/access coverage** | Every route has the correct middleware chain | Broken-access-control (OWASP #1). |
| **UI-coverage** | Every meaningful table has a viewer | "Every data needs a UI." |
| **Admin-endpoint-connection** | Every admin UI action maps to a working endpoint | Dead buttons / 404s. |
| **Redundancy / consolidation** | Same setting editable in 2+ places; orphaned pages | UX clarity = competitive value; found social-links + announcement + hero split-brains and 5 orphaned pages on a predecessor product. |

**The Iceberg Audit** is the structured 38-term verification pass that bundles many of these — dispatch it as a single Sonnet sub-agent (skeleton + term list in `~/.claude/projects/-Users-ahmadsharaf/memory/reference-iceberg-audit.md`). Run cadence: MVP→first customer (always), quarterly on every prod project, after any P0, and when a new standing rule is added.

---

## 15. The Gap Audit Fleet (MVP → production, the practical entry point)

When handed an MVP, don't guess — dispatch a fleet of read-only audit subagents (Sonnet, isolated, parallel), one per lens from §14 relevant to the product, each producing a `docs/audits/<date>-<lens>.md` with findings ranked Critical/High/Medium. Then:
1. Dedup + classify findings (a barrier step — needs all findings together).
2. For each Critical/High, dispatch a fixer in an isolated worktree.
3. Integrate sequentially with a typecheck gate; land on main.
4. Re-audit the touched paths. Loop until the Critical/High list is dry.

This is exactly the workflow that took a predecessor product through this session: full fleet audit → root-cause every finding → grouped fixes in worktrees → sequential integration → verify deploy health.

---

## 16. Definition of "production-ready"

A product is production-ready when ALL of these are true (not "the demo works"):
- [ ] Auth chain correct on every route; RLS enforced as non-owner; super-admin + jobs swept for context.
- [ ] Money in integers, centralized + tested; transactions have maxWait; idempotency via SAVEPOINT; event log for money/trust state.
- [ ] Redis rate-limit + two-tier cache; feature flags enforced at 4 layers.
- [ ] Replica-safe (socket adapter + cron leader-election) OR explicitly single-instance-by-design.
- [ ] Five test layers green for revenue/PII/ops paths; CI is the canonical shape, cloud-default, sleep-proof alerts.
- [ ] Sentry + uptime + alerting + ≥30-day logs before first customer.
- [ ] Security gates pass (XSS, injection, secrets 0/0/0/0, CSV-formula guard, consent gate, erasure endpoints).
- [ ] Snapshot + rollback rehearsed; local/staging never touch prod.
- [ ] Every meaningful table has a UI; docs at parity; i18n/RTL parity.
- [ ] Iceberg Audit run with no open Criticals.

When in doubt, run the §14 audit that covers the area of doubt and close what it finds.
