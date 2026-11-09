# sweep-safety - one sweep at a time, help runs nothing, a hung probe is UNKNOWN

tags: [BOTH]
scope: every OS sweep, watcher and maintenance script in ops/
sources: incident I12 (2026-10-26), feedback-worktree-process-and-handoff-hygiene

**Incident (2026-10-26).** About seven `workspace-hygiene.sh` runs (hourly launchd plus one per `gh pr merge` hook) ran at once and hung
`du`/`df`; `workspace-hygiene.sh --help` ran a REAL sweep because unknown flags were skipped.

**Rules.**
1. Every sweep/watcher starts with `lib/args.sh` (`args_help`: `-h/--help` prints the header and exits 0 before anything acts) and
   `lib/single-instance.sh` (mkdir lock in `~/.whisky-os-state/locks/<name>`, pid file, a dead pid is reclaimed, "already running" exits 0).
2. Unknown flags are exit 2 (`args_unknown`), never ignored.
3. `workspace-hygiene.sh --repo X` that finds the sweep busy QUEUES the slug (`~/.whisky-os-state/hygiene.queue`); the running sweep drains it.
   The hourly sweep is the backstop for the last-instant race.
4. `du`/`df` run under `_ut` (bounded). A `du` that times out reports `?`; a `df` that does not answer makes the run a DRY RUN
   ("UNKNOWN", nothing deleted). An unreadable free-space figure is never read as 0 or 999.

**Enforcement.** `ops/tests/single-instance.test.sh`: 7 parallel sweeps -> 1 runs; `--help` on 12 scripts makes zero shimmed calls;
hung du/df shims; dead/live lock; mutation control (lock check removed -> test goes red).
