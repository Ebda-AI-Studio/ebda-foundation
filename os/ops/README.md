## Command center
The Ops Command-Center is now a native macOS app — see `ops/command-center-app/` and `docs/runbooks/ebda-os-ops.md`. The Node aggregator (`ops/dashboard/`) remains the data/action backend.

## launchd jobs deliberately NOT in this repo

Two loaded `com.ebda.os.*` agents on the workstation have no plist here, on purpose:

- **`com.ebda.os.umbrad`** runs `/usr/local/bin/umbrad` — Umbra's own daemon, not a foundation
  ops script. It is Umbra's to install and version.
- **`com.ebda.os.fwb-babysit`** was a single-incident job (FWB PRs #814/#815, installed
  2026-07-19) written to self-destruct once both merged. Both merged on 2026-07-19 and the
  self-destruct never fired, so it stayed loaded and idle until 2026-08-03. Unloaded and archived
  to `~/.claude/scripts/_retired/`. **A self-destructing job needs an external sweep** — if its
  own last run is what removes it, a failure at exactly that step leaves it running forever with
  nobody watching.

`runner-restore.sh` has **no plist on purpose**. It is a thin delegate to `ci-runner-guard.sh`
(read its header), invoked by `dispatch-route.sh` on a `runner-offline` event. The guard already
runs every 30 minutes, so scheduling the delegate too would run the guard twice on every tick.
A plist for it used to ship here unloaded, which made `os-selftest` report "job may be
unregistered" on every single run — a permanent finding nobody could action. Removed 2026-08-03.

## Parking the self-hosted runner fleet

`ops/lib/runner-fleet.sh` is a thin wrapper over `service_paused()` in `ops/lib/os-state.sh`,
so the fleet parks with the same marker convention as every other paused Force service:
`~/.whisky-os-state/runner-fleet-paused`. **Park = create the file, un-park = delete it.**
Nothing else to edit — `ci-runner-guard.sh` and `os-watch.sh` both read `fleet_parked`.

It deliberately does NOT invent its own check. The WBS pause on 2026-08-06 established that
a watcher which grows a private pause check is how the noise comes back, and that pause state
must be RUNTIME state (`~/.whisky-os-state/`), not deployed config — a `heal-registry.json`
edit was silently reverted by the next script sync, re-arming the healer mid-pause.

Why it exists: on 2026-08-06 `fwb-ci6` stopped booting, and on 2026-08-08 every repo was
routed to cloud (`USE_SELF_HOSTED=false`) — but nothing told the fleet's watchers or its
healer. `ci-runner-guard` hard-rebooted a dead guest **every 30 minutes for three days**,
Telegramming each failure, while the `runner-health-check` crons on CRM + WBS fired every
15 minutes at the same dead runner. ~30 pages overnight about infrastructure that was
deliberately out of service. That is the [service-pause] rule: parking a service means
sweeping every WAKER, WATCHER and the HEALER.

Note the guard's `doctor_unhealable_rung` pre-flight was built to stop exactly this thrash
and **did not fire** — `umbra doctor` classifies a non-booting guest as rung `unknown`,
which is not in its unhealable set. Do not rely on doctor alone to notice a pointless heal.

**Parked is not blind.** While parked the guard still asserts the safety invariant: every
repo in `REPOS` must actually be on cloud. Parked fleet + a repo on self-hosted is the
dangerous state — CI queues forever against a runner that will never arrive, and the
watcher that would have said so is the one standing down — so that combination alerts
loudly and exits 1. Both libs fail CLOSED: a missing `runner-fleet.sh` means "not parked",
so a deleted file can never silence a real outage.

## Rebuilds in progress: the guard stands down per machine

`umbra rebuild` writes `${UMBRA_ROOT:-~/.umbra}/provisioning/<vm>` (`expires=<epoch>`,
`phase=`, `pid=`, `updated=`), rewritten at the start of each step with a 60-minute expiry and
removed on success. `ci-runner-guard.sh` reads it through `ops/lib/umbra-provisioning.sh` and,
while it is unexpired (and no more than 4h out), skips every heal, reboot, rebuild, prune,
clock hard-set and outage page **for that machine only**, saying so on stdout and in
`runner-status.json`. Everything else still runs and still pages: findings already collected
(a host disk at crit), the fleet-wide guest checks, the per-repo routing. The marker is re-read
immediately before every guest-changing action (`hands_off`), so a rebuild that starts while the
guard is mid-run is honoured too. Host sleep: umbra re-stamps the marker every 30 s from the
wall clock, and an expired marker whose `pid=` is still a live umbra process also counts (for at
most 4h past expiry), so a guard that fires the moment the Mac wakes does not act on a rebuild
still in flight. A failed rebuild keeps the marker
while you finish by hand; a killed one stops covering the guest within one TTL. Delete the file
to hand the machine back early. Why: on 2026-10-16 the guard rebooted a brand-new `fwb-ci6`
mid-rebuild, and had to be unloaded by hand for the window.

## Self-hosted runner disk (Umbra guest `fwb-ci6`)

`runner-job-started-hook.sh` is deployed INSIDE the guest as
`/home/umbra/hooks/job-started.sh` and wired per runner via
`ACTIONS_RUNNER_HOOK_JOB_STARTED` in each `actions-runner-*/.env`. A runner only
reads `.env` at start, so after changing it: `sudo systemctl restart 'actions.runner.*'`
— check `pgrep -fc Runner.Worker` is 0 first, or you kill a live build.

**The runner dirs are the long-named ones** (`actions-runner-ebda-store-1`),
one systemd unit each. On 2026-08-03 a set of short-named duplicates
(`actions-runner-fwb-1`, `-crm-1`, …) was found holding **13.3 GB** — leftover copies
from the rename migration, with identical `.runner` files (same `agentId`) and no
systemd unit. Removed. If you see both spellings again, the short one is the leftover
— but verify with `systemctl show <unit> -p ExecStart` before deleting, not by name.

## Worktree dependency cache + disk guard (`wt-deps.sh`)
Every agent worktree used to run its own `npm ci` (~2.3 GB each); 6 parallel agents filled the Mac disk and a full
host disk corrupts the Umbra CI VM (2026-10-16, 2026-10-24). Now:
- `wt-deps.sh [dir]` (called by `new-task-worktree.sh`; also runnable alone in any worktree; `WT_SKIP_DEPS=1` skips).
  Key = sha256(lockfile)[:16] + node major + arch. `~/.cache/wt-deps/<repo>/<key>/tree/**/node_modules` holds ONE real
  install (root + every workspace's nested node_modules). New worktrees get `cp -cR` APFS clones (copy-on-write, ~0 disk
  until files change). Miss -> one install in that worktree, snapshot, keep the 2 newest keys per repo. Non-APFS /
  cross-volume -> plain install. node_modules is never symlinked. Existing populated node_modules is left alone
  (`WT_DEPS_FORCE=1` replaces). Lifecycle scripts follow normal npm behaviour; repo-specific steps (e.g. ebda
  `npm run generate -w packages/database`) still run per worktree and only write the files they touch.
- Disk guard: `new-task-worktree.sh` refuses under 30 GB free (`WT_MIN_FREE_GB`, override once with `WT_FORCE=1`),
  printing top space users + the cleanup command.
- `workspace-hygiene.sh` drops node_modules from worktrees whose PR is MERGED even when kept for uncommitted files
  (never one a process stands in), and posts a Telegram alert via `notify.sh` when host free < 30 GB (6 h cooldown,
  stamp `~/.cache/wt-deps/.disk-alert`).

### Every worktree-creation path is caught, and the CI VM is trimmed (2026-10-25)
Full design + grading: `standard/disk-discipline.md`. In short:
- `git-hooks/dispatch.sh` is installed by `install.sh` as every standard hook under `~/.claude/git-hooks` and activated with
  `git config --global core.hooksPath` (never overwrites a different existing value). `post-checkout` runs `wt-deps.sh` on a
  NEW linked worktree; every hook then `exec`s the repo's LOCAL `.git/hooks/<name>` (husky only where `ebda.chainHusky=true`, set by install.sh for Ahmad's repos). Automatic callers run hook-mode `wt-deps.sh`: trusted repos under ~/Desktop/projects only, CLONE-ONLY (a cache miss prints the manual command; no installer ever runs from a hook). A repo with its own
  `core.hooksPath` (husky v9) bypasses the global one - `hooks/post-worktree-deps.sh` (PostToolUse on EnterWorktree and
  Bash `git worktree add`) covers Claude there, and `wt-deps.sh` re-arms husky in the clone.
- `hooks/block-worktree-install.sh` (PreToolUse) denies `npm ci|install` / `pnpm install` / `yarn` in a worktree ONLY on a
  cache hit (`wt-deps.sh --check`); escape hatch `WT_ALLOW_INSTALL=1`. Register with `ops/install-hooks.sh`.
- `workspace-hygiene.sh` runs `umbra prune <vm>` on running machines when host free < 40 GB or disk.img grew > 10 GB since
  the last prune (`UMBRA_PRUNE_FREE_GB`, `UMBRA_PRUNE_GROWTH_GB`; state `~/.cache/wt-deps/umbra-prune.tsv`; log
  `~/Library/Logs/forceai-umbra-prune.log`); skips a VM under `umbra rebuild`; Telegram if still < 30 GB after.
