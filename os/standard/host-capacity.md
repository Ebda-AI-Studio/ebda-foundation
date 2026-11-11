# host-capacity - one heavy suite at a time, and never touch a busy CI guest

tags: [BOTH]
sources: `host-capacity-one-heavy-suite-and-guarded-umbra`, `feedback-manual-lock-rule-deadlocks-when-hook-takes-same-lock`, `feedback-umbra-sparse-disk-host-full-corrupts-guest`, `feedback-agent-test-containers-starve-ci-host`

**Incident (2026-10-24/25).** The Umbra CI guest froze and its ext4 corrupted three times in two days. Measured:
~105 concurrent vitest processes from several agents' pre-push suites on a 16 GB Mac, the guest at 5 GiB with 3 job slots
and the default disk cache mode, swap 3 of 4 GB, load 30+. Host overload looks like flaky CI and ends in a guest that
needs `umbra rebuild`. Disk full (`disk-discipline.md`) is the other way to kill the guest; this is the CPU/RAM/I-O way.

**The rule:** *the host runs ONE full test suite at a time; anything that touches the CI guest is gentle by default.*
A rule only in CLAUDE.md is a preference, so each point has code.

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
git tree hash of HEAD plus the test list, so a re-push of the same tree costs 0 s and only a PASS is recorded; (2) a numbered-slot
semaphore (`~/.claude/locks/prepush-slot-N.lock`, N=4, `lockf`/`flock`, wait then exit 75, never skip) with a fixed
`--maxWorkers=2`. CI still runs the tests. Cost if wrong: a test depending on state outside the tracked tree could be cached
as a pass and fail only in CI. sources: ebda-store `docs/rulings/PREPUSH-5.md`.

## 2. Agent fan-out
At most **2 heavy tracks** at once (LEAN mode); code-only tracks may run in parallel, suites queue on the lock. A new
worktree's first push does not justify a fresh full-suite run per agent - run touched tests per task, full suite at PR end.
One shared capped test DB; stop test containers when done (`container list` empty).

## 3. Alarms - what pages before the guest dies
`ops/guest-wedge-watch.sh` (#252) probes the guest, watches in-flight CI jobs, and alerts on host pressure: swap in use at
or above `GW_SWAP_MAX_PCT` (85) and low host disk (`disk-discipline.md`); only the narrow wedge verdict restarts a guest.
**Not yet alarmed (follow-up):** sustained 1-min load above 2x core count, and the top-RSS process list in the alert. Measure
before blaming (`umbra shell <vm>` -> `/proc/net/dev`, `df`, `/proc/pressure`; `umbra stats` for guest cpu/mem/swap).

## 4. Never prune or fstrim a busy guest
`umbra prune` runs `fstrim`, which **stalls guest I/O for ~80 s** -> CI test timeouts and, on a stressed guest, the wedge.
- Automatic cleanup only on an **idle** guest: `umbra prune <vm> --if-idle --no-fstrim` (umbra #63); `workspace-hygiene.sh` safe-prune (#255) never trims a guest with a running job and never fstrims for routine cleanup.
- A full fstrim is a deliberate, scheduled action on an idle guest, not a reflex when disk is low.
- The VM disk is attached **Uncached + Full sync** (a crash cannot lose acknowledged writes); job slots are throttled to 2 for the 5 GiB guest.

## 5. Forensics BEFORE rebuild
`umbra rebuild` recreates the machine and destroys the evidence. Since umbra #62 `umbra stop`/`rebuild` capture a best-effort
post-mortem first into `~/.umbra/forensics/<vm>-<utc>-<reason>/` (live guest dump within a 25 s budget, plus the host-side
mirror of the guest journal `~/.umbra/guest-logs/<vm>.log`, which exists even when the guest cannot answer ssh). Rule: **read
that directory before declaring a cause, and never delete it**; add host-side facts by hand (`sysctl vm.swapusage`, `uptime`,
top processes by RSS, `stat` of `disk.img`) because the capture is guest-centred. A fresh guest beats debugging a dead one
(`feedback-umbra-fresh-guest-beats-debugging-a-dead-one`) - after the cause is on disk.

## Grading
| # | Criterion | Check | Severity |
|---|---|---|---|
| 1 | Every repo's heavy pre-push step runs through `host-lock.sh` (or an equivalent single host lock) | grep the hook; two simultaneous pushes serialize | High |
| 2 | No wrapper+hook double lock | wrapped `git push` in a repo whose hook locks = gap | High |
| 3 | Routine prune is idle-only and fstrim-free | `workspace-hygiene.sh` / `umbra prune --if-idle --no-fstrim` | High |
| 4 | Swap and disk alarms exist (load: follow-up) | `ops/tests/guest-wedge-watch.test.sh` fires on a synthetic swap reading | Medium |
| 5 | A rebuild is preceded by a forensics capture | `~/.umbra/forensics/` has an entry per stop/rebuild (automatic since umbra #62) | Medium |

Enforced by `ops/host-lock.sh` (tests: `ops/tests/host-lock.test.sh`), `ops/guest-wedge-watch.sh`, `ops/workspace-hygiene.sh`.
Umbra-side follow-ups are filed as umbra issues: bare `umbra prune` still fstrims a busy guest (make idle-only the default), and the job throttle counts slots but ignores host swap/load.
