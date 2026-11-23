## Command center
The Ops Command-Center is now a native macOS app — see `ops/command-center-app/` and `docs/runbooks/ebda-os-ops.md`. The Node aggregator (`ops/dashboard/`) remains the data/action backend.

## launchd jobs deliberately NOT in this repo

One loaded `com.ebda.os.*` agent on the workstation may have no plist here, on purpose:

- **`com.ebda.os.store-babysit`** was a single-incident job (store PRs #814/#815, installed
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

## The runner fleet (native macOS runners)

CI runs ONLY on native macOS GitHub runners (Umbra, the old local Linux CI VM, was retired 2026-11-14, Ruling
UMBRA-RETIRE-1). `ci-runner-guard.sh` judges the fleet from the GitHub API alone (`gh api orgs/<org>/actions/runners`:
online/busy per org and per label) and only REPORTS; the runners are launchd services on the Mac
(`actions.runner.<org>.<name>`), restarted with `launchctl kickstart -k gui/$(id -u)/actions.runner.<org>.<name>`.
Design and grading: `standard/cicd.md`. Park/focus/rebuild markers (`runner-fleet-paused`, `runner-focus.json`,
`~/.umbra/provisioning/`) no longer mean anything and are ignored.

## Worktree dependency cache + disk guard (`wt-deps.sh`)
Every agent worktree used to run its own `npm ci` (~2.3 GB each); 6 parallel agents filled the Mac disk and a full
host disk fails CI runner jobs and degrades the Mac. Now:
- `wt-deps.sh [dir]` (called by `new-task-worktree.sh`; also runnable alone in any worktree; `WT_SKIP_DEPS=1` skips).
  Key = sha256(lockfile)[:16] + node major + arch. `~/.cache/wt-deps/<repo>/<key>/tree/**/node_modules` holds ONE real
  install (root + every workspace's nested node_modules). New worktrees get `cp -cR` APFS clones (copy-on-write, ~0 disk
  until files change). Miss -> one install in that worktree, snapshot, keep the 2 newest keys per repo. Non-APFS /
  cross-volume -> plain install. node_modules is never symlinked. Existing populated node_modules is left alone
  (`WT_DEPS_FORCE=1` replaces). Lifecycle scripts follow normal npm behaviour; repo-specific steps (e.g. ebda
  `npm run generate -w packages/database`) still run per worktree and only write the files they touch.
- Roots (2026-11-19, `lib/wt-roots.sh`, the ONE resolver): worktrees go to `$OS_WORKTREE_ROOT`, else `/Volumes/Ebda/_worktrees` when that SSD
  is mounted AND writable (`OS_SSD_ROOT` moves the mount point), else `$OS_PROJECTS_DIR/_worktrees`. The wt-deps cache goes to
  `$OS_DEPS_CACHE` (legacy `WT_DEPS_CACHE`), else `/Volumes/Ebda/.cache/wt-deps`, else `~/.cache/wt-deps`, so cache + worktrees share a
  volume and APFS clones work (cross-volume still plain-installs). GitHub runners stay on the internal disk (macOS TCC blocks launchd
  runners from removable volumes). Listers/cleaners (`workspace-hygiene.sh`, `worktree-cleanup.sh`, `post-merge-cleanup.sh`,
  `worktree-report.sh`, the post-merge hook, the trust check) iterate `wt_all_roots` = every EXISTING root, so an unmounted SSD is skipped,
  never an error; `new-task-worktree.sh` then falls back to internal with ONE warning line (only on a machine that has used the SSD).
  Move existing idle trees: `bash ~/.claude/scripts/migrate-worktrees-to-ssd.sh` (dry run) then `--apply [--deps]`: refuses a tree a
  process stands in (lsof), keeps git state (rsync + `git worktree repair`, verified HEAD + status count), leaves a symlink at the old path.
- Disk guard: `new-task-worktree.sh` refuses under 30 GB free on the volume the worktree will be created on (`WT_MIN_FREE_GB`, override once with `WT_FORCE=1`),
  printing top space users + the cleanup command.
- `main-first.sh` fairness (G16): a starved repo's main CI also gets runners by round-robin cancel of other repos' queued PR runs (see the script header); knobs `MAIN_FIRST_FAIR_CAP`, `MAIN_FIRST_FAIR_TOTAL`.
- `os-selftest.sh` (G14) REPORTS each launchd job's non-zero `last exit code`; the fixer is filed by `sched-fail-watch.sh` (every 10 min, no model tokens): a launchd job after 2 distinct failing runs, or a GitHub scheduled workflow (event=schedule, OS org repos) whose newest finished run is red, opens ONE `review-finding` issue (per job/workflow per UTC day, and per failing run id) with the masked log tail / run link and sends one Telegram line via `notify.sh`; a later green/exit-0 run clears the state. Cloudflare cron triggers are NOT covered (no cheap failure signal without a Workers Observability token; `cf-workers-watch` covers deploys + health). Filing goes through `lib/job-failure.sh` `jf_file_issue`.
- `lib/wt-safety.sh` `wt_squash_integrated` (G13): a squash/rebase-merged branch counts as merged when its tree equals a recent main commit, or a MERGED PR's mergeCommit holds byte-identical content for every file the branch changed (so a PR head that moved after merge no longer keeps the worktree); a post-merge commit, a new branch, or a dirty tree still keeps it. Used by `workspace-hygiene.sh` and `worktree-cleanup.sh`.
- `workspace-hygiene.sh` drops node_modules from worktrees whose PR is MERGED even when kept for uncommitted files
  (never one a process stands in), and posts a Telegram alert via `notify.sh` when host free < 30 GB (6 h cooldown,
  stamp `~/.cache/wt-deps/.disk-alert`).

### Every worktree-creation path is caught (2026-10-25)
Full design + grading: `standard/disk-discipline.md`. In short:
- `git-hooks/dispatch.sh` is installed by `install.sh` as every standard hook under `~/.claude/git-hooks` and activated with
  `git config --global core.hooksPath` (never overwrites a different existing value). `post-checkout` runs `wt-deps.sh` on a
  NEW linked worktree; every hook then `exec`s the repo's LOCAL `.git/hooks/<name>` (husky only where `ebda.chainHusky=true`, set by install.sh for Ahmad's repos). Automatic callers run hook-mode `wt-deps.sh`: trusted repos under ~/Desktop/projects only, CLONE-ONLY (a cache miss prints the manual command; no installer ever runs from a hook). A repo with its own
  `core.hooksPath` (husky v9) bypasses the global one - `hooks/post-worktree-deps.sh` (PostToolUse on EnterWorktree and
  Bash `git worktree add`) covers Claude there, and `wt-deps.sh` re-arms husky in the clone.
- `hooks/block-worktree-install.sh` (PreToolUse) denies `npm ci|install` / `pnpm install` / `yarn` in a worktree ONLY on a
  cache hit (`wt-deps.sh --check`); escape hatch `WT_ALLOW_INSTALL=1`. Register with `ops/install-hooks.sh`.

## Dream cycle, self-heal and the brain hand-off (Task 6)

`dream.sh` (daily 08:00; Sundays deep, midweek `--reflect-only`), `dream-reflect.sh`, `dream-standard-drift.sh`, `self-heal.sh`, `heal-watch.sh` and `app-error-heal.sh` run on the Mac and report to the brain, not to a chat. `lib/brain-post.sh` POSTs findings to `$OS_BRAIN_URL/findings` (Bearer `INGEST_TOKEN`, both from `$OS_SERVICES_ENV`); with no brain configured, or when the POST fails, they are appended to `$OS_STATE_DIR/brain-spool.ndjson` and drained on the next successful post. Self-heal services come from `heal_services` in `~/.ebda-os.local.json` (`lib/heal-registry.sh`); the lists are Ebda-only. `dream-standard-drift.sh --reseed` re-proposes, once each, lessons that the previous repo's ledger recorded. The research/scan/act phases of `dream.sh` run when their scripts are installed and are reported `absent` otherwise.
