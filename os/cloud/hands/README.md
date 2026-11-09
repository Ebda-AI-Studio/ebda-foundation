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

## Container isolation (ruling F-I8)

- Egress: untrusted commands reach the network only through the root-run allowlist proxy (`lib/egress.mjs`: github.com, api.github.com, codeload.github.com, objects.githubusercontent.com, registry.npmjs.org, api.anthropic.com and the brain host). `entrypoint.sh` adds iptables rules so the unprivileged uids can only talk to loopback, and REFUSES to run (exit 3) if it cannot (`HANDS_EGRESS_REQUIRE_KERNEL=1`, the image default). Not measured on a real Cloudflare Container: `iptables` needs CAP_NET_ADMIN there.
- Egress rules cover IPv4 AND IPv6 (`iptables` + `ip6tables`) for both unprivileged uids; the container exits 3 (and tells the brain, `lib/report-refusal.mjs`, which raises a P1) if either family cannot be locked down, unless the kernel has IPv6 disabled.
- The dependency install runs as `tester` too (the tree is handed to it first), never as Claude's uid, and the unprivileged homes (`.claude`, `.claude.json`, `.npmrc`, shell and git config, `.config`, `.npm`, `.cache`) are wiped and verified empty before and after every job, so a postinstall cannot plant settings or hooks for the next run (N-3).
- Auto-merge also needs `merge-gate.sh --hands` (added by the hands to every gate command): it refuses, exit 2, while a PR-triggered workflow exposes a secret other than `GITHUB_TOKEN` to PR code (a job gated to push events is fine) (I-8).
- Claude Code runs as `node`; the repo's test / format commands run as `tester` (`HANDS_TEST_USER`), so they cannot read Claude's memory or `/proc`.
- Hands PRs run each repo's own CI; checked 2026-11-09 (ebda-store, ebda-whatsapp, ebda-foundation workflows): no workflow exposes deploy secrets to `pull_request` events; the only `secrets.*` on PR-triggered files sit in notify jobs gated to push-to-main.
- Dependency fixes (I-9): only a version bump of an existing dependency to a plain semver range; a new package, URL/git spec or non-registry lockfile host is a PR + question. `lint` / `format` are not pre-approved (M-1).
- `pr-stuck` jobs (ruling F-I5) work on the PR's own same-repo head branch and push a fast-forward to it; they never merge.

## Per job (sequential, one at a time)

1. **Usage guard** (`lib/usage-guard.mjs`, Ruling I-4): read the weekly Claude usage; refuse when it is unknown or at /
   over the threshold (the stricter of the hands threshold and the brain's `USAGE_WEEKLY_THRESHOLD_PCT`). A threshold
   that is not a finite number 1..100 on either side (empty, typo, placeholder) refuses every job: fail closed (I-1).
   A refusal reports `skipped_usage` for this job and every job after it (the brain re-queues them) and ends the run.
   Sources, freshest wins, rules ported from `os/ops/lib/usage_sentinel.py`:
   - `claude-cli`: the `rate_limit_event` the Claude Code CLI prints in `--output-format stream-json`. Measured on CLI
     2.1.317 (2026-11-06): `rate_limit_info.unifiedWindows.seven_day.utilization` is a fraction (0.96 = 96 %), `resetsAt`
     in epoch seconds. Before the first job a one-turn haiku probe reads it; every job's own Claude run refreshes it.
   - `manual` (`$USAGE_STATE/manual.json`, `usage-sentinel.sh calibrate`, ≤ 1 h) and `snapshot` (statusline
     `~/.claude/usage-snapshot.json`, ≤ 15 min): Mac only.
   - The brain's stored report is never read back (an echo would keep a stale number "fresh" forever).
2. **May we work on it?** (`lib/policy.mjs`): destructive / irreversible classes (deletes, prod data writes, purchases,
   secrets, billing) need an explicit `proceed` answer; otherwise nothing runs. A repo without hands config → nothing runs.
3. **Work tree** `<workdir>/<jobId>/work`: shallow clone of the default branch; the base sha is recorded BEFORE Claude
   runs. In the container it is chowned to the sandbox user.
4. **Claude Code** headless (`claude -p … --output-format stream-json`) in the work tree, capped (urgent 30 min,
   nightly 45 min, and the run cap). Prompt (`lib/prompt.mjs`): the finding is fenced as untrusted data; Claude never
   commits, pushes, deploys, touches secrets or changes how tests run. Permissions (`claudePermissionArgs`): Mac =
   `acceptEdits` with `Read/Edit/Write(./**)` (the checkout only), `Glob`, `Grep` and the repo's own test command;
   container = `bypassPermissions` as the unprivileged sandbox user. Both deny edits to `.git/**`, `.github/**`, `.env*`,
   test configs and `package.json` (allowed for dependency bumps only). The permission rules are a first line; the diff
   check (step 9) enforces the same rule on what actually changed.
5. **Commit tree** `<jobId>/commit`: a FRESH clone of the same base sha, made after Claude. Its `.github/workflows` is
   copied to `<jobId>/base-workflows` before anything is applied: the merge gate derives required checks from that
   pristine copy, never from the edited tree (S3).
6. **What changed**: a byte comparison of the work tree against the fresh clone (`lib/tree.mjs`, plain file reads that
   never follow symlinks: the parent dir must still resolve inside the tree, the file is opened `O_NOFOLLOW` and must
   be the inode the walk saw, so a swap by a leftover process is refused (N-2); `.git` and `node_modules` skipped;
   ignored files dropped by the CLEAN tree's rules). Symlinks, special files and files over 5 MB are refused. git is never run in the work tree after Claude (S1).
7. The repo's own `install` + `test` commands (per-repo config, argv arrays, no shell) in the work tree, as the sandbox
   user, with an allowlisted env (no credential at all).
8. **Lint / format classes**: the base version of every changed file is written back and the repo's `format` command is
   run on exactly those files; the result must equal Claude's version byte for byte, else no auto-merge.
9. **Secret scan** of every changed file + the PR title/body: built-in patterns always, gitleaks (pinned in the image)
   when installed. A hit blocks the push (`could_not_fix` + question; the secret is never echoed).
10. The changes are applied to the commit tree; `git add -- <paths>` (explicit), commit, the tree must be clean
    afterwards, push, `gh pr create`. Every hands git call: `core.hooksPath=/dev/null`, `core.fsmonitor=false`,
    `credential.helper=`, `protocol.file.allow=never`, `GIT_CONFIG_NOSYSTEM=1`, an empty `GIT_CONFIG_GLOBAL`.
11. **Merge rule** (bound to the ACTUAL diff, I-2/S2): merge ONLY when the job is `auto-when-gate-green`, its kind is
    pre-approved, AND every changed path fits that kind's allowlist (`lib/diffcheck.mjs`): docs → `*.md`/`*.mdx`/
    `docs/**`; dependency/CVE bumps → manifests + lockfiles, `package.json` only when nothing but dependency fields
    changed; tests → test files only; lint/format → any path, only when step 8 verified it. No changed path may be
    protected (`.github/` incl. CODEOWNERS, `CODEOWNERS`, `.husky/`, `.env*`, wrangler config, migrations, Dockerfile,
    `.gitattributes`, `.npmrc`, and agent instructions: `CLAUDE.md` / `AGENTS.md` / `GEMINI.md` at any depth,
    `.claude/`, `.agents/`, `.cursor/`, `.codex/`, `.cursorrules`, …), listed in the repo's `protectedPaths` (the
    foundation repo: `os/**`, also automatic when the slug equals `OS_REPO_SLUG`), named by the hands' own repo
    commands (e.g. `scripts/ci-test.sh` in `test`), sensitive or destructive by name, or define how tests run
    (`package.json` scripts, test configs, `tsconfig*`, `Makefile`, …). An auto-merged edit to an agent-instruction file
    would steer every later hands run, so those are always a question (N-1). The
    repo needs a `mergeGate` command, the commit tree must still be clean, and the gate (`os/ops/merge-gate.sh`, run
    from the image with `--workflows {base_workflows}`) must exit 0. Anything else: `pr_opened` with a `question:` note
    and the brain sends ONE review question. The gate may overrun the job cap by up to 60 s (it needs a few polls).
12. Report the outcome (`merged | pr_opened | could_not_fix | timed_out | skipped_usage`) and the usage reading. The job
    dir is removed; a crash is swept on the next start (`job_*` dirs only) and on SIGTERM/SIGINT.

### Credentials (S1/S4)

| Credential | Who gets it | How |
|---|---|---|
| `GH_TOKEN` | `git clone` / `fetch` / `push` | per-job `GIT_ASKPASS` helper in a root-only private dir, token in that one process's env |
| `GH_TOKEN` | `gh pr create`, the merge gate | that one process's env, cwd = the private dir, `--repo` explicit |
| `CLAUDE_CODE_OAUTH_TOKEN` | Claude Code (container) | file descriptor 3 (`CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR=3`), never its env; `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1` |
| none | the repo's install / test / format, Claude's own tools | allowlisted env (`PATH`, locale, `TMPDIR`, `HOME`, …) |

Container: the hands run as root and every untrusted command runs as `node` through `setpriv`, so it cannot read the
hands' `/proc/<pid>/environ`, the askpass dir or the commit tree. **Mac residual** (Ruling 4b-5): no second user, so a
same-uid process (the repo's tests, which Claude may have edited) could read `OS_SERVICES_ENV` or the hands' env; the Mac
keeps Claude to file tools in the checkout plus the test command, and a fix that touches test-defining files is never
merged. Until the container path is live, the Mac runner is pointed only at repos whose findings carry NO third-party
text (no advisory bodies, issue or PR text from outside): the exposure is `ps eww` / `OS_SERVICES_ENV` to same-uid
code. `CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR` comes from the CLI's own env list (2.1.317); it is NOT VERIFIED with a
real token until the first container run (a wrong guess fails loudly: every job `could_not_fix: claude failed`).

## Files

| Path | What |
|---|---|
| `run-batch.mjs` | CLI: `--run <runId>` (container), `--claim [--max N]` (Mac), `--dry-run --fixture <file>` |
| `lib/job.mjs`, `lib/run.mjs` | one job end to end; the sequential run loop |
| `lib/usage-guard.mjs`, `lib/policy.mjs` | the two refusal rules (usage; merge/destructive) |
| `lib/config.mjs` | per-repo config (`os/config/hands.example.json`), from `HANDS_CONFIG_FILE` or `HANDS_CONFIG_JSON` |
| `lib/exec.mjs` | spawn without a shell, cap kills only the process group it started; a cap of 0 = already expired; `fd3` for a secret |
| `lib/tree.mjs`, `lib/git.mjs`, `lib/diffcheck.mjs` | work-vs-fresh-clone diff; git/credential/sandbox hygiene; per-kind path allowlists + secret scan |
| `claude-cli/` | `package.json` + `package-lock.json` pinning Claude Code by version and sha512 integrity (`npm ci` in the image) |
| `lib/dry-run.mjs`, `fixtures/batch.json` | scripted leaves for `--dry-run` (no network, Claude, git remote or gh) |
| `providers/` | `cloudflare-sandbox` (default from Task 7), `mac-local` (pull-only), `github-actions` (disabled); `index.mjs` selects by `HANDS_PROVIDER`. Worker-compatible: the brain bundles them. |
| `providers/mac-local.sh`, `providers/launchd/com.ebda.os.hands-mac-local.plist` | Mac runner + launchd template (installed by Task 5) |
| `Dockerfile`, `entrypoint.sh`, `Dockerfile.dockerignore` | the container image (context = `os/`) |
| `scripts/check-dockerfile.mjs` | engine-free Dockerfile checks (CI) |

The container side of `cloudflare-sandbox` is `os/cloud/brain/src/hands-container.ts` (`HandsContainer` DO): one
instance per lane (`hands-nightly`, `hands-urgent`), 409 when busy (recorded by the brain as a failed run), credentials
passed as env at start, the cap state + a 1-minute alarm are written BEFORE the container starts; the alarm keeps the
instance alive and destroys it at cap + 5 min.

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
   (the bot identity commits are authored as; use the token owner's noreply address). Add a `format` argv (with
   `{files}`) for repos where lint/format fixes may auto-merge, and point `mergeGate --workflows` at `{base_workflows}`
   (config validation rejects a gate that reads `{dir}`).
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
