# Ebda OS brain (Cloudflare Worker)

The always-on part of Ebda OS (Amendment A). It notices, decides, queues work for the hands and reports outcomes.
It never writes code itself (that is `os/cloud/hands/`, Task 4b) and never calls GitHub Actions: Actions minutes are for CI only.

```
GitHub org webhooks ──► POST /github/webhook ──► KV (Mac fallback, GET /pending)   ┐
Mac watchers / dream ─► POST /findings ─────────────────────────────────────────────┤
cron */5  CI inbox, prod health, questions, urgent dispatch, self-check            ├─► BrainDO (SQLite)
cron */15 services (page-load + journey-monitor now gated to hourly)  ·  :07 advisories + CISA KEV, deploy-drift,│
cron 6 h  cf-workers, sentry-stale, cost-guard, world-watch, dr-drill        pr-shepherd│   findings → classify → jobs
cron 21:30 UTC  the ONE nightly hands batch                                         │   runs, questions, messages
cron 05:00 UTC  the ONE daily digest                                                ┘
BrainDO ──► HandsProvider.start(batch) ──► hands pull GET /hands/runs/:id, post outcomes + usage
BrainDO ──► Telegram (≤ 3/day + 1 digest, deduped)        dashboard /dash/ + /api/* (owner only: Access, else Basic Auth)
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
| `page-load` (hourly) | 3 sequential GETs per page; p50 of TTFB or total over the limit, or 2+ of 3 non-2xx | `PAGE_LOAD_TARGETS` `[{name,url}]`, `PAGE_LOAD_P50_MS` (1500) | `page-load:<name>:slow` / `:unreachable` |
| `journey-monitor` (hourly) | guest GET journeys (home, product, cart); step fails on non-2xx, timeout or missing `contains` text. Read-only by construction: checkout/payment/order/login paths are refused at parse time | `JOURNEY_CONFIG` `[{name,steps:[{name,url,contains?}]}]` | `journey-monitor:<journey>:failed`, `:config:error` |
| `deploy-drift` (hourly :07) | live `/health` commit vs tip of the branch (GitHub API); drift = differs AND tip older than the grace | `DEPLOY_DRIFT_TARGETS` `[{name,healthUrl,repo,branch?}]`, `DEPLOY_DRIFT_GRACE_MIN` (120), secret `GITHUB_TOKEN` | `deploy-drift:<name>:drifted` |
| `pr-shepherd` (hourly :07) | open PRs in `OS_ORGS` that are CONFLICTING, have a FAILURE/ERROR check rollup, or sit non-draft without update for `PR_SHEPHERD_STALE_HOURS` | `OS_ORGS`, `PR_SHEPHERD_STALE_HOURS` (24), secret `GITHUB_TOKEN` | `pr:<repo>#<n>:conflicting|failed-checks|waiting` |

pr-shepherd (ruling F-I5): a CONFLICTING or failing-checks PR on a same-repo branch that is the OS's own (`os/fix-*`, `ebda-os/*`) or bot-authored becomes a `pr-stuck` nightly job (the hands push a fix to that branch, never merge). Everything else, including every PR merely waiting over 24 h, is `pr-needs-you`: a digest note, no job, no Claude run.
| `cf-workers` (6 h) | Workers named `CF_WORKERS_PREFIXES` (default `ebda-`): error rate over 6 h above `CF_WORKER_ERROR_RATE` (0.05, min 20 requests); `CF_WORKERS_EXPECTED` Workers missing from the account. A failed Workers Builds deploy is not visible through these APIs (CI owns it) | `CF_ACCOUNT_ID`, `CF_WORKERS_*`, secret `CF_API_TOKEN` (Analytics:Read + Workers Scripts:Read) | `cf-workers:<script>:errors|missing` |
| `cost-guard` (6 h) | GitHub Actions minutes this month for `COST_GH_ORG` (warn 48000 / stop 49500) and Workers requests this month (warn 8M / stop 10M) | `COST_GH_ORG`, `COST_ACTIONS_WARN_MIN`, `COST_ACTIONS_STOP_MIN`, `CF_REQUESTS_WARN`, `CF_REQUESTS_STOP`, `CF_ACCOUNT_ID`, secrets `GITHUB_TOKEN` (org billing read), `CF_API_TOKEN` | `cost-guard:<counter>:warn|stop` |
| `sentry-stale` (6 h) | unresolved issues `age:+72h lastSeen:-24h` per project | `SENTRY_ORG`, `SENTRY_PROJECTS`, `SENTRY_BASE_URL`, secret `SENTRY_AUTH_TOKEN` | `sentry-stale:<project>/<id>:stale` |
| `world-watch` (6 h) | Statuspage incidents (impact major/critical, unresolved) for Cloudflare + GitHub; npm bulk advisories (high/critical) for the pinned runtime deps | `WORLD_STATUS_URLS` (default CF + GitHub), `WORLD_NPM_DEPS` `{"pkg":["x.y.z"]}` | `world-watch:<source>:<incident>`, `world-watch:npm/<pkg>/<id>:open` |
| `ci-catchup` (hourly) | the newest COMPLETED run per workflow on each hands-mapped repo's default branch (last 48 h), replayed through the webhook's two doors: red -> `ingestCiEvent`, green -> `resolveCi`, both deduped by run id + attempt. Covers a brain outage longer than the webhook's 1 h replay window | `HANDS_CONFIG_JSON` repos, secret `GITHUB_TOKEN` | the existing `ci-failure` keys (`<repo>:<workflow>`) |
| `dr-drill` (6 h) | the age of the last restore-drill PASS the Mac posted to `POST /drill` (ruling F-I6, the drill needs R2 + age secrets the container must not hold; `os/ops/restore-drill.sh` runs it weekly): no PASS for `DR_DRILL_STALE_DAYS` (8) = a digest note; 14 days = ONE unhealed-P1 message. Never a hands job | `DR_DRILL_REPO` (default `Ebda-AI-Studio/ebda-store`), `DR_DRILL_STALE_DAYS` | `dr-drill:ebda-store:stale`, `dr-drill:ebda-store:overdue` |

Crons (`src/schedule.ts` = `wrangler.jsonc`): `quarter` `2-59/15 * * * *`, `sixhourly` `17 */6 * * *`; `hourly` also runs deploy-drift, pr-shepherd and ci-catchup.
Footprint: at most 3 outbound requests per service per 15 min and a few dozen per 6 h; KV writes are one gate key per watcher run; no new paid service.

## Config gaps and refusals (final review fixes)

- A finding with no `repo`, or a repo missing from `HANDS_CONFIG_JSON`, never becomes a hands job: urgent class sends ONE `p1-unhealed` message, everything else lands in the digest. Put `repo` (owner/name) on `HEALTH_TARGETS` / `SERVICE_TARGETS` entries so an outage can reach the hands.
- A URL belongs in `HEALTH_TARGETS` or `SERVICE_TARGETS`, never both (two sources = two fingerprints = two urgent runs).
- With a real provider (not `stub`) an urgent container never boots on unknown usage; a P1 the hands refuse on usage (they now report the reading) sends one `p1-unhealed` message and stays queued for tonight (ruling F-C1).
- A run that outlives its cap (+10 min) is timed out: urgent reports could-not-fix; nightly / Mac-claim jobs are requeued once, then end `timed_out`; the digest counts the requeues.
- `mac-local` claims skip third-party-text jobs (advisories, `pr-stuck`, world-watch): ruling 4b-5, enforced in `claim()`.
- A watcher that runs WITHOUT a config gap resolves its own `<id>:config:unconfigured` note (N-1), so `--deployed` clears once the watcher is really configured; a gap that comes back reopens at once (no cool-down).
- The stuck-run cap is fixed at claim time (N-2): a container run is swept at min(45 min x jobs claimed, `HANDS_NIGHTLY_RUN_CAP_MIN`) + 10 min (so jobs the dying container never reached requeue the same night); a Mac claim at max(cap, 45 min x jobs claimed) + 10 min.
- Unknown usage (no report yet) with a real provider starts ONE job per nightly run / Mac claim, the bootstrap that produces the first report; urgent still refuses (RR-unknown-usage). `usage-starved` is a digest item, not a message (RR-usage-starved-digest). `timed_out` counts as a failed CI run on both the webhook and `ci-catchup`.
- A replayed green is ignored by its signed run id + attempt (`ci:green:seen`), so it cannot close a newer red (M-3).
- `POST /hands/refused {runId, reason}` (hands token): the container could not lock down egress and exits 3; the brain sends ONE P1 message a day, marks the run failed and requeues its jobs.
- `GET /api/state` lists `unconfigured` watcher ids; `os/ops/cutover-gate-check.sh --deployed <url>` fails while a ported watcher is unconfigured.

## Telegram: the brain owns the bot (RR-tg-brain-owns)
Code `src/tg-inbox.ts`, tests `test/tg-inbox.test.ts` + `test/send-only.test.ts`. Telegram allows ONE consumer per bot; it is the brain's webhook. The old tg-relay session (a Claude session polling `getUpdates`, only forwarding text, never button taps) is **RETIRED**.

| Piece | Where | Rule |
|---|---|---|
| Register | `POST /api/telegram/webhook/set` (Bearer `INGEST_TOKEN`) | `setWebhook(url=https://os.ebda.app/telegram/webhook, secret_token=TELEGRAM_WEBHOOK_SECRET, allowed_updates=[message, callback_query], drop_pending_updates=false)`. Output never contains the bot token or the secret. |
| Inspect | `GET /api/telegram/webhook/info` | `getWebhookInfo`, token redacted. |
| Rollback | `POST /api/telegram/webhook/delete` | `deleteWebhook(drop_pending_updates=false)`; then restart the relay if you want the old path back. |
| Tap / reply | `POST /telegram/webhook` | unchanged: secret header + chat + owner checks; a reply to a decision message is its note. |
| Inbox in | same webhook | an owner `message` (text, or a file with optional caption) in `TELEGRAM_CHAT_ID` that is not a decision reply -> KV `inbox:<ms of message.date, 13 digits>:<update_id>` `{text, at, message_id, update_id, file?{kind,file_id,name,mime,size}}`, 30-day TTL; a Telegram retry stores once. Replies "Got it" (silent) unless `TELEGRAM_INBOX_ACK=0`. Foreign chats and users are ignored. |
| Inbox read | `GET /api/inbox?since=<ms>` (Bearer `INGEST_TOKEN`) | unread items newer than `since`, oldest first, at most 100. |
| Inbox ack | `POST /api/inbox/ack` `{ids:[<=100 keys]}` | marks read; idempotent; `{acked, missing}`. |
| Send | `POST /api/telegram/send` (Bearer `INGEST_TOKEN`) | `{text <=4000, document_url (https, public host) | document_base64 (<=10 MB decoded), filename?}`; text is the caption when <=1024 chars, else a separate message first. Over-size 413. |
| Mac helpers | `os/ops/brain-inbox.sh list\|ack\|wait`, `os/ops/brain-send.sh text\|file` | token from `$OS_SERVICES_ENV` like `lib/brain-post.sh`, never printed (0600 curl config); host resolved with `dig @8.8.8.8` + `curl --resolve`. `wait` polls every 20 s up to N min and exits 0 on a new item: run it as a background task to be woken. |

No new secret or binding (`TELEGRAM_INBOX_ACK` is an optional var). Cost: free Telegram, a few KV ops per message. The tg-relay files (`~/.claude/channels/telegram/relay/RELAY.md`, the `tgrelay` screen) are left in place; remove them once the webhook is confirmed.

## InstaPay bridge (auto-confirm digest + one-tap "not received")
Code `src/instapay-bridge.ts`, tests `test/instapay-bridge.test.ts`; shared codec/signature in `packages/foundation/src/instapay-digest.ts`. Same Telegram door as decisions (no new consumer); rulings INSTAPAY-6 and INSTAPAY-7 in `docs/RULINGS.md`.

| Piece | Where | Rule |
|---|---|---|
| Notify | `POST /api/instapay/notify` | headers `X-Bridge-Product: store\|chat`, `X-Bridge-Ts` (epoch ms, +-5 min), `X-Bridge-Sig` = HMAC-SHA256 hex over `notify.<ts>.<raw body>` (the revert call the other way uses the label `revert`, so one secret never signs both directions) with `INSTAPAY_BRIDGE_SECRET_STORE\|CHAT`; checked before parsing (401), single-use (409 on replay), 503 when that product's secret is unset. Body `{kind:'digest', items:[{product,id,ownerLabel,amountMinor,kind,confirmedAt}]}` (<= 200; empty -> `{sent:false,empty:true}`, nothing sent) or `{kind:'waiting', items:[... + reasons[]]}` (1-5). `item.product` must equal the signing product. |
| Caps | KV `EVENTS` | 1 digest per product per UTC day (429), 20 waiting messages per product per hour (429); a failed Telegram send releases the claim (502, the product retries). Does not use `admit()` or the OS message budget. |
| Digest message | `sendMessage` (plain text, no parse mode) | one message, one button row per item (`Not received: EGP 1,200.50 <shop>`, callback `ip:<s\|c>:<id>`), paged: 20 buttons per message, every payment gets a button, all pages sent in order (a failure on any page releases the day claim and returns 502 so the product retries the whole digest). Waiting messages carry the reason codes and no buttons. |
| Tap | `POST /telegram/webhook` (owner + chat checks as for decisions) | `ip:<s\|c>:<id>` -> `POST INSTAPAY_REVERT_URL_STORE\|CHAT` (https only, 8 s timeout) with `{id, actor:'telegram-owner', tappedAt}` signed the same way with the `revert` label. Answer text: `reverted`, `already reverted`, `refused: <code>` (401/404/409), `product unreachable, try again` (5xx or network; nothing is kept, the tap is retryable), `refused: bridge not configured`. Audit key `instapay:tap:<product>:<id>:<ms>` (180 d). |
| Secrets | Worker secrets | `INSTAPAY_BRIDGE_SECRET_STORE`, `INSTAPAY_BRIDGE_SECRET_CHAT` (>= 16 chars, one per product), `INSTAPAY_REVERT_URL_STORE`, `INSTAPAY_REVERT_URL_CHAT` (set with `wrangler secret put` after the products ship their endpoints; unset = that product's calls are refused, never passed). |

## Decisions (one-tap approvals in Telegram)
Code `src/decisions.ts`, tests `test/decisions.test.ts`. The controller POSTs approval questions; Ahmad answers with one tap; the controller reads the answers.

| Piece | Where | Rule |
|---|---|---|
| Ask | `POST /api/decisions` (Bearer `INGEST_TOKEN`) | body `[{id, question, why, default, cost_if_wrong, kind, link?}]`, at most 10, one Telegram message each at ~1/s. `yes_no` -> Yes / No / Later; any other kind -> Done / Later (+ an Open URL button for `link`). Deduped by `id`: a pending or answered id is never resent. Response `{sent, duplicate, failed}` (a failed send leaves no record, so a retry resends). |
| Read | `GET /api/decisions?status=answered\|pending` (Bearer `INGEST_TOKEN`) | records `{id, question, why, default, cost_if_wrong, kind, link?, status, createdAt, messageId, answer?, at?, by?, note?}`; answer is `yes / no / later / done` |
| Tap | `POST /telegram/webhook` (same door as questions and social) | callback `d:<id>:<y\|n\|l\|k>`; accepted only with the correct `X-Telegram-Bot-Api-Secret-Token` AND `message.chat.id == TELEGRAM_CHAT_ID` AND presser `from.id == TELEGRAM_OWNER_ID` (default the chat id); anyone else is ignored. First tap records `{answer, at, by}`, edits the message to show the answer and removes the buttons; a second tap changes nothing. |
| Note | same webhook | a text reply (owner, configured chat) to a decision message is stored as `note` (latest wins) via `decisionmsg:<messageId>` |
| Digest | `BrainDO.digest` (05:00 UTC) | a needs-you line "N decisions waiting" (pending count from KV list metadata, no value reads) |
| KV | binding `EVENTS` | `decision:<id>` (JSON, metadata `{status}`), `decisionmsg:<messageId>` -> id; both expire after 180 days |

No new secret or binding; Telegram methods used are `sendMessage`, `editMessageText`, `answerCallbackQuery`. Cost: Workers Paid + free Telegram, a few KV ops per decision.

## Social posting (Facebook Pages + LinkedIn company pages)

Plan, research links and Ahmad-only steps: `docs/plans/2026-11-11-social-posting.md`. Code: `src/social/` (engine, copy rules, routes,
Telegram preview, adapters), tests `test/social.test.ts`; the Mac half is `os/ops/social-content.sh` (launchd `social-content`, daily).
Instagram and TikTok are Ahmad's own and never posted by the OS.

| Piece | Where | Behaviour |
|---|---|---|
| Calendar | `social_posts` (BrainDO SQLite), images in KV `social:img:*` (90-day TTL) | one row per slot id `<brand>-<network>-<YYYYMMDDHHmm>`; re-submit = new revision |
| Approval | `socialTick` on the 5-min `tick` | preview to Telegram 24 h ahead; publishes only Ahmad-approved revisions until 14 days after his first approval (per brand), then auto |
| Publish | `src/social/adapters/{facebook,linkedin}.ts` | claim then call; lost answer = `uncertain`, reconciled from the Page feed, never blind-retried |
| Digest | `socialDigest` on the 05:00 `digest` cron | one message a day: mode, posts, failures, disabled networks, Instagram shares on the Page |
| Routes | `/social/drafts`, `/social/edits`, `/social/calendar`, `/social/status` (read-only self-check) (INGEST_TOKEN); `/social/decide`, `/social/brands/:brand` (SOCIAL_DECIDE_TOKEN); `/social/d/:id` (signed link) | |

Secrets: `SOCIAL_FACEBOOK`, `SOCIAL_LINKEDIN`, `SOCIAL_LINK_SECRET`, `SOCIAL_DECIDE_TOKEN`. Unset = that network / door is disabled and the
digest says why. Vars: `SOCIAL_APPROVAL_DAYS` (14), `SOCIAL_APPROVAL_LEAD_HOURS` (24), `SOCIAL_FB_SPACING_MIN` (180),
`SOCIAL_FB_MAX_DEFER_HOURS` (24), `SOCIAL_GRAPH_VERSION` (v27.0), `SOCIAL_LINKEDIN_VERSION` (202610).

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
| Questions | `BrainDO.flushQuestions/answerQuestion` | Options `proceed / hold`, default, deadline (`QUESTION_DEADLINE_HOURS`, 24). Reversible (a PR) → silence = default `proceed` after the deadline. Destructive → default `hold` and nothing ever happens on silence. Answers: a Telegram button press (Telegram delivers the `callback_query` to `POST /telegram/webhook`, authenticated by `X-Telegram-Bot-Api-Secret-Token`) or the dashboard. |
| Metrics | `BrainDO.actedOn/selfCheck` | acted = dispatched to the hands, asked as a question, or resolved. Acted-on ratio = acted / raised (24 h and 7 d). A finding unacted 24 h after it was raised is an OS bug: counted on the dashboard and in the digest, never its own message. |
| Usage guard | `src/usage.ts` | The hands report `POST /hands/usage {weeklyUsedPct, resetsAt?}` after each job. The brain refuses to start any run (urgent, nightly, Mac claim) when the last report is ≥ `USAGE_WEEKLY_THRESHOLD_PCT` (80) and not past `resetsAt`. No report / report older than 7 days → allowed and labelled `usage-unknown`. usage-unknown starts a run; the hands then refuse every job on unknown or over-threshold usage before any work (`os/cloud/hands/lib/usage-guard.mjs`, tested), so unknown is never unguarded. |
| Usage-starved alert | `BrainDO.noteNightly` | Ruling 4b-6. A nightly batch is starved when the usage guard refuses to start it, or when it starts and every job comes back `skipped_usage`. After `USAGE_STARVED_ALERT_AFTER` (3) starved batches in a row, and every multiple after, one urgent-class message (`usage-starved`: Ebda OS: the last N nightly batches did no work). Any batch with a non-skipped outcome resets the streak. Queue empty or a pull-only provider is not a skip. |
| Dashboard | `public/dash/`, `GET /api/state` | Static assets in the ebda.app studio look (light canvas, ebda.app tokens, gold `#B08D57` as accent, ebda.app girih motifs `public/dash/motifs/`, the Ebda AI Studio mark inlined, IBM Plex Sans Arabic self-hosted under OFL in `public/dash/fonts/`, no orange). Arabic first (`lang=ar dir=rtl`, English toggle remembered per browser), RTL by logical properties. Leads with the hands state ("Hands are OFF"), then counts, decisions, findings, runs, spend vs limits (hands $150/month + $10/day, Cloudflare estimate vs `CF_WARN_USD`/`CF_STOP_USD`), watchers not running with what each one is missing, production health, and a preview of the next digest (built, never sent, no writes). CSP set by the Worker (and `public/_headers`). Ruling RR-dash-auth: EVERY path runs the Worker first (`run_worker_first: true`) and `/dash/*` (HTML, JS, CSS) plus `/api/*` go through `gateHuman()` (`src/dash-auth.ts`): the Access JWT (RS256, aud, iss, exp) when Access is configured, else HTTP Basic Auth (user `ahmad`, secret `DASH_BASIC_PASSWORD` = Keychain `ebda-os-brain-dash-password`, constant-time compare, 10 failures per IP / 200 overall per 15 min lock out, even the right password), else 503. Every refusal is an empty 401/403/429/503. `/health` stays public. |

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

**A monitor's complete listing** (prod-watch, every 10 min from GitHub-hosted runners): `POST /findings` with
`{ findings, reconcile: { source, keep? } }`. Findings of `source` absent from the listing resolve ("cleared at the source");
keys under `keep` are left alone (the monitor could not evaluate them this run, e.g. the R2 logs were unreadable). The heartbeat
is `sources.prodWatchSeenAt` in `GET /api/state`. Kinds: `prod-outage` (probe), `prod-5xx`, `prod-429`, `prod-exception`,
`prod-logs-silent`, `alert-drill`. prod-watch already messages Telegram itself, so a prod-watch finding without a `repo` classifies as
`digest` (recorded, no hands job, no second message; `src/classify.ts`). Dead-man switch: see "prod-watch on the brain cron" below.

**prod-watch on the brain cron (AIOS-7).** With `PROD_WATCH_ON_BRAIN=1` (committed) the 5-min tick runs the prod-watch probes every
10 min (`src/prod-watch.ts`, KV-gated): same `os/config/prod-watch.json` list and `ebda-logs-core.mjs` rules as the GitHub run,
P1s sent with the same dedupe/6-a-day policy, findings as source `prod-watch` (heartbeat `sources.prodWatchCfSeenAt`). The GitHub
run is the secondary: R2 log rules, digest, and probe alerts only while this Worker's `/health` does not answer. Dead-man: brain-cron
run stale 30 min = one `monitor-silent` P1; GitHub run silent 24 h = a `monitor-stale` digest note.

**Platform alert feed (AIOS-8).** `POST /alerts {source, level p0|p1|p2|info, title, text, url?, repo?, at?}` (Bearer `INGEST_TOKEN`,
array <= 20): the same alert within 10 min is one row with a count; P0/P1 also become a `platform-alert` finding. Failed
default-branch workflow runs from the org webhook are recorded too. Overdue-control findings (ALERT_KINDS: `loop-main-red`, `loop-merge-stall`, `monitor-silent`, ...) are mirrored in as
`brain/<kind>` p1 rows when first raised (LOOP-WATCH-2), so the controller wakes on them, not only Ahmad's Telegram. Read: `GET /api/alerts?since=<id>&limit=` (dashboard auth),
newest first. Controller wait loop: `os/ops/alert-wait.sh` (exits printing new alerts).

**Controller leases (HANDS-COORD).** `POST /leases {repo, holder, ttlMin≤240, note?}` / `DELETE /leases {repo, holder}`
(Bearer `INGEST_TOKEN`; Mac helper `os/ops/controller-lease.sh`). 409 = another controller holds it. While a lease is live the
brain hands no job for that repo to any provider; the hands read `GET /hands/leases` before touching a repo (fail closed).

**Committed watcher config.** `os/config/brain-watchers.json` (page-load, journeys, npm deps, CF prefix, cost org) and
`os/config/hands.ebda.json` (= `HANDS_CONFIG_JSON`, also the ci-catchup repo list) are rendered by `scripts/deploy.sh`; an
`OS_BRAIN_<NAME>` in the environment or `~/.ebda-os.local.env` overrides a key.

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
   for s in GH_WEBHOOK_SECRET RELAY_SECRET HANDS_TOKEN HANDS_MAC_TOKEN INGEST_TOKEN TELEGRAM_WEBHOOK_SECRET TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID GITHUB_TOKEN; do
     CLOUDFLARE_ACCOUNT_ID=$OS_CF_ACCOUNT_ID npx wrangler secret put "$s" --config wrangler.deploy.jsonc
   done
   ```
   - `HANDS_TOKEN` is the HMAC key for the per-run container tokens (never a bearer); `HANDS_MAC_TOKEN` is the Mac's own bearer (put the same value in the Mac's `OS_SERVICES_ENV`, NOT `HANDS_TOKEN`). The hands key: `HANDS_ANTHROPIC_API_KEY` (a Console key with a hard spend limit; `HANDS_API_SPEND_LIMIT_USD` declares that limit, committed as 200), plus `OS_BRAIN_CONTAINERS=1` at deploy to merge the containers block. Never put `ANTHROPIC_API_KEY` on the Mac.
   - Dashboard (ruling RR-dash-auth): `DASH_BASIC_PASSWORD` from the Keychain without printing it:
     `security find-generic-password -s ebda-os-brain-dash-password -a ahmad -w | npx wrangler secret put DASH_BASIC_PASSWORD --config wrangler.deploy.jsonc`.
     Create it once with `security add-generic-password -s ebda-os-brain-dash-password -a ahmad -w "$(openssl rand -base64 32)"`. Without it (and without Access) `/dash/*` and `/api/*` answer 503.
   - `RELAY_SECRET` must equal the Mac listener's relay secret (in `OS_SERVICES_ENV`). Leave it unset to run brain-only (no `/pending` copy).
   - `GITHUB_TOKEN`: fine-grained PAT per org (resource owner = the org), read-only **Dependabot alerts**. Until set, the advisory watcher records `GITHUB_TOKEN secret unset` and does nothing.
   - Telegram (ruling RR-tg-brain-owns): the brain REUSES `@EbdaAIStudiobot` and is its single consumer (a webhook, never `getUpdates`). Load the secrets from the Keychain without printing them:
     `security find-generic-password -s ebda-telegram-bot -w | npx wrangler secret put TELEGRAM_BOT_TOKEN --config wrangler.deploy.jsonc` and the same with `-s ebda-telegram-alert-chat-id` for `TELEGRAM_CHAT_ID`. `TELEGRAM_WEBHOOK_SECRET` is a random secret the brain hands to Telegram as the webhook `secret_token`.
     `security find-generic-password -s ebda-telegram-bot -w | npx wrangler secret put TELEGRAM_BOT_TOKEN --config wrangler.deploy.jsonc` and the same with `-s ebda-telegram-alert-chat-id` for `TELEGRAM_CHAT_ID`. `TELEGRAM_WEBHOOK_SECRET` is a random secret shared with the relay (below), not a Telegram webhook secret.
5. GitHub org webhooks (one per org in `OS_ORGS` minus the personal account, which has no org webhooks):
   `gh api orgs/<org>/hooks -f name=web -F active=true -f 'events[]=workflow_run' -f config[url]=https://$OS_BRAIN_HOST/github/webhook -f config[content_type]=json -f config[secret]=<GH_WEBHOOK_SECRET>`
   (needs `admin:org_hook`; only `workflow_run`). Check: the hook's ping returns 204 in the org's webhook deliveries.
6. Telegram (after the Worker is deployed with the secrets): stop the old tg-relay (`screen -S tgrelay -X quit`; once a webhook is set, polling `getUpdates` stops working anyway). Register once with `curl -X POST -H "Authorization: Bearer $INGEST_TOKEN" https://os.ebda.app/api/telegram/webhook/set` and confirm with `GET /api/telegram/webhook/info` (`pending_update_count`, `url`, no `last_error_message`).
7. Cloudflare Access (Zero Trust → Access → Applications, self-hosted), two path-scoped applications on `$OS_BRAIN_HOST`:
   `/dash` and `/api`, policy = Ahmad's email only. Do **not** cover `/github`, `/telegram`, `/hands`, `/findings`, `/leases`, `/alerts`,
   `/pending`, `/health` (machines authenticate with their own secrets). Then add the team domain + the application AUD
   tag to `~/.ebda-os.local.env` as `OS_BRAIN_ACCESS_TEAM_DOMAIN=<team>.cloudflareaccess.com` and `OS_BRAIN_ACCESS_AUD=<aud>`
   and redeploy (step 3). From then on Access wins and Basic Auth is ignored; set `DASH_BASIC_AUTH` to `off` in
   `wrangler.jsonc` and `npx wrangler secret delete DASH_BASIC_PASSWORD` to drop it entirely. Until Access is set,
   `/dash/*` and `/api/*` need Basic Auth (user `ahmad`, the Keychain password).
8. Verify against production: `/health` 200; a webhook redelivery from the org settings → 204; `GET /pending` with the
   relay secret returns `[]` or events; `curl -sI https://$OS_BRAIN_HOST/dash/` and `/dash/dash.js` answer 401 with no body, the dashboard loads with the owner's login; after the first `:07` the dashboard shows the
   advisory run per org; the first digest arrives at 05:00 UTC.

Rollback: `npx wrangler rollback --config wrangler.deploy.jsonc` (code); disable the org webhooks to stop the inbox.


## Cost and abuse controls (audit 2026-11-09, rulings in `docs/RULINGS.md`)

- **One halt flag (F-01).** `HANDS_HALT` (Worker var) or the DO key `halt` stops every container start: urgent, nightly and Mac claim all check it, and the HandsContainer DO answers 423. A `cost-stop`, `cf-usage-stop` or `budget-stop` finding sets it and sends ONE p1 message; `POST /api/halt {"on":true|false,"reason":"..."}` (behind Access, same-origin) sets or clears it; clearing is manual only. The digest leads with `HANDS HALTED: <reason>` and the dashboard shows a banner.
- **Dollar budgets (RR-hands-api-auth).** Every outcome carries the job's cost (the hands compute it from the API response usage x a price table). Monthly default `HANDS_MONTHLY_BUDGET_USD` 150 (config test: set and <= 190, under the $200 API credit): 80 % = a digest warning, 100 % = the halt + one alert. Daily `HANDS_DAILY_BUDGET_USD` 10: past it no new run starts until tomorrow. The batch carries the remaining dollars (`budgetUsd`) and the hands stop between jobs.
- **Model routing.** Sonnet by default, haiku for triage / classification / summaries, opus ONLY for a finding flagged `security-design` or `money-design` and capped by `HANDS_OPUS_JOBS_PER_DAY` (2). The model is recorded per run (`run:models:<id>`) and the month's spend per model is on the dashboard state.
- **Auth.** `HANDS_CLAUDE_AUTH=api` (default) uses the Console key `HANDS_ANTHROPIC_API_KEY` (a Worker secret ONLY the HandsContainer DO reads; it reaches the container as `ANTHROPIC_API_KEY`) and refuses to start without `HANDS_API_SPEND_LIMIT_USD` (the hard limit Ahmad set in the Console, the committed `HANDS_API_SPEND_LIMIT_USD` (200, overridable at deploy through the environment variable of the same name)). `max` selects the OAuth token instead. The Mac runs on Ahmad's login and never holds a key.
- **Per-run credentials (F-06b).** The container's bearer is HMAC(`HANDS_TOKEN`, runId): valid for its own run and jobs only; `HANDS_TOKEN` is just the key. The Mac has `HANDS_MAC_TOKEN`, which can claim as `mac-local` (provider comes from the token) and report on Mac runs. Usage reports lower than the last one inside the same weekly window are ignored.
- **Containers (F-02, F-04).** `wrangler.containers.jsonc` holds the block (`max_instances` 2, `standard-1`); `deploy.sh` merges it only with `OS_BRAIN_CONTAINERS=1`. The alarm destroys a running container with no run state, past its deadline or past the 245-minute ceiling, arms its next tick BEFORE `destroy()`, and the platform inactivity timeout is set as a backstop. A swept run stops its container; `POST /stop` on the container DO does the same.
- **Footprint (F-05).** The daily `cf-usage` watcher reads Durable Object, KV, Containers and Workers usage from the GraphQL API: warn at 50 %, stop at 100 % of `CF_DO_REQUESTS_DAY` / `CF_KV_WRITES_DAY` / `CF_CONTAINER_VCPU_MIN_DAY`; the digest carries a "Footprint (24 h)" line, `unknown` when a read failed (never 0).
- **Smaller fences.** Mac claims: `HANDS_MAC_JOBS_PER_DAY` (5). Question sends: 3 tries, `retry_after` honoured, a 401/403 stops all sends that day. Alarms: never sooner than 60 s, a throw re-arms at +5 min. No nightly batch while GitHub or Anthropic has an open major incident. Ingest: `detail` <= 8 KiB, `INGEST_PER_DAY` 1000. `limits` (cpu 30 s, 500 subrequests) are in `wrangler.jsonc`.
- **GitHub (F-12).** A GitHub App (`GH_APP_ID`, `GH_APP_PRIVATE_KEY` PKCS#8, `GH_APP_INSTALLATIONS` `{"owner": id}`) mints a 1 h token per run per owner, narrowed to the run's repos with contents + pull_requests write. Without it the PAT fallback (`HANDS_GH_TOKEN`) is used (ruling RR-gh-token). `bash scripts/deploy.sh --check` fails while any repo in the hands config lacks a default-branch ruleset (PR, required checks, no force push, no deletion, no bypass).
- **Meter (RR-meter).** `POST /hands/meter` (run token) books each API response's cost as it happens; a swept job that began Claude with no reading is charged `HANDS_JOB_PESSIMISTIC_USD` (2), never $0; a late outcome's usage is booked before its state change is refused. Per-job hard budget `HANDS_JOB_BUDGET_USD` (5).
