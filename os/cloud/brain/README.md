# Ebda OS brain (Cloudflare Worker)

The always-on part of Ebda OS (Amendment A). It notices, decides, queues work for the hands and reports outcomes.
It never writes code itself (that is `os/cloud/hands/`, Task 4b) and never calls GitHub Actions: Actions minutes are for CI only.

```
GitHub org webhooks ──► POST /github/webhook ──► KV (Mac fallback, GET /pending)   ┐
Mac watchers / dream ─► POST /findings ─────────────────────────────────────────────┤
cron */5  CI inbox, prod health, questions, urgent dispatch, self-check            ├─► BrainDO (SQLite)
cron */15 services, page-load, journey-monitor  ·  :07 advisories + CISA KEV, deploy-drift,│
cron 6 h  cf-workers, sentry-stale, cost-guard, world-watch, dr-drill        pr-shepherd│   findings → classify → jobs
cron 21:30 UTC  the ONE nightly hands batch                                         │   runs, questions, messages
cron 05:00 UTC  the ONE daily digest                                                ┘
BrainDO ──► HandsProvider.start(batch) ──► hands pull GET /hands/runs/:id, post outcomes + usage
BrainDO ──► Telegram (≤ 3/day + 1 digest, deduped)        dashboard /dash/ + /api/* (behind Cloudflare Access)
```

## Cloud watchers (ported from the Mac watchers, Task 4a)

Ten watchers in `src/watchers/`, run from the Worker cron (never inside the DO), entry `src/watchers/run.ts`. Each is a pure function of
`(env, sink, now, fetch)` with a 10 s timeout per request, a KV cadence gate (`wd:last:<id>`), and findings
`source: watcher` with the stable key `<watcher>:<subject>:<state>`; the classifier picks the lane and nothing messages Telegram directly.
Shared rules (`common.ts`): a var left unset skips the watcher and raises ONE deduped `monitor-unconfigured` finding (lane `digest`: recorded, listed once in the daily digest, never a hands job or a Telegram question; same for `watcher-error`, from any source); non-2xx, timeout,
unparsable JSON, `success:false` and GraphQL 200 + `errors` raise a `watcher-error` finding (never "all clear", and an unreadable source
never resolves earlier findings); a finding whose condition is gone is resolved. Tokens are env secrets (`wrangler secret put`) and never
appear in a finding. Targets are config only: set the vars below at deploy with `OS_BRAIN_<NAME>` in `~/.ebda-os.local.env` (`scripts/deploy.sh`
validates the JSON ones); the only default is `DR_DRILL_REPO`.

| Watcher (cron) | Checks | Config (vars / secrets) | Finding keys |
|---|---|---|---|
| `services` (15 min) | named Ebda services through `health.ts` `checkOne` (200 with `ok:false` is down); finding after `HEALTH_FAIL_BUDGET` consecutive fails (KV streak), urgent per classifier | `SERVICE_TARGETS` `[{name,url,kind}]` | `services:<name>:down` (`prod-outage` / `money-path-broken`) |
| `page-load` (15 min) | 3 sequential GETs per page; p50 of TTFB or total over the limit, or 2+ of 3 non-2xx | `PAGE_LOAD_TARGETS` `[{name,url}]`, `PAGE_LOAD_P50_MS` (1500) | `page-load:<name>:slow` / `:unreachable` |
| `journey-monitor` (15 min) | guest GET journeys (home, product, cart); step fails on non-2xx, timeout or missing `contains` text. Read-only by construction: checkout/payment/order/login paths are refused at parse time | `JOURNEY_CONFIG` `[{name,steps:[{name,url,contains?}]}]` | `journey-monitor:<journey>:failed`, `:config:error` |
| `deploy-drift` (hourly :07) | live `/health` commit vs tip of the branch (GitHub API); drift = differs AND tip older than the grace | `DEPLOY_DRIFT_TARGETS` `[{name,healthUrl,repo,branch?}]`, `DEPLOY_DRIFT_GRACE_MIN` (120), secret `GITHUB_TOKEN` | `deploy-drift:<name>:drifted` |
| `pr-shepherd` (hourly :07) | open PRs in `OS_ORGS` that are CONFLICTING, have a FAILURE/ERROR check rollup, or sit non-draft without update for `PR_SHEPHERD_STALE_HOURS` | `OS_ORGS`, `PR_SHEPHERD_STALE_HOURS` (24), secret `GITHUB_TOKEN` | `pr:<repo>#<n>:conflicting|failed-checks|waiting` |

pr-shepherd (ruling F-I5): a CONFLICTING or failing-checks PR on a same-repo branch that is the OS's own (`os/fix-*`, `ebda-os/*`) or bot-authored becomes a `pr-stuck` nightly job (the hands push a fix to that branch, never merge). Everything else, including every PR merely waiting over 24 h, is `pr-needs-you`: a digest note, no job, no Claude run.
| `cf-workers` (6 h) | Workers named `CF_WORKERS_PREFIXES` (default `ebda-`): error rate over 6 h above `CF_WORKER_ERROR_RATE` (0.05, min 20 requests); `CF_WORKERS_EXPECTED` Workers missing from the account. A failed Workers Builds deploy is not visible through these APIs (CI owns it) | `CF_ACCOUNT_ID`, `CF_WORKERS_*`, secret `CF_API_TOKEN` (Analytics:Read + Workers Scripts:Read) | `cf-workers:<script>:errors|missing` |
| `cost-guard` (6 h) | GitHub Actions minutes this month for `COST_GH_ORG` (warn 48000 / stop 49500) and Workers requests this month (warn 8M / stop 10M) | `COST_GH_ORG`, `COST_ACTIONS_WARN_MIN`, `COST_ACTIONS_STOP_MIN`, `CF_REQUESTS_WARN`, `CF_REQUESTS_STOP`, `CF_ACCOUNT_ID`, secrets `GITHUB_TOKEN` (org billing read), `CF_API_TOKEN` | `cost-guard:<counter>:warn|stop` |
| `sentry-stale` (6 h) | unresolved issues `age:+72h lastSeen:-24h` per project | `SENTRY_ORG`, `SENTRY_PROJECTS`, `SENTRY_BASE_URL`, secret `SENTRY_AUTH_TOKEN` | `sentry-stale:<project>/<id>:stale` |
| `world-watch` (6 h) | Statuspage incidents (impact major/critical, unresolved) for Cloudflare + GitHub; npm bulk advisories (high/critical) for the pinned runtime deps | `WORLD_STATUS_URLS` (default CF + GitHub), `WORLD_NPM_DEPS` `{"pkg":["x.y.z"]}` | `world-watch:<source>:<incident>`, `world-watch:npm/<pkg>/<id>:open` |
| `dr-drill` (6 h) | the age of the last restore-drill PASS the Mac posted to `POST /drill` (ruling F-I6, the drill needs R2 + age secrets the container must not hold; `os/ops/restore-drill.sh` runs it weekly): no PASS for `DR_DRILL_STALE_DAYS` (8) = a digest note; 14 days = ONE unhealed-P1 message. Never a hands job | `DR_DRILL_REPO` (default `Ebda-AI-Studio/ebda-store`), `DR_DRILL_STALE_DAYS` | `dr-drill:ebda-store:stale`, `dr-drill:ebda-store:overdue` |

Crons (`src/schedule.ts` = `wrangler.jsonc`): `quarter` `2-59/15 * * * *`, `sixhourly` `17 */6 * * *`; `hourly` also runs deploy-drift and pr-shepherd.
Footprint: at most 3 outbound requests per service per 15 min and a few dozen per 6 h; KV writes are one gate key per watcher run; no new paid service.

## Config gaps and refusals (final review fixes)

- A finding with no `repo`, or a repo missing from `HANDS_CONFIG_JSON`, never becomes a hands job: urgent class sends ONE `p1-unhealed` message, everything else lands in the digest. Put `repo` (owner/name) on `HEALTH_TARGETS` / `SERVICE_TARGETS` entries so an outage can reach the hands.
- A URL belongs in `HEALTH_TARGETS` or `SERVICE_TARGETS`, never both (two sources = two fingerprints = two urgent runs).
- With a real provider (not `stub`) an urgent container never boots on unknown usage; a P1 the hands refuse on usage (they now report the reading) sends one `p1-unhealed` message and stays queued for tonight (ruling F-C1).
- A run that outlives its cap (+10 min) is timed out: urgent reports could-not-fix; nightly / Mac-claim jobs are requeued once, then end `timed_out`; the digest counts the requeues.
- `mac-local` claims skip third-party-text jobs (advisories, `pr-stuck`, world-watch): ruling 4b-5, enforced in `claim()`.
- `GET /api/state` lists `unconfigured` watcher ids; `os/ops/cutover-gate-check.sh --deployed <url>` fails while a ported watcher is unconfigured.

## Design

| Piece | Where | Notes |
|---|---|---|
| Relay | `src/relay.ts`, `src/index.ts` | Ported unchanged: `X-Hub-Signature-256` check, `workflow_run` failure → `{kind:'ci-failure', target:{slug,sha}}`, signed with `RELAY_SECRET` (HMAC parity vector pinned in `test/relay.test.ts`), queued in KV for the Mac's `GET /pending`. The brain also keeps the event in its own inbox. |
| CI watcher | `BrainDO.processCiEvents` | Reads the webhook inbox, not the GitHub API. Default-branch failures only; one finding per repo + workflow while it stays red. A green default-branch run resolves it. |
| Health watcher | `src/watchers/health.ts` | `HEALTH_TARGETS` (api / page / money); defaults are the two live endpoints `https://api.ebda.app/health` and `https://ebda.app/` (both 200 on 2026-11-05), replaced with `OS_BRAIN_HEALTH_TARGETS` at deploy. Runs in the Worker so the DO never waits on the network. A target down `HEALTH_FAIL_BUDGET` (3) checks in a row = P1 (the brain uses the streak as the proxy for "self-heal window spent"; it does not see the Mac recipes). The start of the failure streak is the incident id: one streak = one incident = one urgent run. Recovery resolves it. |
| Advisory watcher | `src/watchers/advisories.ts`, `src/githost.ts` | Open Dependabot alerts per org through the `GitHost` interface (GitHub today), `If-None-Match` (a 304 costs no rate limit), at most hourly. CISA KEV feed refreshed at most daily, cached in KV. A complete listing resolves alerts that disappeared. `deployed` is true only for repos in `DEPLOYED_REPOS` (`OS_BRAIN_DEPLOYED_REPOS`); elsewhere a critical alert waits for the nightly batch. |
| Classifier | `src/classify.ts` | `classifyFinding(f) → {lane, reason, mergePolicy}`. Urgent strictly per Amendment A.1 (outage/money path after self-heal; deployed CVSS ≥ 9.0 or KEV; data exposure). Destructive/irreversible and money/auth/deletion/deploy-config/prod-data → question. Pre-approved classes (dep/CVE bump, docs, tests, lint, flaky) → nightly + auto-merge when the gate is green; everything else → nightly + PR + one question. |
| Pipeline | `src/brain-do.ts` | Dedupe by fingerprint `sha256(source|kind|key)`. Re-sighting rules: in flight (open, queued, question, dispatched, `waiting` = fix PR open) only updates `last_seen` and may PROMOTE the lane to urgent (e.g. a CVE newly KEV-listed) while the job is not handed out, never demote; `held` is never reopened by a re-sighting; `done` / `failed` / `resolved` reopen (same row, new job) only after a cool-down (24 h, 6 h for the urgent class) AND when the evidence (score, KEV, scope, failing sha, outage streak) changed. Urgent: 1 job per run, 1 run at a time, `URGENT_RUNS_PER_DAY` (3), `URGENT_RUN_CAP_MIN` (30); over the cap or usage guard → queued for tonight + one message. Nightly: one batch at 21:30 UTC (23:30 Cairo in winter, 00:30 in Egyptian summer time), up to 25 jobs; empty queue starts nothing. |
| Telegram | `src/telegram.ts` | Hard daily ceiling: `MESSAGE_BUDGET_PER_DAY` (3) normal messages (questions) + `URGENT_MESSAGE_BUDGET_PER_DAY` (3) urgent-class messages (urgent outcomes, unhealed P1, one per incident) = at most 6, plus one digest. Same dedupe key never twice; overflow rolls into the digest. A failed urgent-class send is retried by the DO alarm (tries at t, +5, +15 min), then rolls into the digest marked "delivery failed". Plain text only. |
| Questions | `BrainDO.flushQuestions/answerQuestion` | Options `proceed / hold`, default, deadline (`QUESTION_DEADLINE_HOURS`, 24). Reversible (a PR) → silence = default `proceed` after the deadline. Destructive → default `hold` and nothing ever happens on silence. Answers: Telegram buttons (`/telegram/webhook`) or the dashboard. |
| Metrics | `BrainDO.actedOn/selfCheck` | acted = dispatched to the hands, asked as a question, or resolved. Acted-on ratio = acted / raised (24 h and 7 d). A finding unacted 24 h after it was raised is an OS bug: counted on the dashboard and in the digest, never its own message. |
| Usage guard | `src/usage.ts` | The hands report `POST /hands/usage {weeklyUsedPct, resetsAt?}` after each job. The brain refuses to start any run (urgent, nightly, Mac claim) when the last report is ≥ `USAGE_WEEKLY_THRESHOLD_PCT` (80) and not past `resetsAt`. No report / report older than 7 days → allowed and labelled `usage-unknown`. usage-unknown starts a run; the hands then refuse every job on unknown or over-threshold usage before any work (`os/cloud/hands/lib/usage-guard.mjs`, tested), so unknown is never unguarded. |
| Usage-starved alert | `BrainDO.noteNightly` | Ruling 4b-6. A nightly batch is starved when the usage guard refuses to start it, or when it starts and every job comes back `skipped_usage`. After `USAGE_STARVED_ALERT_AFTER` (3) starved batches in a row, and every multiple after, one urgent-class message (`usage-starved`: Ebda OS: the last N nightly batches did no work). Any batch with a non-skipped outcome resets the streak. Queue empty or a pull-only provider is not a skip. |
| Dashboard | `public/dash/`, `GET /api/state` | Static assets (en + ar, RTL by logical properties, night + gold `#B08D57`, no orange), CSP via `public/_headers`. `/api/*` verifies the Access JWT itself (RS256, aud, iss, exp) and fails closed (503) until Access is configured. |

### Contract for the hands (Task 4b)

`src/hands.ts` is the whole interface: `HandsProvider { name; start(batch: HandsBatch): Promise<RunRef> }`,
`HandsBatch { runId, kind, jobs: HandsJob[], perJobCapMin, usageThresholdPct, createdAt }`,
`JobOutcome { status: merged|pr_opened|fix_deployed|could_not_fix|skipped_usage|timed_out, prUrl?, note? }`.
4a shipped `StubHandsProvider` (records only); 4b (`os/cloud/hands/`) wires `providerFor(HANDS_PROVIDER, env)` to the
real providers in `os/cloud/hands/providers/`: `cloudflare-sandbox` (the `HandsContainer` DO in `src/hands-container.ts`,
one container per lane, capped), `mac-local` (pull-only: the brain starts nothing, the Mac claims), `github-actions`
(refused unless explicitly enabled; Actions minutes are CI only). The committed value stays `stub` until Task 7.
A provider that throws is recorded as a `failed` run, its jobs stay queued, and the tick goes on. A nightly
`pr_opened` outcome whose note starts with `question:` (a PR the hands may not merge) sends ONE review question. A run pulls its batch with `GET /hands/runs/:runId`, reports each job with
`POST /hands/jobs/:jobId/outcome`, reports usage with `POST /hands/usage`; the Mac claims queued nightly work itself with
`POST /hands/claim {provider:'mac-local', max}`. All with `Authorization: Bearer $HANDS_TOKEN`. `skipped_usage` puts the
job back in the queue. A merge happens only if `mergePolicy === 'auto-when-gate-green'` and the repo's merge gate is green.

Mac watchers, the dreaming cycle and self-heal recipes report with `POST /findings` (one finding or an array ≤ 100,
`Authorization: Bearer $INGEST_TOKEN`), shape `src/findings.ts` (`source, kind, key, title` required).

## Frugality (Workers Paid, $5/month included limits)

Estimates for a normal day (inferred from the schedule, not measured):

| Resource | Per day | Per month | Included |
|---|---|---|---|
| Worker invocations (crons 314 + webhooks ~300 + hands/dashboard ~100) | ~700 | ~21 k | 10 M requests |
| Worker CPU (2–10 ms each) | ~5 s | ~150 s | 30 M ms |
| Durable Object requests (3 RPCs per tick + webhooks + hourly + hands) | ~1.1 k | ~35 k | 1 M |
| DO duration (~50 ms wall per call, 128 MB) | ~7 GB-s | ~210 GB-s | 400 k GB-s |
| SQLite rows written / storage | < 5 k / < 1 MB | < 150 k | 50 M rows, 5 GB |
| KV writes / reads | ~100 / ~200 | ~3 k / ~6 k | 1 M / 10 M |
| Outbound: health checks / GitHub API (mostly 304) / KEV | 576 / ≤ 48 / 1 | | free |
| Telegram messages | ≤ 6 (3 normal + 3 urgent) + 1 digest; ≤ 3 on a normal day | | |
| Hands runs | 1 nightly + ≤ 3 urgent | | container estimate in `os/cloud/hands/README.md` (memory-bound, ~$0.55/month typical) |
| GitHub Actions minutes used by the OS | 0 | 0 | |

Frugal rules in code: non-`completed` webhook deliveries return before any storage call; health fetches stay out of the
DO; advisories at most hourly with ETag, KEV at most daily; an empty nightly queue starts nothing.

## Develop

```bash
cd os/cloud/brain
npm ci
npm test            # vitest on workerd (@cloudflare/vitest-plugin), real DO + KV bindings
npm run typecheck
bash scripts/deploy.sh --dry-run    # renders wrangler.deploy.jsonc and builds; uploads nothing
```

CI: job `brain` in `.github/workflows/ci.yml` (only when `os/cloud/**` changes on a PR; always on main).

## Runbook: first deploy (controller, Task 7; nothing here has been run)

All on the **personal** Cloudflare account. Never put an id or secret in the repo.

1. Per-machine config in `~/.ebda-os.local.env`:
   ```bash
   OS_CF_ACCOUNT_ID=<personal account id>
   OS_BRAIN_HOST=<hostname on a zone in that account, e.g. os.<your-domain>>
   OS_BRAIN_DEPLOYED_REPOS="<owner/name> <owner/name>"   # repos whose code is deployed; advisories are urgent only there
   ```
2. KV namespace, then record its id:
   ```bash
   cd os/cloud/brain && npm ci
   CLOUDFLARE_ACCOUNT_ID=$OS_CF_ACCOUNT_ID npx wrangler kv namespace create ebda-os-brain-events
   echo 'OS_BRAIN_KV_ID=<id printed above>' >> ~/.ebda-os.local.env
   ```
3. Deploy (creates the Worker, the SQLite DO via migration `v1`, the custom domain and the 6 crons):
   ```bash
   bash scripts/deploy.sh --dry-run && bash scripts/deploy.sh
   curl -s https://$OS_BRAIN_HOST/health        # {"ok":true,"service":"ebda-os-brain"}
   ```
4. Secrets (each prompts for the value; generate random ones with `openssl rand -hex 32`):
   ```bash
   for s in GH_WEBHOOK_SECRET RELAY_SECRET HANDS_TOKEN INGEST_TOKEN TELEGRAM_WEBHOOK_SECRET TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID GITHUB_TOKEN; do
     CLOUDFLARE_ACCOUNT_ID=$OS_CF_ACCOUNT_ID npx wrangler secret put "$s" --config wrangler.deploy.jsonc
   done
   ```
   - `RELAY_SECRET` must equal the Mac listener's relay secret (in `OS_SERVICES_ENV`). Leave it unset to run brain-only (no `/pending` copy).
   - `GITHUB_TOKEN`: fine-grained PAT per org (resource owner = the org), read-only **Dependabot alerts**. Until set, the advisory watcher records `GITHUB_TOKEN secret unset` and does nothing.
   - `TELEGRAM_BOT_TOKEN`: use a **separate bot** for the brain. Setting a webhook on a bot that something else polls with `getUpdates` breaks that poller.
5. GitHub org webhooks (one per org in `OS_ORGS` minus the personal account, which has no org webhooks):
   `gh api orgs/<org>/hooks -f name=web -F active=true -f 'events[]=workflow_run' -f config[url]=https://$OS_BRAIN_HOST/github/webhook -f config[content_type]=json -f config[secret]=<GH_WEBHOOK_SECRET>`
   (needs `admin:org_hook`; only `workflow_run`). Check: the hook's ping returns 204 in the org's webhook deliveries.
6. Telegram answers (optional; the dashboard can answer too):
   `curl -s "https://api.telegram.org/bot<token>/setWebhook" -d url=https://$OS_BRAIN_HOST/telegram/webhook -d secret_token=<TELEGRAM_WEBHOOK_SECRET> -d 'allowed_updates=["callback_query"]'`
7. Cloudflare Access (Zero Trust → Access → Applications, self-hosted), two path-scoped applications on `$OS_BRAIN_HOST`:
   `/dash` and `/api`, policy = Ahmad's email only. Do **not** cover `/github`, `/telegram`, `/hands`, `/findings`,
   `/pending`, `/health` (machines authenticate with their own secrets). Then add the team domain + the application AUD
   tag to `~/.ebda-os.local.env` as `OS_BRAIN_ACCESS_TEAM_DOMAIN=<team>.cloudflareaccess.com` and `OS_BRAIN_ACCESS_AUD=<aud>`
   and redeploy (step 3). Until then `/api/*` answers 503.
8. Verify against production: `/health` 200; a webhook redelivery from the org settings → 204; `GET /pending` with the
   relay secret returns `[]` or events; dashboard loads through Access; after the first `:07` the dashboard shows the
   advisory run per org; the first digest arrives at 05:00 UTC.

Rollback: `npx wrangler rollback --config wrangler.deploy.jsonc` (code); disable the org webhooks to stop the inbox.
