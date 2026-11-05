# merge-gate - never merge on "no checks"; the gate, not the merge button, is the line

tags: [BOTH]
sources: `ci-merge-gates-never-merge-on-no-checks`, `feedback-never-admin-merge-past-security-checks`, `feedback-gate-that-cannot-fail-reports-success`

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
| 4 | every check COMPLETED with SUCCESS / SKIPPED / NEUTRAL | queued, in-progress, failed, cancelled, timed-out are not green |
| 5 | every REQUIRED check is an explicit SUCCESS (not SKIPPED) | a skipped required job proves nothing ran |
| 6 | the required list is DERIVED from the repo's `.github/workflows` (`ops/lib/merge_gate.py`): jobs of workflows that run on `pull_request` and always run on one (no job `if`, or exactly `github.event_name == 'pull_request'`, and all `needs` likewise) | it cannot drift from the workflows; a hand-kept list rots |

A failing/cancelled check or a moved head ends the run at once (exit 1); pending checks are waited on up to
`--max-wait-min` (180) then exit 2 with nothing merged. No derivable required list (no PR workflow) exits 2.
Run it from a checkout of the repo (default workflows dir is `<toplevel>/.github/workflows`) or pass `--workflows`.

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

## Grading (what an auditor checks)
| # | Criterion | Check | Severity |
|---|---|---|---|
| 1 | Merges go through the gate | merge history shows no PR merged with an empty check list; scripts/watchers call `merge-gate.sh` | High |
| 2 | The gate treats zero checks as not-green | `ops/tests/merge-gate.test.sh` ("ZERO checks is wait, never ok") passes | High |
| 3 | PR secret scans are range-scoped | the gitleaks workflow's PR trigger does not scan `--all` refs | Medium |
| 4 | No absolute-time budget gate on shared runners | perf gates compare to a same-job baseline | Medium |

Enforced by `ops/merge-gate.sh` + `ops/lib/merge_gate.py` (tests: `ops/tests/merge-gate.test.sh`); installed to
`~/.claude/scripts/` by `ops/install.sh`. Composes with `cicd.md`, `gate-integrity.md`, `babysit-prs` (use the gate as its merge step).
