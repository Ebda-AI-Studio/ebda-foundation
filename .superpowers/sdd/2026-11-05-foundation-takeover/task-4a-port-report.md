# Task 4a port report - 10 PORT-BRAIN watchers in the brain

Status: DONE_WITH_CONCERNS. Files: os/cloud/brain/src/watchers/{common,run,services,page-load,journey-monitor,deploy-drift,pr-shepherd,cf-workers,cost-guard,sentry-stale,world-watch,dr-drill}.ts, test/cloud-watchers.test.ts, README section "Cloud watchers" (per-watcher config, cadence, flags).

## What each checks (cadence, finding keys) - full table in the brain README
- services (15 min): SERVICE_TARGETS via health.ts checkOne; finding after HEALTH_FAIL_BUDGET consecutive fails (KV streak); prod-outage / money-path-broken; key services:<name>:down.
- page-load (15 min): 3 sequential GETs, p50 TTFB or total > PAGE_LOAD_P50_MS (1500) -> page-load:<name>:slow; 2+/3 non-2xx -> :unreachable.
- journey-monitor (15 min): JOURNEY_CONFIG GET-only steps (home -> product -> cart), optional `contains`. Checkout/payment/order/login paths refused at parse time (journey dropped + config watcher-error).
- deploy-drift (hourly): /health commit vs GitHub tip; drift when different AND tip older than DEPLOY_DRIFT_GRACE_MIN (120). Stateless (commit date).
- pr-shepherd (hourly): GraphQL search per OS_ORGS org; conflicting / failed-checks / waiting >24 h (non-draft); keys pr:<repo>#<n>:<state>.
- cf-workers (6 h): CF REST script list + GraphQL invocations; error rate > 5% (min 20 req) on Workers with prefix ebda-; CF_WORKERS_EXPECTED missing.
- cost-guard (6 h): org Actions minutes (billing usage API) warn 48000 / stop 49500; CF Workers requests month-to-date warn 8M / stop 10M.
- sentry-stale (6 h): `is:unresolved age:+72h lastSeen:-24h` per project.
- world-watch (6 h): Statuspage (Cloudflare, GitHub; major/critical unresolved) + npm bulk advisories (high/critical) for WORLD_NPM_DEPS.
- dr-drill (6 h tick, weekly enqueue): one nightly finding "run restore drill (node scripts/ops/restore-drill.mjs --target api) on ebda-store"; stale finding when no drill job completed for 8 days (new BrainDO.lastDoneAt).

## Wiring
- schedule.ts + wrangler.jsonc: two new crons `quarter` (2-59/15 * * * *) and `sixhourly` (17 */6 * * *); hourly also runs deploy-drift + pr-shepherd. Per-watcher KV cadence gate `wd:last:<id>`.
- env.ts: all vars optional; new secrets CF_API_TOKEN, SENTRY_AUTH_TOKEN (GITHUB_TOKEN reused). Declared as secrets only in the wrangler comment, no values.
- deploy.sh: OS_BRAIN_<NAME> -> vars passthrough (JSON ones validated). Dry run verified with three vars set.
- Shared rules in common.ts: unconfigured -> one deduped monitor-unconfigured; non-2xx/timeout/non-JSON/success:false/GraphQL errors -> watcher-error; unreadable source never resolves earlier findings.

## Tests
`npx vitest run`: 10 files, 178 tests green (50 new in cloud-watchers.test.ts: per watcher failing, healthy, unconfigured, API-error; runner isolation/cadence; real DO). `npx tsc --noEmit` clean.

## cutover-gate-check.sh
`cutover-gate: clear`, exit 0 (all 10 PORT-BRAIN blockers gone; no KEEP-MAC/other blockers remain at this commit).

## Concerns
1. Every watcher starts unconfigured on deploy until Ahmad sets the OS_BRAIN_* vars and the CF_API_TOKEN / SENTRY_AUTH_TOKEN secrets: expect 8 monitor-unconfigured findings (nightly lane, "code change" -> hands job each) on first run. Acceptable per brief but noisy; could be given its own classifier lane later.
2. cf-workers cannot see a failed Workers Builds deploy (not in these APIs); only errors/missing. CI watcher owns deploy failure.
3. cost-guard GitHub billing endpoint (/organizations/{org}/settings/billing/usage) shape and token scope were written from the API docs, not exercised live; Cloudflare GraphQL dataset workersInvocationsAdaptive likewise. NOT VERIFIED against production; first live tick will show a watcher-error if the shape differs.
4. page-load/services run in the Worker (single colo), not from the user's region.
5. Services probes duplicate the two HEALTH_TARGETS if the same URLs are configured in both (separate finding sources, so two findings); configure services with the extra services only.

## Fix round 1
1. classify.ts: source `watcher` + kind `monitor-unconfigured` / `watcher-error` returns lane `question` (early return), never nightly/urgent, so no hands job; deduped by fingerprint. Scoped to source `watcher` because the dreaming cycle emits its own `monitor-unconfigured` (existing classify.test expects nightly for source `dream`). Tests: both kinds with severity/selfHealExhausted variants, real-DO test (no queued jobs, dedupe), dream-source keeps nightly. Note: the lane is `question`, so each costs one Telegram question within the daily budget (overflow rolls into the digest); there is no separate digest-only lane.
2. dr-drill freshness counts only outcomes with `drill:'pass'`: JobOutcome.drill, `/hands/jobs/:id/outcome` passes it through, BrainDO.lastPassAt (json_extract), hands `lib/run.mjs` sets it for dr-drill jobs (PASS in the note, no FAIL, status merged/pr_opened/fix_deployed). Test: done without marker and done+fail stay stale, pass counts.
3. dr-drill key is the ISO week (`dr-drill:ebda-store:2026-W45`, boundary tests for W53/W01); the weekly KV gate is written only after `ingestMany` returns. Tests: gate closes after success, ingest throw leaves gate null and the next run retries.
4. journey-monitor forbids whole path segments (`/cart/checkout`, `/payment/x`, `/orders`, `/login` refused; `/products/order-box` allowed); undecodable path refused; a redirect landing on a forbidden path fails the step.
Verification: brain vitest 186/186, hands vitest 65/65, tsc clean, cutover-gate-check clear.
