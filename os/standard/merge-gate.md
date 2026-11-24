# merge-gate - never merge on "no checks"; the gate, not the merge button, is the line

tags: [BOTH]
sources: `feedback-ci-merge-throughput-thin-runner-pool`, `ci-merge-gates-never-merge-on-no-checks`, `feedback-never-admin-merge-past-security-checks`, `feedback-gate-that-cannot-fail-reports-success`

**Incident (2026-10-25).** ebda-store #223, a destructive DB migration, merged 6 seconds after it was opened with ZERO
CI checks. The watcher read an empty `statusCheckRollup` as "all green", and `gh pr merge` merges happily when nothing has
reported yet. Whisky-11 repos are on the GitHub Free plan: private repos there have **no branch protection**, so no
server-side rule would have stopped it. The merge command is the only line, and it must be a gate that can fail.

**The rule:** *a PR is merged only through `ops/merge-gate.sh <pr> <head-sha> --repo <owner/name>`.* Not `gh pr merge`,
not a watcher loop, not the GitHub UI "merge" on a PR whose checks list is empty or unfinished.

**Tradeoff:** a merge takes 3 polls x 30 s longer than a bare `gh pr merge`, and a repo with no PR workflow cannot
be merged through the gate at all (it refuses - which is the point: that repo has no CI to trust).

## What the gate demands (on N=3 consecutive polls)
| # | Condition | Why |
|---|---|---|
| 1 | head sha == the sha you reviewed (7+ char prefix), and the final merge passes `--match-head-commit` | you merge what you reviewed, not a late push |
| 2 | `mergeable == MERGEABLE` | UNKNOWN/CONFLICTING is not mergeable |
| 3 | **at least one check exists** | zero checks is "CI has not started", never green |
| 4 | the LATEST run of every check name is COMPLETED with SUCCESS / SKIPPED / NEUTRAL | queued, in-progress, failed, cancelled, timed-out are not green; a superseded run of the same name decides nothing |
| 5 | every REQUIRED check is an explicit SUCCESS (not SKIPPED) on its latest run | a skipped required job proves nothing ran |
| 6 | the required list is DERIVED from the repo's `.github/workflows` (`ops/lib/merge_gate.py`): jobs of workflows that run on EVERY `pull_request` (no `paths` / `paths-ignore` on that trigger) and always run on one (no job `if`, or exactly `github.event_name == 'pull_request'`, or exactly the fork guard, and all `needs` likewise) | it cannot drift from the workflows; a hand-kept list rots |

A failing/cancelled check or a moved head ends the run at once (exit 1); pending checks are waited on up to
`--max-wait-min` (180) then exit 2 with nothing merged. No derivable required list (no PR workflow) exits 2.
Run it from a checkout of the repo (default workflows dir is `<toplevel>/.github/workflows`) or pass `--workflows`.

**Deferred heavy checks (`--defer-heavy-to-merge-group`, Ruling MQ-FULL-LANE-1, Ebda 2026-11-23).** When the repo's merge queue runs the full lane
on PR+main before anything merges (ebda-store: `merge_group` runs unit shards, integration, E2E, builder E2E, build, audit), a PR whose heavy
PR-lane runs were CANCELLED (concurrency, controller sweeps, hosted slot limits - never a defect) may be gated with this flag: those cancelled
heavy checks (`Unit shard`, `Unit Tests`, `App build(s)`, `Integration*`, `E2E Tests`, `Builder E2E`, `Build`, `Worker dry-run`, `Orphan test coverage`,
`Security Audit`, `Tested tree check`) are dropped from the verdict. Still refused: any FAILED check, zero checks, every required check (explicit
SUCCESS), `Lint` and `Type Check` (skipped in the merge_group run, so only the PR run proves them), and the light gates (Repo guards, PR body sections,
Slop/Capability baselines, AI review, gitleaks, CodeQL). The flag refuses (exit 2) when `rules/branches/main` has no `merge_queue` rule. Each use is
appended to `$MERGE_GATE_DEFER_LOG` (default `~/.claude/handoff/merge-gate-defer.log`). Never use it for money PRs: they keep full PR-lane CI at the stamped head.

### Cross-repo: the required list is the TARGET repo's (2026-11-12)
`ops/merge-gate.sh 72 <sha> --repo Ebda-AI-Studio/ebda-whatsapp`, run from ebda-foundation, derived the required list from
ebda-foundation's own workflows ("OS brain Worker", "OS hands", "OS layer", "PR sanity"...) and waited 90 minutes for checks
ebda-whatsapp never emits. Now both gate scripts (`ops/merge-gate.sh`, `os/ops/merge-gate.sh` = the installed
`~/.claude/scripts/merge-gate.sh`) accept `--workflows DIR` and, **when `--workflows` is absent and `--repo` is not the repo
whose checkout supplies the workflows (compared with that checkout's `origin`), refuse with exit 2 and never read the PR.**
A caller for another repo passes `--workflows <target checkout>/.github/workflows` or runs the installed gate from the target
checkout. `os/ops/drain.sh` now runs the gate with `cd "$DIR"` (launchd's cwd is `/`). The hands config passes `--workflows`.

### Latest run wins (2026-11-10)
`statusCheckRollup` keeps OLD runs of a same-name check on the same head sha. On ebda-whatsapp PR 56 (2026-11-09) the
label check had two runs on one head: CANCELLED at 21:16:28Z (superseded by its concurrency group) and SUCCESS at
21:16:32Z. The gate judged every run, so the dead one refused the PR twice (exit 1) although nothing was wrong.
The gate now groups the rollup by check name and judges only the latest run: the one with the greatest
`startedAt // createdAt // completedAt`; equal timestamps keep rollup order (the later entry wins). `gh` prints a null
timestamp as the year-1 zero time, which counts as missing, and an unfinished run with no start time is treated as the
newest so it can never lose to an older green run. It holds in both directions: older pass + newer fail still refuses,
older pass + newer run in progress waits, and an old SUCCESS does not satisfy a required check whose latest run was
SKIPPED. Checks with different names never mask each other.

### Path-filtered PR workflows are never required (2026-11-10)
A workflow whose `pull_request` trigger carries `paths` or `paths-ignore` creates NO check run for a PR that touches
nothing inside the filter. Requiring its job made the gate wait the full 180 minutes for a check that would never
exist (ebda-store PR 490, `blast-radius.yml`, 2026-11-09). Such a workflow contributes no required check. This does
not make it optional when it runs: its checks are still under condition 4, so a failing or unfinished run blocks the
merge. A filter on `push` only changes nothing, the PR job stays required. To require a job on every PR, put it in a
workflow with no path filter and decide inside the job (the affected-workspace pattern in `cicd.md`).

## Companion gate-scope rules (same incident day)
- **Secret scanning scopes to the PR.** A gitleaks workflow that scans *all refs* fails every PR the moment one branch
  carries a fake-key fixture. On `pull_request` scan the PR's own range (`--log-opts "origin/<base>..HEAD"`); full history
  runs on `main` and nightly. Test fixtures that look like secrets are built at runtime (string concatenation), never
  committed as literals.
- **Load-sensitive gates compare, they do not budget.** An absolute-millisecond startup-CPU gate flaked on a loaded
  runner. Measure `main` in the same job on the same machine and gate on the ratio/delta (ebda-store #226).
- **Probes target resources we control and assert a marker.** A public status probe aimed at a store that did not
  exist (`amelia`) turned the status page red ("Storefronts down"). A probe hits a seeded resource we own and asserts a
  page-specific marker string, not merely HTTP 200 (see `deploy-verify.md`).

## Thin runner pool: no refresh, main-red stop, batch PRs (2026-11-12)
The June 2026 lesson (per-PR CI is slow because the queue is self-inflicted) recurred in November because it lived only in
memory. A controller "refreshed" 33 reviewed Ebda PRs one at a time (update-branch, wait for review, wait for CI): 20 min to
2 h each on two Mac runners, i.e. days. Measurement showed the Umbra VM was not even running and Ebda CI was already on the Mac;
the bottleneck was the refresh, not the infrastructure.

Ruling MERGE-NO-REFRESH-1 - Never call `update-branch` (or rebase) a reviewed PR before merging it; merge on last-run green + AI review at the head + `MERGEABLE`, and let main's push CI be the integration check (the drain's MAIN GATE, `main_gate()`, already merges nothing while main is not green). Evidence: 2026-11-12 Ebda, 33 reviewed PRs, the org ruleset never required up-to-date branches; `os/ops/drain.sh` (`--main-workflow`, default `CI`) pauses with "MAIN NOT GREEN <sha> - paused" before every pass and before every single merge; `os/tests/drain.test.sh` fails on the old drain (red, cancelled, unknown and mid-pass-red cases). Cost if wrong: two PRs that each pass alone can break main together, and the main-red stop then halts the queue until a fix lands.

What the drain and its helper now enforce (`os/ops/drain.sh`, `os/ops/relabel-after-review.sh`):
| Rule | Enforced as |
|---|---|
| No branch refresh | the drain never calls `update-branch` / rebase (a test pins it) |
| Review = conclusion, at head | with `--hold-risky`, the label is not enough: `--review-workflow` (default `AI review`) needs >=1 `success` on the head sha and no failure / cancelled / timed_out / action_required / startup_failure run, none unfinished. `relabel-after-review.sh` re-applies the label only on the same test, fail closed (a FAILED review is `completed` too, so status alone is never enough). Residual: a fork PR whose `fork-gate` run failed before the maintainer labelled it keeps that failed run on the head and stays held by the drain; clear it with a manual review and merge |
| A loop that did nothing is not running | every cycle logs `considering N PRs` and one `PR #n <sha> <state>` line per PR; a PR list passed as ONE quoted string (whitespace in an argument) exits 2, an empty list exits 2, an explicit list with none open exits 4. 2026-11-12: a refresher got its list as one quoted arg, logged one "skip" and exited 0, and was reported as running for 2 h |

Operating rules that go with it:
- **Batch PRs.** Ship ~10 small, already-reviewed PRs as ONE batch PR: one CI run and one review instead of ten. The diff must
  stay under the AI-review limit (400 KB; larger fails the check, see AIR-5); an oversize PR is split or reviewed by hand. A batch
  also separates real defects from stale infra reds (Ebda batch-1: 3 real fixes surfaced among 10 "red" PRs).
- **Measure the bottleneck before changing infrastructure**: runner busy/queue (`gh run list`, `gh api .../actions/runners`) and
  host load (`uptime`, `/proc/net/dev` on a VM) first. Closing a VM that is not running saves nothing.
- **Subagent diffs are grepped for suppressions before acceptance**: `allow`, `ignore`, `disable`, `@ts-`, `eslint-disable`,
  `as any` with a silencing comment. A batch agent once silenced a type error with an allow-comment; type it properly.
- **A loop is "running" only after its first per-item log line**, never after the process started or exited 0.
- **Status tables in docs are claims.** "How much is not built" comes from a plans-vs-main audit, not a register table.

## Grading (what an auditor checks)
| # | Criterion | Check | Severity |
|---|---|---|---|
| 1 | Merges go through the gate | merge history shows no PR merged with an empty check list; scripts/watchers call `merge-gate.sh` | High |
| 2 | The gate treats zero checks as not-green | `ops/tests/merge-gate.test.sh` ("ZERO checks is wait, never ok") passes | High |
| 2a | The gate judges the latest run per check name, both directions | same suite: "cancelled then success, same name => ok" and "success then failure, same name => refuse" pass | High |
| 2b | A path-filtered PR workflow is not required, and still blocks when it fails | same suite: "path-filtered pull_request ... is not required" and "path-filtered check ran and failed => refuse" pass | High |
| 3 | PR secret scans are range-scoped | the gitleaks workflow's PR trigger does not scan `--all` refs | Medium |
| 4 | No absolute-time budget gate on shared runners | perf gates compare to a same-job baseline | Medium |
| 5 | The drain never refreshes a branch | `os/tests/drain.test.sh` ("never calls update-branch") passes | High |
| 6 | Review means a clean conclusion at the head sha | `os/tests/drain.test.sh` (failed/cancelled review run => held) and `os/tests/relabel-after-review.test.sh` pass | High |
| 7 | A loop given no PRs or one quoted list fails loudly | `os/tests/drain.test.sh` ("one quoted list", "empty PR argument", "none open") passes | Medium |

Enforced by `ops/merge-gate.sh` + `ops/lib/merge_gate.py` (tests: `ops/tests/merge-gate.test.sh`); installed to
`~/.claude/scripts/` by `ops/install.sh`. Composes with `cicd.md`, `gate-integrity.md`, `babysit-prs` (use the gate as its merge step).
