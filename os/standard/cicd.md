# cicd — CI/CD & Workflow File Rubric

tags: [BOTH]
sources: PLAYBOOK §6, CLAUDE.md (Rule 15 — CI/CD + workflow file standard), reference-iceberg-audit.md (term 27: CI/CD)

## What "solid" looks like
Every repo's `.github/workflows/` converges to one canonical shape: a `ci.yml` with a top-level concurrency group that cancels superseded runs; `timeout-minutes` on every job; Prisma `db:generate` before typecheck; a split audit gate (prod zero-tolerance, dev gated at high); a sleep-proof `notify-failure` Telegram job that always stays on cloud; a gitleaks all-branch secret scan paired with allowlist files; clean branch hygiene; runner routing that defaults to cloud with a non-input override; and a pre-push hook mirroring a CI subset.

## Criteria
| # | Criterion | Solid (grade 2) | Gap detection | Severity |
|---|---|---|---|---|
| 1 | Top-level concurrency group | `ci.yml` has a top-level `concurrency:` block with `cancel-in-progress: true` so superseded pushes don't pile up | grep `.github/workflows/ci.yml` for a top-level `concurrency:` key AND `cancel-in-progress: true` | Medium |
| 2 | `timeout-minutes` on every job | Every job has a `timeout-minutes` (caps: lint=5, typecheck=10, build=15, unit=10, integration=15, E2E=20, audit=5) — anti-hang for leaked jest/vitest timers | grep workflows for each `jobs.<name>:` block lacking a `timeout-minutes:` key | High |
| 3 | Prisma `db:generate` before typecheck | The `db:generate` (prisma generate) step runs BEFORE the typecheck step, else tsc reports ~396 phantom errors from missing `@prisma/client` types | grep the typecheck job; confirm a `prisma generate`/`db:generate` step appears earlier in the same job (or as a needs-dependency) | High |
| 4 | Audit gate split | Prod zero-tolerance `npm audit --audit-level=low --omit=dev`; dev gated at high (unfixable transitive tooling vulns) | grep workflows for `npm audit`; confirm both an `--omit=dev --audit-level=low` invocation AND a separate dev `--audit-level=high` invocation | High |
| 5 | `notify-failure` Telegram job | A `notify-failure` job fires Telegram via `TELEGRAM_BOT_TOKEN` + `TELEGRAM_ALERT_CHAT_ID` on `failure() && main && push`; stays on `ubuntu-latest` even when everything else is self-hosted (fail-open) | grep workflows for a `notify-failure` job with `if:` containing `failure()` + Telegram secret names; confirm its `runs-on: ubuntu-latest` is unconditional | High |
| 6 | gitleaks all-branch scan + allowlist | gitleaks workflow scans ALL branches with `fetch-depth: 0`, paired with `.gitleaks.toml` (allowlist) + `.gitleaksignore` (documented false positives) | file-exists `.gitleaks.toml` AND `.gitleaksignore`; grep the gitleaks workflow for `fetch-depth: 0` | Critical |
| 7 | Branch hygiene | Only `main` (+ `preview` if staging active); no `test-*`/`staging`/`vercel/*` orphans — orphan branches with old creds trip the gitleaks all-branch scan even after main is scrubbed | `git branch -r` and confirm no branches outside `main`/`preview`; flag any `test-*`/`staging`/`vercel/*`/`auto-fix/*` orphan | Medium |
| 8 | Runner routing with non-input default | `runs-on` keyed on the repo variable `vars.EBDA_RUNS_ON` (not `inputs.force_cloud` alone), falling back to `ubuntu-latest` when unset, so push/PR events follow the owner's routing; `workflow_dispatch force_cloud` overrides per-run | grep `runs-on:` expressions; confirm they reference `vars.EBDA_RUNS_ON`, not `inputs.force_cloud` as the sole determinant | High |
| 9 | Pre-push hook mirrors CI subset | A pre-push hook runs lockfile-drift check + prisma generate + lint + typecheck + unit tests to catch issues 90s before burning runner minutes | file-exists `.husky/pre-push` (or `.git/hooks/pre-push`); grep it for lockfile-drift + `prisma generate` + lint + typecheck + unit steps | Medium |
| 10 | Merge captures all branch commits | Push the LAST commit before announcing "ready"/merging (a merge snapshots origin at merge-time; later/post-squash commits silently drop); one topic per branch; after any squash/merge verify `git show --stat <merge-sha>` covers `origin/main..origin/<branch>` | a merged PR with commits remaining in `origin/main..origin/<branch>` = dropped-commit gap | Medium |
| 11 | Graphify artifacts tracked convergently | Track ONLY the 3 canonical artifacts (`graph.json`/`GRAPH_REPORT.md`/`graph.html`) via a gitignore whitelist; `git rm --cached` manifest/.graphify_root/cache; regenerate only when HEAD moved or source is dirty (convergence marker) — graphify output is non-deterministic (manifest mtimes + embedded build-commit self-chase) so scheduled auto-commit churns forever | grep `.gitignore` for the whitelist; flag tracked `manifest.json` or unconditional scheduled regen | Medium |

| 12 | Service readiness proves YOUR process, not the port | A readiness/health gate must fail the job when the bind fails, and assert on something only this build serves (commit id, started PID) — a bare `curl localhost:<port>/health` passes when an unrelated leftover process answers, so the job proceeds against the wrong service | grep readiness steps for a bind-failure check; flag any poll whose only assertion is HTTP 200 on a fixed port | High |

| 13 | No fixed host ports in service containers | A job that maps `ports: ['5432:5432']` cannot run twice at once on one host; with multiple runner instances per repo, a second run of the SAME workflow collides ("failed to set up container networking"). Map `ports: ['5432']` and read `${{ job.services.<id>.ports['5432'] }}`; never leave a hardcoded port in job-level `env` as a fallback, which would silently point steps at whichever run owns it | grep workflows for `NNNN:NNNN` under `services:` | High |
| 14 | Runtime `apt-get` is lock-safe | On a multi-runner host, concurrent jobs race for `/var/lib/dpkg/lock-frontend`; a losing job can fail AFTER doing its real work (a db-backup dumped successfully, then died installing rclone, so the backup never uploaded). Pre-install on the guest and guard with `command -v <tool> ||`, and pass `-o DPkg::Lock::Timeout=600` | grep workflows for `apt-get install` without a `command -v` guard or a lock timeout | High |

## Action pinning lives in `standard/supply-chain.md`
Every `uses:` must be a commit SHA, gated by `ops/pin-actions.sh --check`. It is a separate
lens because it is a provenance concern, not a workflow-shape concern: a perfectly shaped
workflow that floats on `@v4` still executes whatever the action's owner pushes next.

## Evidence (filled during audit, per repo)
- a previous storefront product: …
- an earlier messaging product: …

## Merge-automation safety (added 2026-06-08, learned the hard way)

Any automated or admin merge that BYPASSES a failing check (`gh pr merge --admin`, merge-on-green helpers) MUST first read the failing checks and **REFUSE if a security check is failing** — `gitleaks`, Semgrep/SAST, secret scan, ZAP, CodeQL, dependency audit. Those require a real fix (or a verified, scoped allowlist), never a bypass. Only an *infra-flake* failure unrelated to the change (e.g. an expired-token gate) may be admin-merged, and only with explicit human approval. Enforce with `ops/safe-to-admin-merge.sh <repo> <pr>` (exit 1 = security failing = refuse). Origin: a docs PR was admin-merged past a failing `gitleaks` on assumption it was the unrelated Vercel-token gate (it turned out to be a pre-existing public anon key — no harm, but the bypass was wrong).

**After every merge: tear down the worktree.** A PR developed in a `git worktree` leaves a dead worktree+branch behind once merged. Immediately run `ops/post-merge-cleanup.sh <owner/repo> <pr>` — safe to call unconditionally; it self-refuses unless the PR is genuinely MERGED, the tree is clean, and nothing is unpushed (4 squash-merge-aware gates). This is the source-level fix for the zombie-branch / root-owned-leftover pileup that `EACCES`-es self-hosted runners. Full lifecycle + the common-test-files preservation rule: `standard/worktree-lifecycle.md` + `standard/common-test-files.md`.

**`pr-shepherd.sh` — the CI/CD closed loop for open PRs (born 2026-07-12).** Pure `gh`
API, zero LLM tokens, scheduled every 20 min (`com.ebda.os.pr-shepherd`). Per open PR it
does six moves, each a real incident that used to cost a manual session: **HEAL** —
rerun jobs infra killed (OOM `exit 137`, disk-full, lost-runner; max 2 reruns per
`(pr, head-sha)`, ledger-tracked at `~/.whisky-os-state/pr-shepherd-ledger.json`), rerun
a head whose latest required run was CANCELLED and never re-ran, `gh pr update-branch`
when a green PR is merely behind main, and resolve unresolved AI-review threads ONLY
when the review check on the CURRENT head is SUCCESS (an advisory re-post is not a
real finding). **SHIP** — squash-merge when not draft, all checks green, no unresolved
threads, and the branch isn't `auto-fix/*` or `dream-fix/*` (those fleets own their own
merge policy / `DREAM_AUTOMERGE` gate — pr-shepherd never overrides them). **ALERT** —
a genuine content failure (real red, not an infra signature) gets ONE Telegram per
`(pr, head)` naming the failing jobs; it never blind-reruns a content failure. Same
security-gate discipline as `safe-to-admin-merge.sh` applies: it only unblocks
infra-flake noise, never bypasses a failing security/lint/test check.

## CI runner guard (native Mac runner fleet health)
CI runs ONLY on native macOS GitHub runners (Ebda-AI-Studio: `ebda-mac-1/2` label `ebda-mac` heavy,
`ebda-mac-light-1/2` label `ebda-mac-light`). Repos route to them through the repo
variable `EBDA_RUNS_ON` (`["self-hosted","ebda-mac"]`) and fall back to `ubuntu-latest` when it is unset. Umbra, the old
local Linux CI VM, was retired 2026-11-14 (`docs/RULINGS.md` Ruling UMBRA-RETIRE-1).

`ops/ci-runner-guard.sh` (launchd `com.ebda.os.ci-runner-guard`, every 30 min, and on demand) judges fleet health from
the GitHub API only: `gh api orgs/<org>/actions/runners` per org in `RUNNER_ORGS` (default: the primary org).
- Every runner of the org offline, or every runner carrying one label offline (e.g. all `ebda-mac` heavy runners while
  `ebda-mac-light` is up) -> a finding: exit 1, one `notify.sh` page, `runner-status.json` warn.
- Some runners offline, or all busy -> a note only (busy is normal under load).
- An unreadable runner list (API failure, missing `admin:org` scope) is UNKNOWN, never "all offline": it is noted as
  not evaluated and does not page.
- Host disk >= `HOST_DISK_CRIT_PCT` (94) is a finding, >= `HOST_DISK_WARN_PCT` (88) a note: a full Mac disk fails jobs.
- Every `gh` call is wall-clocked through `_ut` (lib/os-state.sh): a monitor that can block on what it monitors goes
  quiet, and quiet reads as healthy.

## Main-first CI (starved main run)
GitHub does not schedule self-hosted jobs FIFO across runs, so many builder PRs can hold both heavy runners
(`self-hosted` + `ebda-mac`) while the main-branch CI run sits `queued` for hours. A red/pending main stops the store
merge drain (only fixes-main PRs merge), so every other approved PR stalls. Measured 3x on 2026-11-14.

`ops/main-first.sh` (launchd `com.ebda.os.main-first`, every 5 min; `--dry-run` supported; log
`~/Library/Logs/ebda-main-first.log`; ledger `~/.whisky-os-state/main-first/`) automates the controller's manual fix,
per repo in `MAIN_FIRST_REPOS` (default ebda-store, ebda-whatsapp, ebda-foundation). When the NEWEST main `CI` run is
queued/in_progress and one of its jobs has been queued longer than `MAIN_FIRST_MIN` (10) minutes:
1. cancel older main CI runs whose head is an ancestor of the newest main head (compare API);
2. cancel QUEUED `pull_request` runs with a queued job asking for `MAIN_FIRST_LABEL` (`ebda-mac`) - never in_progress
   runs, never a branch in `MAIN_FIRST_ALLOW_BRANCHES`, never a PR labelled `fixes-main`; one PR comment per head;
3. when the newest main CI run completes `success`, re-request each cancelled run once (approved PRs first, oldest
   approval first, `MAIN_FIRST_RERUN_CAP` (2) per tick); a closed PR or a moved head is dropped (the push already
   started a fresh run); ledger entries expire after 24 h. A red main re-runs nothing.
All reads happen before any cancel; a 5xx/504 or unparsable response skips the repo for that tick. Tests:
`ops/tests/main-first.test.sh` (fake `gh`).
The guard only REPORTS; it never starts, stops or rebuilds anything. The runners are launchd services on the Mac
(`actions.runner.<org>.<name>`): restart one with `launchctl kickstart -k gui/$(id -u)/actions.runner.<org>.<name>`.
It does not flip routing variables: routing is the owner's `EBDA_RUNS_ON` decision.
Tests: `ops/tests/ci-runner-guard.test.sh` (fake `gh`: healthy, all-offline, one dead label pool, API failure,
multi-org, host disk).

## Self-hosted post-job hook MUST be best-effort (never fail a job) — 2026-06-11
A GitHub Actions self-hosted runner can run a hook after every job via the runner's
`.env`: `ACTIONS_RUNNER_HOOK_JOB_COMPLETED=/home/<user>/runner-hooks/post-job-cleanup.sh`.

**The trap (cost us a long session):** if that hook exits non-zero, GitHub fails the
job at the **"Complete runner"** step — *after* every real step (lint, build, gitleaks,
semgrep, npm-audit, tests) already succeeded. Every required check then shows red for
an infra reason unrelated to the PR, so **green code can't merge**. A broken hook
silently blocked EVERY PR on two repos (a
`docker prune` / root-owned-file `rm` hitting EACCES made it exit 1 ~once per run).

**The rule:** a post-job hook is best-effort housekeeping and must **never** red a job.
Canonical shape: `template/runner-hooks/post-job-cleanup.sh` — `set +e`, run the host's
real cleanup with `|| true`, and **always `exit 0`**. Keep real logic in a sibling
`post-job-cleanup.real.sh` so the "never fail" guarantee can't be edited away.

**Install / repair (on the Mac runner host):** open the runner's `.env` (`ACTIONS_RUNNER_HOOK_JOB_COMPLETED=...`),
read the hook and its exit code so we learn *why* it failed, not just mask it, make it follow the canonical shape above
(`set +e`, `|| true`, `exit 0`), then restart that runner's launchd service. The hook is read fresh per job.

**Detection (OS, reactive):** `ops/runner-hook-health.sh [--notify]` reads recent CI
runs across Force repos and flags the signature *job failed but only the cleanup /
"Complete runner" step failed — every real step passed*, then alerts with the one-line
fix. Complements `ci-runner-guard.sh` (that judges whether runners are online; this
handles a broken self-hosted post-job hook). **Scheduled** via launchd
`com.ebda.os.runner-hook-health` every 3h (`--notify`), alongside
`com.ebda.os.ci-runner-guard` (both runtime copies in `~/.claude/scripts`, plist
templates in `ops/launchd/`, deployed by `ops/install.sh`).

**Merge implication:** when CI is red ONLY because of this signature (verify each
required check's *inner* steps: the real scan/lint/test step succeeded, only "Complete
runner" failed), it is an infra-flake — `safe-to-admin-merge.sh` reasoning applies and
an admin-merge is acceptable *with explicit human OK*, because no real security or code
gate is failing. Never admin-merge when a real scan/lint/test step itself failed.

## Self-hosted runner hygiene — never leave a process behind (2026-08-19)

**Rule: no manually-started, long-lived process may outlive the shell that started it on a
shared or CI runner.** If you must run a service on the guest to verify something, bind a
**non-CI port** and tear it down in the same command, so an interrupted session cannot orphan it:

```bash
( node server.js & pid=$!; trap "kill $pid" EXIT; run-checks )   # dies with the shell
timeout 300 node server.js                                       # or a hard ceiling
```

**Why this is High severity.** A leftover listener on a well-known port makes CI fail in a way
that is *indistinguishable from a code regression* and *persists across runs and commits*:

1. CI starts its own service → the bind fails, but the step does not treat that as fatal.
2. CI polls `/health` on that port → **200 OK, from the leftover process**.
3. CI's tests write to the service-container DB; requests are served by the leftover process
   pointed at a different DB → auth/lookup failures everywhere, with a green readiness step.

a previous storefront product 2026-08-19: a hand-started `apps/api` on port 4000 (pointed at a local postgres, not the
service container) produced `INVALID_CREDENTIALS` across 12 integration files on users the tests
had just created. Killing it turned CI green on the next run with **no code change**.

**Diagnostic — run this before reading any diff when CI was green yesterday and is red today
with no relevant change:**

```bash
ss -lptn 'sport = :<ci-port>'                        # who holds it
ps -o pid,lstart,etime,cmd -p <pid>                  # started before the job? not CI's
tr '\0' '\n' < /proc/<pid>/environ | grep -E 'DATABASE_URL|PORT'
docker ps --format '{{.Names}}\t{{.Ports}}\t{{.RunningFor}}'
```

A listener whose uptime predates the job is contamination, not CI. **Leave containers you did not
create alone.** Reproducing CI's exact command by hand and getting a pass is the signal to stop
reading the diff and start inspecting the runtime.

### The runner host's disk is a fleet-wide single point of failure (2026-08-23)

A CI host that reaches 0 bytes free takes every runner offline at once (they lose their GitHub session and
do not recover on their own), and runs sit queued with nothing watching. Two rules:

1. **Adding runner instances adds disk, not just concurrency.** Budget `instances x workspace size` before scaling a
   fleet - a repo with a large `node_modules` costs 2-3 G *per instance*.
2. **Watch the CI host's disk.** `ci-runner-guard.sh` reads the Mac's data volume every cycle (note at 88%, finding
   at 94%); `workspace-hygiene.sh` removes merged worktrees hourly and alerts below 30 GB free. An unreadable disk
   reads as **unknown**, never 0%.

sources: stray-process-on-shared-runner-poisons-ci

### A shared runner host turns every per-job resource into a contended one (2026-08-23)

Scaling a runner host from 6 to 18 instances bought throughput and three outages. Each was a
shared resource that simply was not contended at 6 instances:

- **Disk** — 18 × ~2.5 GB of `_work` filled a 58 GB disk to **0 bytes**; the whole fleet went
  offline. Budget `instances x workspace size` before adding instances.
- **The dpkg lock** — a nightly `db-backup` dumped the database successfully and *then* failed
  installing `rclone`, so the backup never uploaded. A DR job that fails at the last step is worse
  than one that fails early: the log shows a successful dump.
- **Fixed host ports** — a second concurrent run of the *same* job could not bind `5432:5432`.

**When reclaiming `_work`, keep `_work/_tool`.** It is the toolchain cache (~400 MB of Node per
runner) and is not what fills the disk. Wiping it makes every later job re-download its toolchain;
under contention that pushed a lint job past its cap with `Setup Node.js` alone taking 14m46s —
which reads as a lint failure and is not one.

**Before adding runner instances, ask what each concurrent job takes and holds**: disk,
package-manager locks, fixed ports, shared venvs, `~/.npm`. Concurrency is the cheap part.

sources: runner-fleet-scaling-costs-disk-and-locks

## The gate must bind to the SHIPPED artifact, not to a build (2026-09-04)

Learned on the course-platform build; sibling of `feedback-partial-deploy-from-per-workflow-drift`.

- **CI gated one build and shipped another.** A `build-gate` job built the app and asserted no paid
  content appeared in the output. The deploy job then ran `npm run deploy`, which **rebuilds** and
  never re-runs the assertion. Two builds, one asserted, the other uploaded — and nothing in the run
  said so. Verified at the strongest available level by reading the deploy tool's installed source:
  its `deploy` command never calls `build`.
- **Put the gate inside the deploy command, not beside it in the YAML.** The fix was
  `"deploy": "build && assert && deploy"` in `package.json`, so all three links share one output
  directory and the asserted bytes **are** the uploaded bytes. In the npm script rather than the
  workflow, because a laptop deploy must be gated too — and because the drift between the two was
  itself the defect.
- **A skipped job skips its dependents.** Once the gate moved into the deploy script, `build-gate`
  became PR-only. Leaving `needs: [build-gate]` on the deploy job would have **skipped every
  production deploy**, silently and greenly. Check every `needs:` edge whenever a job's trigger
  changes. (`always()` on a notify job still fires; `failure()` ignores a skipped dependency.)
- **Every gate needs a one-word entry point or it does not get run.** A typecheck failure gated both
  the PR and the deploy while three consecutive reports cited `test` and `lint` and never `tsc`. Root
  cause was not the version pin that broke it — it was that typecheck had no `npm run typecheck`
  beside `npm test` and `npm run lint`. **The gate nothing reported is the one that was red.**
- **A gate is proved failable by leaking, not by reading YAML.** Plant a real violation of each arm,
  confirm a non-zero exit that NAMES the offending file, restore, confirm zero.


## Merge gate + gate scope (2026-10-25)
A PR is merged only through `ops/merge-gate.sh` (zero checks is never green; head pinned; explicit required checks
derived from the workflows; 3 consecutive polls) - `merge-gate.md`. Secret scans on `pull_request` scan the PR's own range, full
history on `main` + nightly; perf/startup gates compare to a same-job `main` baseline, never an absolute budget; status probes
target seeded resources and assert a page marker. sources: `ci-merge-gates-never-merge-on-no-checks`.
