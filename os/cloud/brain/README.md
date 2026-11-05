# Ebda OS brain (Cloudflare Worker)

The always-on part of Ebda OS (Amendment A). It notices, decides, queues work for the hands and reports outcomes.
It never writes code itself (that is `os/cloud/hands/`, Task 4b) and never calls GitHub Actions: Actions minutes are for CI only.

```
GitHub org webhooks ──► POST /github/webhook ──► KV (Mac fallback, GET /pending)   ┐
Mac watchers / dream ─► POST /findings ─────────────────────────────────────────────┤
cron */5  CI inbox, prod health, questions, urgent dispatch, self-check            ├─► BrainDO (SQLite)
cron :07  dependency/CVE advisories (ETag) + CISA KEV (daily)                      │   findings → classify → jobs
cron 21:30 UTC  the ONE nightly hands batch                                         │   runs, questions, messages
cron 05:00 UTC  the ONE daily digest                                                ┘
BrainDO ──► HandsProvider.start(batch) ──► hands pull GET /hands/runs/:id, post outcomes + usage
BrainDO ──► Telegram (≤ 3/day + 1 digest, deduped)        dashboard /dash/ + /api/* (behind Cloudflare Access)
```

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
| Usage guard | `src/usage.ts` | The hands report `POST /hands/usage {weeklyUsedPct, resetsAt?}` after each job. The brain refuses to start any run (urgent, nightly, Mac claim) when the last report is ≥ `USAGE_WEEKLY_THRESHOLD_PCT` (80) and not past `resetsAt`. No report / report older than 7 days → allowed and labelled `usage-unknown`. usage-unknown is allowed only while the hands provider is the stub; registering a real provider (4b) comes with the hands enforcing the threshold between jobs. |
| Dashboard | `public/dash/`, `GET /api/state` | Static assets (en + ar, RTL by logical properties, night + gold `#B08D57`, no orange), CSP via `public/_headers`. `/api/*` verifies the Access JWT itself (RS256, aud, iss, exp) and fails closed (503) until Access is configured. |

### Contract for the hands (Task 4b)

`src/hands.ts` is the whole interface: `HandsProvider { name; start(batch: HandsBatch): Promise<RunRef> }`,
`HandsBatch { runId, kind, jobs: HandsJob[], perJobCapMin, usageThresholdPct, createdAt }`,
`JobOutcome { status: merged|pr_opened|fix_deployed|could_not_fix|skipped_usage|timed_out, prUrl?, note? }`.
4a ships `StubHandsProvider` (records only); 4b registers `cloudflare-sandbox` and `mac-local` in `providerFor()` and
switches `HANDS_PROVIDER`. A run pulls its batch with `GET /hands/runs/:runId`, reports each job with
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
| Hands runs | 1 nightly + ≤ 3 urgent | | (4b: container minutes) |
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
3. Deploy (creates the Worker, the SQLite DO via migration `v1`, the custom domain and the 4 crons):
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
