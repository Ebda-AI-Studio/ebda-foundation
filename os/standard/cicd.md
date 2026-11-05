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
| 8 | Runner routing with non-input default | `runs-on` keyed on a repo `vars.USE_SELF_HOSTED` default (not `inputs.force_cloud` alone) so push/PR events default to cloud; `workflow_dispatch force_cloud` overrides per-run | grep `runs-on:` expressions; confirm they reference `vars.USE_SELF_HOSTED`, not `inputs.force_cloud` as the sole determinant | High |
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

## CI runner guard (minutes-exhausted → self-hosted auto-failover)
`ops/ci-runner-guard.sh` (Whisky AI OS) — detects when GitHub-hosted Actions minutes run out
(cloud `ubuntu-latest` jobs die at infra level: no runner, no failed step, empty logs — green
PRs become un-mergeable for reasons unrelated to the code) and, when a self-hosted runner is
online, flips the repo's `USE_SELF_HOSTED` variable to `true` so CI routes to the free
self-hosted runners. Always alerts via the Whisky Whoop bot. Never auto-reverts
self-hosted→cloud (deliberate cost/load choice). Detection: billing API (if `GH_BILLING_PAT`
set) + heuristic on the last CI runs. Runs on a schedule (launchd `com.ebda.os.ci-runner-guard`,
every 30 min) and on demand. Criterion: every Force repo's `ci.yml` MUST honor `vars.USE_SELF_HOSTED`
(the `runs-on` ternary) so the guard can flip it without a code change.

**Runner fleet (2026-07-12 cutover): Umbra first, legacy OrbStack fallback.** The
self-hosted runners live in a local VM on the Mac. The canonical host is now the
Umbra machine `fwb-ci6` (runner services are systemd units inside the
VM, so booting it restarts them; its runners register at the ORG level, invisible to
the repo-scoped `/actions/runners` API — a running Umbra fleet can look like zero
runners to a naive check, so the guard judges health by the CI queue instead of that
API). The OrbStack machine `fwb-ci` is the legacy safety net, started ONLY when the
Umbra fleet is also down — running both VM fleets at once on the 16GB box causes
memory pressure that kills runner services mid-job (observed 2026-07-12: two CI runs
cancelled mid-`npm ci`). The guard self-heals a stopped machine (`umbra start` /
`orb start`) before alerting, and never resurrects OrbStack while a Umbra restart is
still soaking. `os-watch.sh` enumerates whatever runners are actually registered (no
hardcoded runner names) rather than probing retired names that go silently stale.

**Guard invariants (2026-09-15).** Three live defects set these; `ops/tests/ci-runner-guard.test.sh`
enforces each one.
- **Every `umbra` call is wall-clocked through `_ut`.** A guard run hung 27+ min on an unwrapped
  `printf … | umbra shell m -- bash`, whose ssh was waiting for a banner the guest never sent. A
  hung guard is a silent guard, because launchd will not start the next tick. `_ut` preserves
  stdin: under bash 3.2 a backgrounded command otherwise reads /dev/null, which made a wrapped
  stdin script run empty. On timeout it kills the whole descendant tree, since a surviving
  grandchild holding stdout keeps `$(…)` blocked. The suite fails on any unwrapped call.
- **`starting`/`stopping` is not an outage.** umbra holds a machine in `stopping` for up to 180s.
  The guard waits for the transition to settle, bounded by `UMBRA_TIMEOUT_SLOW`. A planned
  `stop && start` produces no page and no competing `umbra start`, and the guard skips probing
  the still-booting guest for that cycle. A transition that never settles is still alerted.
  "SELF-HEALED" is reported only when the VM is actually running after the start.
- **The expected runner count is measured, not configured.** Order: installed `actions.runner.*`
  units in the guest, then the sum of `count` in `~/.umbra/runners/<machine>.json`, then 1.
  `RUNNER_INSTANCE_COUNT` is an explicit override and must not be set in the plist. A pinned `1`
  printed "20/1 active — healthy" and made a shortfall impossible to detect.

**Auto-rebuild of a corrupt guest (2026-09-16).** The guard's one DESTRUCTIVE remedy. When
`umbra doctor --json` returns a verdict with `health: fail`, `rung: guest-disk-corrupt` and a
`subject` naming the guard's own machine, the guard runs `umbra rebuild <machine> --yes` instead
of standing down. Authorised by Ahmad ("rebuild it if it comes back") after fwb-ci6 corrupted
twice in two days: a reboot never recovered it (forced stop at 120s, failed readiness, the vm
process burning 0.01s of cpu over a 10s sample) and a rebuild always did, in ~9 min.

- **Only that rung, and only that machine.** `guest-ssh-stall`, `netstack-dead`, `host-hardware`,
  `machine-crashed` and `billing-lockout` never rebuild. The target comes from the verdict's
  `subject`, never from config — a destructive action must name its target from the evidence that
  convicted it, so a corrupt verdict about another guest cannot destroy this one.
- **`guest-disk-corrupt` STAYS in `UNHEALABLE_RUNGS`.** It must keep blocking the restart/reboot
  path, which still makes the fault worse. The rebuild is layered in FRONT of the stand-down, not
  a reclassification.
- **Rate limit + cooldown, persisted across runs** (`~/.whisky-os-state/guest-rebuild-history.json`,
  `ops/lib/guest-rebuild.sh`): at most **2 rebuilds per rolling 24h**, never two inside **3h**. The
  guard ticks every 30 min, so an unguarded persistent verdict is 48 destructive rebuilds a day —
  the 2026-08-27→09-07 restart loop with a bigger hammer. 3h because a freshly rebuilt guest wedged
  again ~37 min later on 2026-09-15; a shorter gap loops against a cause that is not the disk. On
  hitting either limit the guard alerts loudly and does nothing else. A missing lib FAILS CLOSED
  (no guardrail ⇒ no rebuild).
- **Never destroy a live job — unless the guest is already unusable.** A busy runner defers the
  rebuild only while the guest still answers ssh with a WRITABLE root. On an unusable guest the
  busy flag is a stale registration, not work in flight (2026-09-16: runners drained 20→16 while
  jobs queued unrun, a listener log frozen mid-write), so deferring to it would defer forever.
- **Verified after the fact, in the guard's own output:** state `running`, ssh answering, root
  writable, ≥1 runner unit active, GitHub runners online. An exit code of 0 is not a restored
  service, and a rebuild that leaves root read-only is reported as NOT restored and alerts.
- Every decision is logged with its evidence (rung, subject, `guest_usable`, `runner_busy`,
  rebuild history) so a human can audit why it did or did not fire.
- **Hands-off while umbra provisions** (2026-10-16): `umbra rebuild` holds
  `~/.umbra/provisioning/<vm>` (`expires=<epoch>`, refreshed per step, 60-min TTL, removed on
  success or a failed `health` step, kept on any other failure). The guard
  (`ops/lib/umbra-provisioning.sh`) stands down for THAT machine only — no start, reboot, rebuild,
  prune, clock hard-set or outage page — until the expiry, and refuses an expiry more than 4h out.
  Collected findings, fleet-wide checks and per-repo routing still run and page, and the marker is
  re-read immediately before every guest-changing action (check-then-act). The expiry, never the file's existence, is the signal: a killed rebuild hands the guest
  back within one TTL. The lib fails OPEN (missing/malformed ⇒ normal guard). Why: at 02:53 the
  guard rebooted a guest mid-rebuild, and with a doctor verdict in hand it would have started a
  second `umbra rebuild` on top of the first (reproduced in `ops/tests/ci-runner-guard.test.sh`).
- **`umbra doctor` gets its own wall clock** (`UMBRA_TIMEOUT_DOCTOR`, 180s; doctor measured 65-66s
  on a degraded guest against the 45s probe ceiling), and an empty doctor result is logged as
  "not evaluated" — never silently read as healthy.
- **ATTENTION rungs page, never act.** `guest-crash-damage` (a runner tool-cache `node` exiting
  132, or EXT4 warnings in the boot's kernel log) has a local remedy, so the guard alerts with
  doctor's `next_action` for its own machine only and keeps healing as normal.

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

**Install / repair (on the runner host — the OrbStack `fwb-ci` Ubuntu machine, `orb -m
fwb-ci`, not the Mac):** `bash ops/setup-runner-hooks.sh` — diagnoses the current hook
(prints it + its exit code so we learn *why* it failed, not just mask it), preserves
existing logic as the `.real.sh`, writes the best-effort wrapper, idempotent. No runner
restart needed (the hook is read fresh per job). One edit fixes all runners sharing the
hook path.

**Detection (OS, reactive):** `ops/runner-hook-health.sh [--notify]` reads recent CI
runs across Force repos and flags the signature *job failed but only the cleanup /
"Complete runner" step failed — every real step passed*, then alerts with the one-line
fix. Complements `ci-runner-guard.sh` (that handles cloud-minutes exhaustion; this
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

`fwb-ci6` reached **0 bytes free of 58 G**: 18 registered runners, ~40 G of
`_work` checkouts and `node_modules`. Every runner then failed to reach GitHub,
**all 18 registrations went offline**, and four repos sat with runs that could
never start. Nothing watched the disk, so the first symptom was CI having been
dead for days.

Two rules follow:

1. **Adding runner instances adds disk, not just concurrency.** Budget
   `instances × workspace size` before scaling a fleet — a repo with a large
   `node_modules` costs 2–3 G *per instance*.
2. **Watch the CI host's disk and reclaim automatically.** A full disk on a CI
   host is not a "warn later" condition: it takes the whole fleet down, and the
   runners do not recover on their own once GitHub reaps the session.
   `ci-runner-guard.sh` now warns at 80% and runs `umbra prune` at 90%, and
   `umbra prune` clears idle `_work` trees (skipping runners mid-job).
   An unreadable disk reads as **unknown**, never 0% — a guest you cannot reach
   must not report healthy.

sources: stray-process-on-shared-runner-poisons-ci

### A shared runner host turns every per-job resource into a contended one (2026-08-23)

Scaling `fwb-ci6` from 6 to 18 runner instances bought throughput and three outages. Each was a
shared resource that simply was not contended at 6 instances:

- **Disk** — 18 × ~2.5 GB of `_work` filled a 58 GB disk to **0 bytes**; the whole fleet went
  offline. Budget `instances × workspace size` before adding instances.
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


## Runner focus — runners are ON-DEMAND (2026-10-08)
**Standard:** the Umbra guest `fwb-ci6` (6 CPU / 6 GiB, disk on the external SSD — never move it)
runs only the runners of the repos that are using CI right now. Everything else is stopped AND
disabled, so the whole guest RAM goes to the repo that needs it. 22 always-on runner services
for ~19 repos plus two load hangs in one day (2026-10-08) is the failure this prevents.

- `ops/runner-focus.sh on|off|only|all|auto|status <slug>...` (slug = repo part of the runner
  name; `status` shows active/idle/busy and guest memory). `off` never stops a BUSY runner
  (GitHub `busy=true`, or unknowable) — it skips it and keeps it in the focus set until a
  later `off` succeeds.
- Desired set lives in `~/.umbra/runner-focus.json` (`{"focus":[slugs]}`; no file = all runners
  expected). Default focus: `ebda`. Starting a new project's CI: `runner-focus.sh on <repo>`.
- `ci-runner-guard.sh` and `runner-reregister.sh` read it: a deactivated runner is EXPECTED to
  be down — not counted, never restarted, never re-registered. Hung-guest detection and reboot
  are unchanged and judged on the focused runners. An unreadable focus file disables healing
  and alerts (fail closed: healing blind would restart runners deactivated on purpose).
- Auto-on: each guard cycle runs `runner-focus.sh auto`, which turns ON a deactivated repo whose
  job has been queued for a self-hosted label (`umbra-ci`/`self-hosted`) for > 3 min. It only
  ever turns runners on. Org-level runners (ebda) are never auto-handled. Reset with
  `runner-focus.sh only <slug>...` when the work is done.
- Tests: `ops/tests/ci-runner-guard.test.sh` ("a deactivated runner is not healed").

## Merge gate + gate scope (2026-10-25)
A PR is merged only through `ops/merge-gate.sh` (zero checks is never green; head pinned; explicit required checks
derived from the workflows; 3 consecutive polls) - `merge-gate.md`. Secret scans on `pull_request` scan the PR's own range, full
history on `main` + nightly; perf/startup gates compare to a same-job `main` baseline, never an absolute budget; status probes
target seeded resources and assert a page marker. sources: `ci-merge-gates-never-merge-on-no-checks`.
