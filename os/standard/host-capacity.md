# host-capacity - one heavy suite at a time on the shared Mac

tags: [BOTH]
sources: `host-capacity-one-heavy-suite-and-guarded-umbra` (history), `feedback-manual-lock-rule-deadlocks-when-hook-takes-same-lock`, `feedback-agent-test-containers-starve-ci-host`

**Incident (2026-10-24/25).** Measured: ~105 concurrent vitest processes from several agents' pre-push suites on a 16 GB
Mac, swap 3 of 4 GB, load 30+. Host overload looks like flaky CI. At the time it also froze and corrupted the Umbra CI VM
(three rebuilds in two days); Umbra is retired (2026-11-14, Ruling UMBRA-RETIRE-1) and CI now runs on native macOS runners
that share this host, so the same overload now shows up as slow or timed-out runner jobs. Disk full (`disk-discipline.md`)
is the other way to starve the runners; this is the CPU/RAM/I-O way.

**The rule:** *the host runs ONE full test suite at a time.* A rule only in CLAUDE.md is a preference, so each point has code.

**Tradeoff:** pushes queue (a pre-push can wait minutes behind another suite) instead of racing. Queueing is slower
per push and far faster than a rebuild.

## 1. One heavy suite, host-wide - `ops/host-lock.sh`
Every repo's pre-push (and any agent running a full suite by hand) runs the heavy step as
`host-lock.sh <command...>` -> one lock file, `~/.claude/locks/heavy-test.lock`, macOS `lockf(1)` (no `flock` on this Mac;
Linux falls back to `flock` on the same path). It **queues, never skips**, prints who is ahead, exits 75 on timeout
(default 3600 s) and never runs unlocked. The kernel drops the lock when the holder dies, so a killed push cannot wedge the queue.
Pair it with half the cores per run (`--maxWorkers=50%`).

**Lock layering (the 2026-10-25 deadlock).** BSD `lockf` is not re-entrant. A stop-gap rule "wrap `git push` in
`lockf heavy-test.lock`" plus a pre-push hook taking the same lock made the push wait on its own parent for 3600 s (exit 75,
~30 min lost). Rules:
1. **One owner per lock layer.** If a hook takes the lock, callers must NOT also wrap the command; broadcast "plain `git push`" in the same step as the hook merge, and retire the manual rule then.
2. **Re-entrant helper.** `host-lock.sh` exports `HOST_LOCK_HELD=<lockfile>` to the command it runs; a nested call sees the marker, re-checks that the lock is genuinely held (a stale marker must not bypass the queue) and runs directly.
3. Repos without the hook keep the manual form: `lockf -k ~/.claude/locks/heavy-test.lock <cmd>` (full suites only; never around `git push` where a hook takes the lock).

**Light steps do not take the heavy lock (PREPUSH-5, 2026-11-11).** The lock is for FULL suites. A pre-push step that is
light (about 100 s CPU, 0.5 GB: the repo-scanner unit tests) must not queue behind it, or 8 parallel pushes wait 20+ min
behind unrelated runs. Pattern (ebda-store `scripts/ci/prepush-slot.sh` + `pre-push-gate.sh`): (1) a pass cache keyed by the
git tree hash of HEAD plus the test list plus a size+mtime fingerprint of the gitignored files the tests read (built `dist`, generated dirs), used and written
**clean tree only** (`git status --porcelain` empty, because the tests read the working directory), so a re-push of the same clean tree costs 0 s and only a PASS is recorded; (2) a numbered-slot
semaphore (`~/.claude/locks/prepush-slot-N.lock`, N=4, `lockf`/`flock`, wait then exit 75, never skip) with a fixed
`--maxWorkers=2`. CI still runs the tests. Cost if wrong: a test depending on state outside the working tree (env, network) could be cached
as a pass and fail only in CI. sources: ebda-store `docs/rulings/PREPUSH-5.md`.

## 2. Agent fan-out
At most **2 heavy tracks** at once (LEAN mode); code-only tracks may run in parallel, suites queue on the lock. A new
worktree's first push does not justify a fresh full-suite run per agent - run touched tests per task, full suite at PR end.
One shared capped test DB; stop test containers when done (`container list` empty).

## 3. Alarms
`ops/ci-runner-guard.sh` reads the host data volume every 30 min (note at 88% used, finding at 94%) and the fleet's
online/busy state from the GitHub API (`disk-discipline.md`, `cicd.md`). `workspace-hygiene.sh` alerts below 30 GB free.
**Not alarmed (follow-up):** sustained 1-min load above 2x core count, swap pressure. Measure before blaming
(`vm_stat`, `sysctl vm.swapusage`, `uptime`, top processes by RSS).

## Grading
| # | Criterion | Check | Severity |
|---|---|---|---|
| 1 | Every repo's heavy pre-push step runs through `host-lock.sh` (or an equivalent single host lock) | grep the hook; two simultaneous pushes serialize | High |
| 2 | No wrapper+hook double lock | wrapped `git push` in a repo whose hook locks = gap | High |
| 3 | Host-disk alarm exists (load and swap: follow-up) | `ops/tests/ci-runner-guard.test.sh` ("critical host disk is a finding") | Medium |

Enforced by `ops/host-lock.sh` (tests: `ops/tests/host-lock.test.sh`), `ops/ci-runner-guard.sh`, `ops/workspace-hygiene.sh`.
