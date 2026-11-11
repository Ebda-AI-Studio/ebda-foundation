---
name: ebda-loop
description: Use when Ahmad says "loop", "run the loop", "start the loop" or "keep the loop going" (NOT the built-in /loop interval skill, which only repeats a prompt on a timer). The Ebda operating procedure the controller follows every cycle - re-triage STILL-OPEN + FOUND against main and open PRs, dispatch Sonnet builders (money > auth > data > ops > UX), drive merges through the drain loops and the independent review gate, verify deploys, re-verify on the QA store, run audits on cadence, watch alerts, and stop only when loop/exit-check.sh passes all 6 exit criteria.
---
<!-- AI OS capability, installed by os/install.sh (os/skills/* -> ~/.claude/skills). Source of the process: loop/LOOP.md; state: loop/REGISTER.md. -->

# ebda-loop

"loop" = this procedure. `/loop 5m ...` (built-in) is a different thing: a timer. Start every cycle with `bash os/ops/loop-status.sh` (path under the foundation checkout; `--no-net` when offline) and write what it shows into your handoff.

Never idle while STILL-OPEN or FOUND is non-empty. Never stop for a feeling: the only exit is step 8.

## Hard rule: wake-on-exit watchers (Ruling LOOP-WATCH-1)

Any watcher whose EXIT is the wake-up (`alert-wait.sh`, `loop-watchdog.sh`, a gate or CI waiter) runs ONLY as a harness-tracked background task: `Bash` with `run_in_background: true`. NEVER `nohup`, `&` or `disown`: the harness wakes the session on the exit of a task it tracks, and the exit of a detached process wakes nobody (2026-11-11: alert-wait relaunched with `nohup ... &`, 21 P1 alerts missed, 2 h stall, 0 merges with ~20 approved PRs waiting). They exit once per event by design, so a wake means re-arm.

## Session-start checklist

1. `bash os/ops/loop-status.sh` into the handoff.
2. Arm `bash os/ops/alert-wait.sh` (background task).
3. Arm `bash os/ops/loop-watchdog.sh` (background task). It wakes on red main CI, a dead drain or alert listener, or 40 min without a merge while approved PRs wait; ack a known issue with the line it prints.
4. Confirm the drain jobs are loaded and the drain markers exist.

## On every wake (alert, watchdog or task exit)

Run `bash os/ops/loop-status.sh`; check main CI (`gh run list -R <repo> --branch main --workflow CI --limit 1`) and the last-merge time; act on the cause; then RE-ARM `alert-wait.sh` and `loop-watchdog.sh` as background tasks (each exited). A wake you did not re-arm after is a blind loop. The brain backstops this without any session: main CI red 30+ min or no merge 60+ min with approved PRs sends ONE P1 to Ahmad (watcher `loop-stall`), but that is the last line, not the plan.

## Each cycle

1. **Re-triage.** Sources: newest `business/ebda/audits/*still-open*.md` (under `~/Desktop/projects/Ebda-AI-Studio/`) + the FOUND list in `loop/REGISTER.md` + open `review-finding` issues. Check every item against `origin/main` (grep/`git log -S`) and open PRs (`gh pr list`); drop what is done, mark what an open PR covers, keep the rest. Bucket by theme, order **money > auth > data > ops > UX**. Record the result in REGISTER.md (append; do not rewrite other sections).
2. **Dispatch.** One builder per theme, `model: "sonnet"` (Opus only for money/security design), max 2 tracks at once. Every brief carries these rules:
   - worktree via `~/.claude/scripts/new-task-worktree.sh <repo> <feat|fix>/<task>`; deps via `wt-deps.sh`, never `npm ci`
   - one themed PR into `main`, never stacked; a test that fails on the old code
   - foundation first: add the rule/token/guard/standard to ebda-foundation, then consume it (LOOP.md step 4)
   - the anti-slop standard (LOOP.md); docs in the same PR (documentation parity)
   - no `--no-verify`, no `git stash pop`, `git add` specific paths, kill only PIDs you started
   - report: PR number, what test fails on old code, blast-radius line, what could not be verified
3. **Merge.** Merging is the drains' job, not yours: confirm the `<OS_LAUNCHD_PREFIX>.drain-*` launchd jobs are loaded (`loop-status.sh` "drains"; if none, start the drain scripts under `os/ops/` by hand as background tasks you own). Risky-path PRs (label `risky`) wait for the independent review (`ai-review-passed`); never merge around it. Merge only through `merge-gate.sh` (zero checks is never green). A failed check gets a fixer within 5 minutes.
4. **Deploy verify.** After merges: every service's `/health` commit vs the main tip of its repo, and every pipeline the merge should have triggered (`os/standard/deploy-verify.md`). A cancelled run is a deploy that did not happen. A merge is not a deploy.
5. **QA.** Re-verify every merged item live on the QA store (Amelia, store `1bb14d0e-0cb8-4cb4-b939-e889c4bc2ebc`, ameliaaurum.com, store.ebda.app admin) in Chrome at 390/820/1280/1440; arm console + network capture first. Record each as CLOSED (VERIFIED evidence) or back to FOUND in `loop/REGISTER.md`. Guest-shaped writes only; never complete a purchase.
6. **Audits on cadence.** If no backfill code audit ran in the last 7 days, or after a big merge batch: run money / auth-security / data-jobs code audits (Opus for money and security, Sonnet otherwise) over main; lens audits (`os/audit/lenses/`) and the iceberg audit (`os/standard/iceberg-*.md`) on their own cadence. Findings become `review-finding` issues, then step 1.
7. **Alerts.** Keep `bash os/ops/alert-wait.sh` and `bash os/ops/loop-watchdog.sh` armed as harness background tasks (see the hard rule; each exit = wake, read, re-run). A p1 preempts the cycle.
8. **Exit.** Run `bash loop/exit-check.sh`. If the script is absent, measure the six criteria yourself and say which you could not measure. Stop only when all 6 pass; then hand Ahmad his two items: the launch assets and the 10-minute merchant test.

## Reporting

Per cycle, at most 8 lines: status counts, what merged/deployed/closed, what is blocked and why, next action. Label claims VERIFIED / NOT VERIFIED / INCONCLUSIVE.
