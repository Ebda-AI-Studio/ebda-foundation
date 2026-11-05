# Ebda OS hands

The part of Ebda OS that writes fixes (Amendment A + A.1). The brain (`os/cloud/brain/`) notices, classifies and queues;
the hands pull a batch, fix each job with Claude Code headless, open PRs, merge only what they are allowed to, report
every outcome back, and exit. Nothing here runs on GitHub Actions: Actions minutes are for CI only.

```
brain cron 21:30 UTC (nightly, 1/day) ─┐                          ┌─ GET  /hands/runs/:id      (the batch)
brain urgent dispatch (≤3/day, 1 at a  ├─► provider.start(batch) ─► run-batch.mjs ─┼─ POST /hands/jobs/:id/outcome
time, 30-min cap)                      ┘   (container or Mac)                    └─ POST /hands/usage
Mac awake (launchd, every 30 min) ──────► run-batch.mjs --claim ──► POST /hands/claim (same usage guard)
```

## Per job (sequential, one at a time)

1. **Usage guard** (`lib/usage-guard.mjs`, Ruling I-4): read the weekly Claude usage; refuse when it is unknown or at /
   over the threshold (the stricter of the hands config and the brain's `USAGE_WEEKLY_THRESHOLD_PCT`). A refusal reports
   `skipped_usage` for this job and every job after it (the brain puts them back in the queue) and ends the run.
   Sources, freshest wins, rules ported from `os/ops/lib/usage_sentinel.py`:
   - `claude-cli`: the `rate_limit_event` the Claude Code CLI prints in `--output-format stream-json`. Measured on CLI
     2.1.317 (2026-11-06): `rate_limit_info.unifiedWindows.seven_day.utilization` is a fraction (0.96 = 96 %), `resetsAt`
     in epoch seconds. Before the first job a one-turn haiku probe reads it; every job's own Claude run refreshes it.
   - `manual` (`$USAGE_STATE/manual.json`, `usage-sentinel.sh calibrate`, ≤ 1 h) and `snapshot` (statusline
     `~/.claude/usage-snapshot.json`, ≤ 15 min): Mac only.
   - The brain's stored report is never read back (an echo would keep a stale number "fresh" forever).
2. **May we work on it?** (`lib/policy.mjs`): destructive / irreversible classes (deletes, prod data writes, purchases,
   secrets, billing) need an explicit `proceed` answer; otherwise nothing runs. A repo without hands config → nothing runs.
3. Fresh shallow clone of the default branch into `<workdir>/<jobId>`, branch `os/fix-<jobId>`.
4. Claude Code headless (`claude -p … --output-format stream-json`) with the task prompt (`lib/prompt.mjs`: the finding
   is fenced as untrusted data; Claude never commits, pushes, deploys or touches secrets), capped at the job's wall-clock
   cap (urgent 30 min, nightly 45 min) and the run cap. Claude's env has no `GH_TOKEN` / `HANDS_TOKEN`.
5. The repo's own `install` + `test` commands from the per-repo config (argv arrays, no shell, no credential in their env).
6. Commit only the files Claude changed (explicit paths, never `-A`, never `--no-verify`), push, `gh pr create`.
7. **Merge rule** (4a carried requirement 2; the brain accepts any outcome, so it lives here): merge ONLY when the job is
   `auto-when-gate-green`, its kind is pre-approved (dependency / CVE bumps, docs, tests, lint, flaky), nothing it
   touches is destructive or sensitive, it changed no protected path (workflows, `.env*`, wrangler config, migrations,
   Dockerfile), the repo has a `mergeGate` command, and that gate exits 0 (`os/ops/merge-gate.sh`: N green polls,
   head-pinned). Anything else: `pr_opened` with a `question:` note, and the brain sends ONE review question.
8. Report the outcome (`merged | pr_opened | could_not_fix | timed_out | skipped_usage`) and the usage reading.

A run also has a wall-clock cap (`runCapMin`, nightly 90; urgent = the job cap): jobs it does not reach go back as
`skipped_usage`.

## Files

| Path | What |
|---|---|
| `run-batch.mjs` | CLI: `--run <runId>` (container), `--claim [--max N]` (Mac), `--dry-run --fixture <file>` |
| `lib/job.mjs`, `lib/run.mjs` | one job end to end; the sequential run loop |
| `lib/usage-guard.mjs`, `lib/policy.mjs` | the two refusal rules (usage; merge/destructive) |
| `lib/config.mjs` | per-repo config (`os/config/hands.example.json`), from `HANDS_CONFIG_FILE` or `HANDS_CONFIG_JSON` |
| `lib/exec.mjs` | spawn without a shell, cap kills only the process group it started |
| `lib/dry-run.mjs`, `fixtures/batch.json` | scripted leaves for `--dry-run` (no network, Claude, git remote or gh) |
| `providers/` | `cloudflare-sandbox` (default from Task 7), `mac-local` (pull-only), `github-actions` (disabled); `index.mjs` selects by `HANDS_PROVIDER`. Worker-compatible: the brain bundles them. |
| `providers/mac-local.sh`, `providers/launchd/com.ebda.os.hands-mac-local.plist` | Mac runner + launchd template (installed by Task 5) |
| `Dockerfile`, `entrypoint.sh`, `Dockerfile.dockerignore` | the container image (context = `os/`) |
| `scripts/check-dockerfile.mjs` | engine-free Dockerfile checks (CI) |

The container side of `cloudflare-sandbox` is `os/cloud/brain/src/hands-container.ts` (`HandsContainer` DO): one
instance per lane (`hands-nightly`, `hands-urgent`), 409 when busy (recorded by the brain as a failed run), credentials
passed as env at start, a 1-minute alarm keeps the instance alive and destroys it at cap + 5 min.

## Providers

| `HANDS_PROVIDER` | Starts | Notes |
|---|---|---|
| `stub` (committed default) | nothing | records the run only; stays until Task 7 |
| `cloudflare-sandbox` | one container per batch | brain nightly cron + urgent dispatch only; needs the Task 7 containers block, else every start is a recorded failed run |
| `mac-local` | nothing (pull-only) | the Mac claims queued nightly work; urgent jobs are queued for it with one message |
| `github-actions` | a `workflow_dispatch` | refused (stub) unless `HANDS_GITHUB_ACTIONS_ENABLED=true` + repo + workflow + token; no workflow ships. Do not enable: Actions minutes are CI only. |

A provider that throws never aborts the brain tick: the run is recorded `failed`, the jobs stay queued, and an urgent
job retried this way counts toward the 3/day cap (then goes to tonight's batch with one message).

## Frugality (Workers Paid included: 25 GiB-h memory, 375 vCPU-min active CPU, 200 GB-h disk per month)

Instance `standard-1` (1/2 vCPU, 4 GiB, 8 GB disk; `basic` at 1 GiB is too small for Claude Code + `npm ci` + tests,
inferred). Memory and disk bill on provisioned size while running; CPU on active use only (Cloudflare docs, 2025-11-21).
Rates: $0.009 per GiB-h, $0.0012 per vCPU-min, $0.00025 per GB-h. All figures below are ESTIMATES, not measurements.

| Run | Wall time | Memory | Active CPU (~30 % of 1/2 vCPU) | Disk |
|---|---|---|---|---|
| Typical night (3 jobs × ~12 min + ~2 min boot/probe) | ~40 min | 2.7 GiB-h | ~6 vCPU-min | 5.3 GB-h |
| Worst night (90-min run cap) | 90 min | 6 GiB-h | ~14 vCPU-min | 12 GB-h |
| One urgent run (30-min cap + boot) | ≤ 35 min | ≤ 2.3 GiB-h | ≤ 5 vCPU-min | ≤ 4.7 GB-h |
| Month, typical (30 nights + ~2 urgent) | ~21 h | ~86 GiB-h (61 over → ~$0.55) | ~190 (inside 375) | ~170 GB-h (inside 200) |
| Month, worst (90-min nights + 3 urgent/day) | ~97 h | ~390 GiB-h (~$3.30 over) | ~870 (~$0.60 over) | ~780 GB-h (~$0.15 over) |

Memory is the binding limit: the included 25 GiB-h cover ~6 h of `standard-1` a month (~12 min a night). An empty queue
starts nothing. Egress (clones, npm) is not estimated here. GitHub Actions minutes used by the hands: 0.

## Develop

```bash
cd os/cloud/hands
npm ci
npm test                                              # vitest, every leaf mocked
npm run dry-run                                       # fixture walk end to end, no network
npm run lint:dockerfile                               # engine-free Dockerfile checks
```

CI: job `hands` in `.github/workflows/ci.yml` (only when `os/cloud/**` or `os/config/hands.example.json` changes on a
PR; always on main). It builds no image.

Optional local image build (needs an engine; nothing is pushed): `docker build -f os/cloud/hands/Dockerfile --platform
linux/amd64 -t ebda-os-hands:local os && docker run --rm --entrypoint claude ebda-os-hands:local --version`, then
`docker image rm ebda-os-hands:local`.

## Runbook (controller, Task 7; nothing here has been run)

All on the personal Cloudflare account. Never put a token or id in the repo or the image.

1. **Claude Code token** (long-lived, Max plan): on the Mac, `claude setup-token` and copy the printed token. Then
   `cd os/cloud/brain && CLOUDFLARE_ACCOUNT_ID=$OS_CF_ACCOUNT_ID npx wrangler secret put CLAUDE_CODE_OAUTH_TOKEN --config wrangler.deploy.jsonc`.
2. **GitHub token**: one fine-grained PAT per org the hands work in (resource owner = that org), repository access =
   only the repos listed in the hands config, permissions **Contents: read and write** + **Pull requests: read and
   write** (+ Metadata read, automatic). Nothing else (no Actions, no admin, no secrets). Expiry ≤ 90 days, calendar the
   rotation. Store as `HANDS_GH_TOKEN` the same way. (More than one org = more than one token; until a per-org split
   exists, start with the one org whose repos are in the config.)
3. **Repo config**: write the per-repo config (shape `os/config/hands.example.json`; every repo needs its own `test`
   command; add `mergeGate` only for repos whose merge gate should be allowed to merge pre-approved classes) and store
   it: `wrangler secret put HANDS_CONFIG_JSON < ~/.ebda-os.hands.json`. Also `HANDS_GIT_NAME` and `HANDS_GIT_EMAIL`
   (the bot identity commits are authored as; use the token owner's noreply address).
4. **Container block** in `os/cloud/brain/wrangler.jsonc` (and redeploy with `scripts/deploy.sh`):
   ```jsonc
   "containers": [{ "class_name": "HandsContainer", "image": "../hands/Dockerfile", "image_build_context": "../..",
                    "instance_type": "standard-1", "max_instances": 2 }],
   // durable_objects.bindings += { "name": "HANDS_CONTAINER", "class_name": "HandsContainer" }
   // migrations += { "tag": "v2", "new_sqlite_classes": ["HandsContainer"] }
   ```
   `image_build_context` is `os/` (relative to the brain dir), so `ops/merge-gate.sh` is in the image. Then set
   `"HANDS_PROVIDER": "cloudflare-sandbox"`. `HANDS_BRAIN_URL` is rendered from `OS_BRAIN_HOST` by `deploy.sh`.
5. **Verify**: `wrangler deploy --dry-run` passes; the dashboard shows the next nightly run with provider
   `cloudflare-sandbox`; the first run's outcomes arrive (a `failed` run with "missing secrets/vars: …" names what is
   unset). Read the container logs in the dashboard; confirm one container per night in the Containers usage page.
6. **Mac fallback** (Task 5): add `BRAIN_URL`, `HANDS_TOKEN`, `GH_TOKEN`, `HANDS_GIT_NAME`, `HANDS_GIT_EMAIL` to
   `OS_SERVICES_ENV`, the repo config to `~/.ebda-os.hands.json`, and install
   `providers/launchd/com.ebda.os.hands-mac-local.plist` (placeholders `__HOME__`, `__PATH__`, `__OS_HOME__`).

Rollback: set `HANDS_PROVIDER` back to `stub` and redeploy; queued jobs wait, nothing is lost.
