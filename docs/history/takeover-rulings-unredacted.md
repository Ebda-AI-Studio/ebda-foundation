# Takeover rulings, original wording

The tracked ledger (docs/RULINGS.md) carries these with predecessor names replaced by [prior-name], because the repo-wide forbidden-string test scans everything outside docs/history/.

## Takeover rulings (feat/foundation-takeover)

Copied from the git-excluded SDD progress log on 2026-11-09 so they live in a tracked file. TK-nn ids were assigned in log order to rulings that had none.

Ruling TK-01 - one integration branch feat/foundation-takeover for Tasks 2-6 + 9, one PR at the end, merged via ebda-foundation's merge-gate — SDD's single-branch model; per-task PRs would multiply CI runs (frugality rule) — cost if wrong: one larger PR to review.

Ruling TK-02 - Task 1's merge of PR #1/#2 happens on main first (those PRs exist and are independent), then this branch merges origin/main — keeps their history — cost if wrong: one merge commit.

Ruling TK-03 - Task 0 leaves Force AI's open work untouched (default in the plan) and only tags; the report of open work goes to Ahmad in the controller's message — cost if wrong: Force plan/worktrees stay unlanded (they are Force AI's).

Ruling TK-04 - OD-2 event relay — Ahmad asked "what will it do for us", no decision yet; Task 4 ports the relay source into os/workers/event-relay WITHOUT deploying (deploy needs Ahmad's yes) — cost if wrong: a few unused files.

Ruling TK-05 - Task 7 (live Mac cutover) is a stop point: the controller asks Ahmad before running it — security-sensitive side effect. Cost if wrong: not stated when the ruling was made (see the takeover plan and review notes).

Ruling TK-06 - Task 8 (consumers in other repos) runs after the final review of this branch, each consumer its own PR — it is outside this worktree. Cost if wrong: not stated when the ruling was made (see the takeover plan and review notes).

Ruling TK-07 - port source = final-before-ebda PLUS the generic OS changes of the 10 open OS PRs (#262-#264, #274-#280; list in fnd-open-os-prs.tsv) — they are newer fixes (runner guard, hygiene sweep, auto-heal, merge-gate cancelled≠failing, umbra fsck, usage sentinel) that would otherwise be lost when the old repo freezes — cost if wrong: an unreviewed PR's change lands in the port; mitigated because each passes the task review.

Ruling TK-08 - (supersedes OD-2 ruling): Ahmad said "Do it" (2026-11-05 ~22:30) to the event relay → Task 4 ports os/workers/event-relay AND adds a deploy runbook (personal CF account 69188202…, KV namespace, RELAY_SECRET, GitHub org webhooks on Ebda-AI-Studio + Whisky-11 for workflow_run). The live deploy + webhook creation run in Task 7 (Mac cutover), with the controller — cost if wrong: a small Worker + 2 webhooks to remove.

Ruling TK-09 - finding "step 3 no PR/merge" — preflight ruling (one PR at end) stands — cost if wrong: none extra.

Ruling TK-10 - finding "plan doc docs/plans/done/2026-11-05-foundation-takeover.md matches forbidden strings" — it must name them; Task 2's no-force-strings test exempts docs/history/ AND that one plan file by exact path — cost if wrong: a future plan could hide a Force string (only this path is exempt).

Ruling TK-11 - finding "repo-wide forbidden-string test missing" — it is Task 2 Step 1 by the plan; not pulled into Task 1 — cost if wrong: none (Task 2 is next).

Ruling TK-12 - (spec addition, Ahmad 2026-11-05): "Ebda Telegram must not message a lot — actually act and enhance the products from the dreaming cycle and CVEs" → Task 4 adds an action engine + notification policy (memory feedback-os-acts-not-pings): finding → worktree → fix → PR → merge gate; auto-merge only for pre-approved classes (dep/CVE bumps, docs, tests, lint, flaky fixes); Telegram budget = unhealed P1 + real decisions + 1 daily digest of outcomes (≤3/day, deduped); acted-on ratio measured. Telegram bot = the Ebda bot (@EbdaAIStudiobot), not the Force bot — cost if wrong: more autonomous PRs than Ahmad wants (gate + class allowlist bound it).

Ruling TK-13 - (spec change, Ahmad 2026-11-05 late — plan Amendment A, commit 2c6c8f0 on docs/foundation-takeover-plan): GitHub stays; Actions minutes = CI only (OS spends 0); always-on brain on Cloudflare Workers (os/cloud/brain); hands = ONE batched Cloudflare container run per day (end of day) + Mac fallback; Task 4 → 4a (brain Worker) + 4b (hands batch). Merge the amended plan into feat/foundation-takeover AFTER Task 2 finishes (agent is working in the tree) and re-extract briefs for Tasks 4a/4b/5/7 — cost if wrong: Task 2 ports a few Mac-only scripts that become unused.

Ruling TK-14 - (Amendment A.1, Ahmad): urgent jobs (unhealed outage/money path, CVSS≥9 or KEV, data exposure) get an immediate container; max 3/day, 1 at a time, 30-min cap — cost if wrong: up to 3 extra container runs/day (cents).

Ruling TK-15 - I3 (96 ops suites not in CI) — add them to CI but path-filtered (run only when os/** changes), on ubuntu-24.04 — ~8 min per OS PR; frugal rule satisfied by the filter — cost if wrong: ~8 CI min per OS-touching PR.

Ruling TK-16 - I4 + hardcoded identities — new os.env keys OS_UMBRA_VMS (default "fwb-ci6"), OS_SENTRY_ORG (default the current org id, overridable), OS_PROJECTS_DIR ($HOME/Desktop/projects) — the VM name stays the real one until Umbra moves (OD-3) — cost if wrong: a later rename touches only os.env.

Ruling TK-17 - widen os/tests/no-force-strings.test.sh (Task 2's file) in Task 3's fix round — the gap was found here; regex adds client domains/names, `force[-_ ]?ai` (case-insensitive), `Force AI`, `forceai[-_.]`, `FWB|WBS` as words, `force-website-builder|whatsapp-bulk-sender|gcc-horse-market|horse-market|work-wise|legende|olounge|beethoven|al[-_]?assriya|wady|pecan+bee|forcemediakw` — cost if wrong: false positives on generic words (fix by narrowing, never by exempting a whole dir).

Ruling TK-18 - client names in watch lists/deny lists → move to the gitignored per-machine local config (~/.ebda-os.local.json) with an example file listing placeholders — data stays on the machine, not in git — cost if wrong: watchers have empty lists until the local file is written (Task 7 writes it).

Ruling TK-19 - FWB/WBS/CRM references in standards → neutral wording ("a previous storefront product", "an earlier messaging product"); PR numbers/incidents → docs/history/standards/incidents.md with a link; `sources: reference-force-ai-*` lines → removed (memory slugs are not repo content). Cost if wrong: not stated when the ruling was made (see the takeover plan and review notes).

Ruling TK-20 - /force-build and /force-audit references → rename to the Ebda skill names that exist (or drop the reference with a note in docs/history) — cost if wrong: a dangling command name in docs.

Ruling TK-21 - playbook → one "Current stack" table matching ebda-store main (Cloudflare Workers, D1, Durable Objects, KV, Queues, R2, Workers AI; identity service; Telegram) + a short "Legacy (Postgres/Neon/Redis/Inngest/Socket.io/Vercel) — retired 2026-11-05" note linking docs/history — cost if wrong: a stale fact in a doc.

Ruling TK-22 - `fwb-ci6` is the real Umbra VM name (live infra; renaming it is out of scope until OD-3 moves Umbra) — it may appear ONLY as a value of OS_UMBRA_VMS in os/config/os.env and in os-config.sh's embedded default; the string test exempts exactly those two lines by key, everything else uses $OS_UMBRA_VMS or a neutral placeholder (<umbra-vm>) in docs — cost if wrong: one legacy name stays visible in config until the VM is renamed.

Ruling TK-23 - other lowercase fwb/wbs service names (fwb-web, wbs-api, wbs-monitor, "fwb:ebda-store" maps) → neutral names (store-web, msg-api, …) or removed; test pattern becomes case-insensitive \b(fwb|wbs)\b. Cost if wrong: not stated when the ruling was made (see the takeover plan and review notes).

Ruling TK-24 - I-4 — usage-unknown stays allowed ONLY while the hands provider is the stub; carried into Task 4b as a hard requirement (refuse real hands work on unknown/over-threshold usage, with a test) — cost if wrong: a real provider could run past the weekly budget if 4b forgets (the 4b brief will state it).

Ruling TK-25 - I-2 — unhealed-P1 outage messages: one per incident fingerprint + a hard daily ceiling of 6 total Telegram messages (3 normal + up to 3 urgent/P1), overflow rolls into the digest — honours "≤3/day on a normal day" and bounds a bad day — cost if wrong: a 7th distinct real outage on one day reaches Ahmad only in the digest.

Ruling TK-26 - (Ahmad 2026-11-06): deploy the brain (4a) standalone FIRST THING after the weekly reset, before Tasks 5-7 — cost if wrong: brain runs without hands for a while (findings queue as PR-less jobs/questions).

Ruling TK-27 - (framework for fix round 1): EVERY old job gets one explicit disposition in os/MANIFEST.md with a reason — (a) KEEP-MAC (needs the Mac: Claude CLI, Umbra, local disk/memory: dream/reflect/instinct, self-heal for Mac services, mac-maintenance, memory jobs), (b) PORT-BRAIN (cheap watcher logic, always-on: sentry-stale, deploy-drift, page-load via fetch/Browser Rendering, journey/synthetic checks, services/cf-workers watch, cost-guard, dr-drill trigger → the weekly restore drill), (c) REPLACED-BY (name the replacement: alert-triage → brain classify; daily-brief → brain digest; dashboard server → brain dashboard; ci-alert → relay webhooks; pr-shepherd → hands; event-listener → relay /pending), (d) DROP (Force-only or obsolete, with reason: ghas-guard — GHAS stays off by rule; anomaly-watch FWB/WBS maps; neon-backup — no Neon). No job without a row. PORT-BRAIN items that don't exist yet are implemented in a Task 4a follow-up BEFORE Task 7 (the cutover gate checks MANIFEST: any job marked PORT-BRAIN without code blocks cutover) — cost if wrong: a watcher's signal is missing for the days between cutover and its port, so the gate forbids that.

Ruling TK-28 - (Ahmad 2026-11-06): DROP for good — ghas-guard (GHAS off), neon-backup, aladiyat-backup, salam erp-backup, wbs-monitor, checkout-monitor, anomaly-watch (Force products; stopped+disabled on the Mac today, reversible). The Ebda OS never backs up or alerts on Force AI products — cost if wrong: Force client DBs lose Ahmad-side local dumps (they keep their own provider backups).

Ruling TK-29 - R-4a-1: config-missing findings (monitor-unconfigured, watcher-error) from ANY source (watchers AND dream/heal-watch) go to a new digest-only lane — no hands job, no Telegram question. Why: hands cannot set tokens/config; Ahmad wants ≤3 messages/day and ~8 such findings arrive on first deploy. Overrides the Task 6 classify test expecting nightly for dream monitor-unconfigured. Cost if wrong: a config gap waits for the daily digest instead of pinging — acceptable, it is not an outage.

Ruling TK-30 - R-4a-2: the hands drill:'pass' parse in os/cloud/hands/lib/run.mjs needs a unit test (PASS → pass, FAIL/absent → no marker) before task completion. Cost if wrong: not stated when the ruling was made (see the takeover plan and review notes).

Ruling TK-31 - R-4a-3: digest query reads LIMIT 500 digest-lane rows before filtering shown ones; >500 stale digest rows could hide a new one. Accepted residual — digest-lane findings are deduped per watcher×subject (≈10 watchers × few subjects), 500 unreachable in practice. Cost if wrong: a monitor note is delayed until old rows resolve; fix then = filter shown in SQL. Batched for final review.

Ruling R-8 - Task 8 (F2–F11 consumer adoption: 10 PRs into ebda-store + ebda-whatsapp, incl. F5 identity, F6 alerts, F7 search re-index, F9 guard/erasure) starts AFTER the Nov 11–14 launch, not now. Why: each changes live auth/observability/search/erasure code in both products during launch week; the takeover's own goal (OS + library in ebda-foundation, Mac independent of force-ai-foundation) does not need consumers re-synced. The final whole-branch review + ONE PR proceed without Task 8. Cost if wrong: consumers stay on vendored copies ~1 more week (no user-visible effect; skew rule ≤7 d on MINOR is not yet in force since no consumer is on the lock).

Ruling F-C1 - a P1/urgent the hands refuse (usage guard or any refusal) is NOT demoted silently: hands always report usage + refusal reason; the brain sends ONE Telegram P1 "could not self-heal: <reason>" (allowed class: unhealed P1) and keeps the job queued for the next eligible run. Cost if wrong: one extra message on a refusal day.

Ruling F-I5 - pr-shepherd: CONFLICTING or failing-checks PRs on a SAME-REPO branch → hands job that checks out the PR head branch and pushes to it (never forks; PROTECTED paths + secret scan still apply; never merges). PRs only "waiting >24 h" → digest lane. Cost if wrong: a fix pushed to a PR branch Ahmad was editing — mitigated by same-repo + bot-authored-or-OS-branch only (ebda-os/* or PRs opened by the OS); human branches → digest.

Ruling F-I6 - the weekly restore drill needs R2 + age secrets the container must not hold: it runs on the Mac (KEEP-MAC, mac-local lane) weekly and posts its PASS/FAIL to the brain ingest; the brain's dr-drill watcher only checks staleness of the last PASS and raises dr-drill-stale (digest if <14 d, P1 question if ≥14 d). No hands job. Cost if wrong: drill depends on the Mac being up; staleness alarm covers it.

Ruling F-I8 - container egress allowlist (github.com/api.github.com/codeload, registry.npmjs.org, api.anthropic.com, the brain URL); Claude runs as a uid that cannot read the hands' git token or its own credential file beyond the process env passed by the runner; hands-opened PRs run CI that has NO deploy secrets (deploy secrets only on main/environment-protected jobs) — verify each consumer's workflows and add a merge-gate refusal for hands PRs if a workflow exposes secrets to PR events. Cost if wrong: hands may fail on an unlisted host; it fails closed, visible as a watcher-error.

Ruling F-I11 - remove Neon scripts, the Neon org id and any Force/client DB targets from os/ (Ebda has no Neon; Force Neon jobs are DROP); add a `neon` pattern to no-force-strings (exempt only force-purge-check + its test). Cost if wrong: none — FWB/WBS Neon stays Ahmad's call outside this OS.

Ruling RR-M10-pending - GET /pending (Mac fallback drain) stays non-atomic: Workers KV has no atomic read+delete, so two concurrent drains can both return an event, and a drain whose response is lost drops up to 100 events. Evidence: the endpoint serves only the predecessor-wire-format relay fallback (RELAY_SECRET), the Mac is the single caller, events carry a signed id the Mac dedupes on, and the same CI results also reach the brain through the webhook (ingestCiEvent) and ci-catchup, so a dropped relay event is re-derived within the hour. Cost if wrong: one Mac-side CI notification is missed or shown twice; no money, auth or data path depends on it.

Ruling RR-GH-exfil - The unprivileged uids have NO GitHub path: Claude's proxy allows only api.anthropic.com (plus HANDS_EGRESS_ALLOW); the install, test and format commands get a proxy with an empty allowlist and an npm registry MIRROR that forwards GET/HEAD only (publish, dist-tag, unpublish are 405); the hands' own git and gh run as root outside the proxies (`os/cloud/hands/lib/egress.mjs`, tests in `test/final-fix.test.mjs`). This REPLACES the earlier evidence, which was wrong: an injected payload can carry the attacker's OWN GitHub PAT, Anthropic key or npm token, so "the untrusted code has no GitHub credential" never closed a write path to api.github.com, api.anthropic.com or registry.npmjs.org. Real residual (inferred, not measured): the proxy is a TLS tunnel and cannot see methods, so Claude (bypassPermissions) can still upload what it can read (the checkout of a mapped private repo, its prompt) to the attacker's own Anthropic account with the attacker's key; closing that needs TLS interception or a credential-pinning forwarder behind ANTHROPIC_BASE_URL, which is NOT VERIFIED to work with the OAuth flow. Cost if wrong: the contents of a mapped private repo leak to an attacker-controlled Anthropic account; the Claude OAuth token and the GitHub token are not in that reach (see RR-ptrace).

Ruling RR-net-admin - CAP_NET_ADMIN / iptables-nft / ip6tables inside a Cloudflare Container is NOT VERIFIED (nothing was deployed or measured). The container now fails closed (exit 3) and tells the brain (POST /hands/refused), which raises a P1 once a day, fails the run and requeues its jobs. The check that settles it at deploy time (Task 7, before the Mac bootout): start one nightly run with a single harmless docs finding and read /api/state: a `hands:refused` P1 in Telegram, or a run stuck `failed` with no usage report, means the rules cannot be applied (then run the hands on the Mac / another provider, or drop to the proxy-only mode via HANDS_EGRESS_REQUIRE_KERNEL=0 by an explicit ruling); a first `POST /hands/usage` from the container means the rules applied. Cost if wrong: the cloud hands do not run until the platform grants the capability; nothing runs with open egress.

Ruling RR-ci-catchup - the 1 h replay window on webhooks stays (it is the replay guard); lost events are covered by the hourly ci-catchup watcher (newest completed run per workflow, last 48 h, hands-mapped repos only), idempotent through the run id + attempt key. Cost if wrong: a red CI on a repo outside the hands config, or older than 48 h, is not caught up and waits for the next push.

Ruling RR-tg-send-only - The brain reuses @EbdaAIStudiobot (Keychain items `ebda-telegram-bot`, `ebda-telegram-alert-chat-id`) and is SEND-ONLY: `sendMessage` for alerts, questions and the digest, `answerCallbackQuery` to acknowledge a button; no `setWebhook`, no `getUpdates` anywhere (`os/cloud/brain/test/send-only.test.ts` scans the sources). Inbound button answers reach the brain only through the authenticated `POST /telegram/webhook`, which the tg-relay session (the bot's one poller) calls with the shared `TELEGRAM_WEBHOOK_SECRET`; inbound text commands are dropped. Decision: Ahmad 2026-11-09. Cost if wrong: a button press is not delivered until the relay forwards it, so a question waits for the dashboard or its deadline default.
