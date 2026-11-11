# 2026-11-11 Jarvis mode: the OS runs the loop unattended

Ahmad (2026-11-11): the OS handles everything below a delegation threshold, sends ONE nightly update, and calls him only for real decisions. **Hard constraint: zero new spend.** Only what is already paid: Cloudflare Workers Paid (personal account; brain `ebda-os-brain` + crons), this Mac (self-hosted runner, launchd, `claude -p` on Claude Max), the Telegram bot @EbdaAIStudiobot, GitHub.

## Finish line
- **Must work:** a red main or a stalled merge is diagnosed and fixed or retried without a chat session; one nightly message; a P0 reaches Ahmad's phone loudly.
- **Exercised:** brain cron -> finding -> job -> Mac hands (`claude -p`) -> PR; forced Actions-exhausted and infra-red drills; phone test push.
- **Must not change:** hands open PRs only (HANDS-COORD, `HANDS_MAY_MERGE` false); merge only via `ops/merge-gate.sh` and the `ai-review-passed` gate; prod-watch keeps Telegram alert ownership (OBS-2); `OS_HANDS_LOCAL` stays opt-in until Phase 2 passes.
- **Done =** each phase's exit check below passes as measured facts, and the monthly bill delta is $0.

## Existing parts this builds on (read, not assumed)
- Brain: `os/cloud/brain/` (crons */5, */15, 6 h, 21:30 UTC nightly hands batch, 05:00 UTC daily digest; Telegram <= 3/day + 1 digest, deduped; classifier lanes).
- Hands: `os/cloud/hands/` + Mac job `hands-mac-local` (opt-in via `OS_HANDS_LOCAL=1`, `os/launchd/mac-local.list`); config `os/config/hands.ebda.json` (`jobCapMin` 45, `runCapMin` 90, `usageThresholdPct` 80, `protectedPaths`).
- Guards: `os/ops/host-lock.sh`, `os/ops/usage-sentinel.sh` (>= 80 % weekly writes the fanout-stop file), `os/ops/controller-lease.sh`, `os/ops/ci-runner-guard.sh`, `os/ops/notify.sh`, `os/ops/drain.sh`.
- Learning: `os/ops/dream-standard-drift.sh`, `os/ops/encode-lesson.sh` (draft only, human review), `os/standard/`, `docs/RULINGS.md`.

## 1. Delegation policy
New `os/config/delegation.json`, read by the brain classifier and the hands runner. Plus Ruling DELEG-1 in `docs/RULINGS.md` (decision, evidence, cost if wrong). Fail closed: a class not listed = ASK.

| Class | Default | Named fields Ahmad sets |
|---|---|---|
| docs, tests, lint, deps patch/minor with green CI, CI/infra reruns, flaky retry | ACT + report | `maxFilesActAlone`, `maxLinesActAlone` |
| code in money paths (orders, payments, payouts, refunds, entitlements) | ACT only with independent AI review passed (`ai-review-passed`), else ASK | `moneyPaths` globs |
| irreversible migration (drop/rename column, data delete, backfill on prod) | ASK | - |
| real-client traffic switch (FWB pecanbee, wady aljuz; DNS, routing, flags that move live stores) | ASK | `realClientTargets` |
| purchase, payment, plan upgrade, any spend > `spendCapUsd` (default 0) | ASK | `spendCapUsd` |
| anything needing Ahmad's login, 2FA or a new secret | ASK | - |
| protected paths (`.github/**`, `wrangler*`, `migrations/**`) | PR only, ASK before merge | `protectedPaths` (already in `hands.ebda.json`) |
| deploy of Ebda products | ACT (standing OK, deploy-change label) then verify live | - |

ASK = one queued question in the brain (default recorded, cost if wrong stated) and the loop keeps going on other work (overnight-queue rule). A question unanswered for `askDefaultAfterHours` takes its stated default only if the class says `defaultOnTimeout: true`; money, migration, real-client and spend never do.
Test: a table-driven test feeds each class and asserts ACT/ASK; a missing class asserts ASK.

## 2. The controller lives in infrastructure
- **Triage = brain (cron).** Findings -> classifier -> `delegation.json` -> job or question. No chat session is required for any step.
- **Execution = Mac hands.** Load the launchd job (`OS_HANDS_LOCAL=1`) only after these exist and pass tests:
  1. Each job runs `host-lock.sh` (one heavy job host-wide) and `claude -p --model sonnet` in a fresh worktree (`new-task-worktree.sh`, deps via `wt-deps.sh`).
  2. **Progress check** (keepalive lesson): a restart needs new commits or a changed failing-test set since the last run; **max 3 restarts per job per hour, 6 per day**; a done-marker file stops the loop; breach = one `watcher-error` finding, no further restarts.
  3. **Usage fanout-stop:** before each spawn, `usage-sentinel.sh`; the fanout-stop file present = spawn nothing, queue the job, say so in the nightly update. One concurrent `claude -p` (hard rule: never > 1-2).
  4. Caps from `hands.ebda.json`; protected paths force PR-only; the controller lease (`controller-lease.sh`) keeps one writer per repo.
- **Detached loops** are listed in the handoff and have a stop file (detached-guard lesson).
- **Heartbeat:** the Mac posts to the brain every 5 min; a missing heartbeat > 20 min is a P1 finding (the Mac is the single point of failure; at $0 there is no standby, stated residual).
- Footprint: one Mac process at a time, ~0 CPU idle; brain cron additions use the existing Workers Paid allowance; cost $0.

## 3. Self-recovery for today's incidents
Each is a brain finding class with a runbook the hands execute; paging only when the runbook ends unresolved.

| Incident | Detect | Act alone | Page only if |
|---|---|---|---|
| **Actions minutes exhausted** (50k burned by bulk `update-branch`) | CI inbox sees runs failing with the quota message / billing API shows 100 % | set repo var `EBDA_RUNS_ON` to the Mac runner label on every Ebda repo, rerun failed runs once, record the change; revert when minutes reset (var unset = hosted) | the Mac runner is offline and `runner-restore.sh` fails |
| **main red from infra** (apt/Chromium install step fails on all shards, same step, no test failure) | `deploy-red-on-main` + same failing step name across all shards | rerun failed jobs on the Mac runner (`EBDA_RUNS_ON`), no page; second failure = open a fix PR for the install step | red persists after the Mac rerun, or any shard shows a real test failure |
| **merge stall** | PR green + mergeable + not merged > `mergeStallMin` | diagnose in order: missing label (`ai-review-passed` stripped by a new push), behind main (one `update-branch` per PR, never bulk), required check missing, ruleset, merge-gate refusal; fix the cause, one retry | cause is a review finding, a conflict needing a decision, or a permission only Ahmad has |

Guard from the Actions lesson: **bulk `update-branch` is forbidden**; `drain.sh` updates at most `maxUpdateBranchPerHour` PRs, only when idle, never one whose agent is mid-push. A test asserts the cap.

## 4. Nightly update
One Telegram message at 05:00 UTC (the existing daily digest slot, `digest` lane), <= 8 lines, plain text:
```
1 Up/down: ebda.app, store admin, api, os brain (ok/down + since)
2 Orders (24 h): N paid, N failed, N refunds
3 CI/deploys: main green|red, last deploy sha = main tip yes|no
4 Fixed alone: N items (top 3 one-liners)
5-7 Waits for you: <decision> -> default taken: <x> -> cost if wrong: <y>
8 Spend: $0 delta; Actions minutes used N%; Claude weekly N%
```
Individual alerts keep the existing cap (<= 3/day, deduped). Orders come from a read-only SELECT through the existing prod-watch path, never a write. If no data source is reachable the line says "could not check", not zero (unknown is not empty).

## 5. Escalation that rings the phone at $0
Facts, checked against what is known and marked:
- Telegram Bot API cannot place voice calls (measured: no such method in the Bot API; calls exist only for user accounts over MTProto).
- **(a) Telegram P0 repeated every 2 min until acked** with an inline "Ack" button (callback handled by the brain; stop on ack). Free, no new infra. Limit: a bot message is a normal notification; it rings only if Ahmad's phone lets that chat through Do Not Disturb. iOS has no critical alerts for Telegram; the usable lever is a Focus exception for Telegram + a custom loud sound on the bot chat (inferred from iOS/Telegram settings, to be proven in the drill below).
- **(b) ntfy.sh**: free, open source, topic-based; the brain POSTs with `Priority: 5` (max) and a `Click` link. Free tier is about 250 messages/day per visitor (inferred from the public docs; confirm at https://docs.ntfy.sh/publish/#limitations) which is far above P0 volume. Android: priority-5 notifications go to the "max" channel; the channel can be set to bypass Do Not Disturb and use the alarm volume. iOS: the ntfy app has no Apple critical-alert entitlement (inferred, NOT VERIFIED), so it behaves like (a): rely on a Focus exception for the ntfy app and the notification sound. The topic name is a shared secret: use a long random topic, never reuse it.
- (c) Twilio trial and any paid voice: rejected (costs money; trial calls only reach verified numbers and carry a trial preamble).
- (d) Telegram userbot/MTProto call from a second account: rejected (ToS risk, account ban, fragile).

**Recommendation: (b) + (a) as a pair.** ntfy is the loud channel; the repeating Telegram message is the independent second path and the ack path. Fire both on a P0; repeat both every 2 min up to `p0MaxRepeats` (default 10), stop on ack, then one reminder per `p0ReminderMin`. A P0 is only: prod outage on a money path, security incident, data-loss risk, the Mac heartbeat plus brain both unable to self-heal. Cost $0, footprint one extra POST.

**What Ahmad does on the phone (about 10 minutes):**
1. Install the ntfy app (free). Subscribe to the long random topic the OS generates and prints once (stored in Keychain on the Mac and as a brain secret).
2. Android: ntfy app -> Notification channels -> "Max priority": set sound to an alarm tone, enable "Override Do Not Disturb", set volume. iOS: Settings -> Focus -> each Focus you use -> Allowed Apps -> add ntfy and Telegram; Settings -> Notifications -> ntfy -> Sounds: pick the loudest; set Time Sensitive if offered.
3. Telegram: open the @EbdaAIStudiobot chat -> Notifications -> Sound: a distinct loud tone; do NOT mute it.
4. Run the OS drill (`os/ops/phone-drill.sh`, Phase 4): it sends one P0 test with the phone on silent + a Focus on. Pass = Ahmad confirms it rang within 60 s and the Ack button stopped the repeat. If iOS fails the drill, the residual (no true alarm on iOS at $0) is written as a ruling with the cost if wrong, and Ahmad decides whether a paid option is ever worth it.

## 6. The learning loop
Every lesson ends in BOTH halves, in the same session:
- (a) a global memory file in `~/.claude/projects/-Users-ahmadsharaf/memory/` whose body contains the sentinel **"indexed in global MEMORY.md"** and is indexed in the root MEMORY.md (one line per theme);
- (b) an enforcing guard or test in `os/standard/` (+ `os/ops/` script or CI check) picked up by `dream-standard-drift.sh`, citing `sources: <slug>`.
Every AI on this Mac then loads it: Claude sessions and `claude -p` hands via `~/.claude` (installed by `os/install.sh`), Codex via the generated `~/AGENTS.md`. `encode-lesson.sh` drafts the detector; hands open the PR; a lesson with only one half is flagged by the dream cycle as an open finding.

Worked examples from today (memory half exists or is written; guard half is the work):

| Lesson | Guard (enforcing) |
|---|---|
| Bulk `update-branch` burned 50k Actions minutes | `drain.sh` rate cap + test; brain `cost-guard` alarm at 60 % of included minutes; workflow-lint rule: no loop that calls update-branch without a cap |
| A nohup watcher never woke the controller | every watcher posts a brain finding (not a log line); a test asserts each detached loop has a finding path + stop file; heartbeat alarm (section 2) |
| Fail-open ratchet when the base ref was missing in CI | ratchet scripts exit non-zero when the base ref is absent; a test with the base ref deleted must fail; `gate-integrity` standard gets the case |
| Secrets checked at 2 of 3 GitHub levels | one script checks org, repo AND environment secrets (and the org scope `admin:org`), a test with a secret present at only one level; unknown (403) reports "could not check", never "ok" |

## 7. Phases (each ships alone; cost line in each)
| # | Phase | Ships | Exit check (facts) | Cost / month | Footprint |
|---|---|---|---|---|---|
| 1 | Policy | `os/config/delegation.json`, DELEG-1, classifier reads it, table test | test suite exits 0; an unlisted class yields ASK | $0 | none at runtime |
| 2 | Hands on the Mac | launchd hands job with host-lock, progress check, restart cap, fanout-stop, heartbeat | `OS_HANDS_LOCAL=1 install.sh` lists the job; a fake no-progress job stops at the cap; fanout-stop file blocks a spawn; `container list` empty | $0 (Claude Max) | 1 process at a time |
| 3 | Self-recovery | the three runbooks + update-branch cap | drill: set a throwaway repo var, quota-message run reroutes to the Mac and goes green; forced infra-red reruns without a page; a stalled test PR gets a stated cause | $0 | few API calls/hour |
| 4 | Phone | ntfy + repeating Telegram P0, ack button, `phone-drill.sh` | Ahmad confirms ring within 60 s on silent + Focus, ack stops the repeat; repeat count capped in a test | $0 | 1 extra POST per P0 |
| 5 | Nightly update | 8-line digest with orders, fixed, waits + defaults | message <= 8 lines on 3 consecutive nights; unknown source renders "could not check" | $0 | 1 message/day |
| 6 | Learning loop | drift bridge flags one-half lessons; the 4 guards above | each guard's test fails on the old behaviour (mutation check); dream report lists 0 one-half lessons | $0 | weekly dream run |
Total new spend: $0/month. Any step that would cost money stops and becomes an ASK.

## What Ahmad decides (thresholds only)
`maxFilesActAlone`, `maxLinesActAlone`, `moneyPaths`, `realClientTargets`, `spendCapUsd` (default 0), `askDefaultAfterHours`, `mergeStallMin`, `maxUpdateBranchPerHour`, `hands restarts per hour/day`, `usageThresholdPct` (80), `p0MaxRepeats`, `p0ReminderMin`, nightly send time, and the P0 definition list. Everything else the OS decides and reports.

## Residuals (stated, not hidden)
- The Mac is a single point of failure; at $0 the answer is a heartbeat alarm plus a phone ping, not a standby.
- iOS has no true alarm path without a paid or entitlement-gated option; the drill decides.
- ntfy limits and iOS behaviour are inferred and must be proven by the Phase 4 drill before anything depends on them.
