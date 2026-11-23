# os/ manifest

The AI OS layer of ebda-foundation: the operating tooling that every business (Ebda AI Studio and its sibling businesses) runs under. It is ported in from the frozen predecessor at tag `final-before-ebda`; see the freeze note in `docs/history/`.

## Layout

| Path | Purpose | State |
|---|---|---|
| `config/os.env` | Single source for the OS identity: repo slug, orgs, launchd prefix, git chain key, state dir, services env path. | present |
| `ops/*.sh`, `ops/lib/`, `ops/hooks/`, `ops/git-hooks/`, `ops/remediation/`, `ops/detectors/`, `ops/journeys/`, `ops/cloud/` | The generic OS core: monitors, guards, installer, merge gate, worktree and runner tooling. | ported (Task 2) |
| `ops/force-purge-check.sh` | Read-only purge readiness: lists, by category with counts, everything on this Mac still tied to the predecessor business. Deletes nothing. Test: `tests/force-purge-check.test.sh`. | new (Task 9) |
| `ops/launchd/com.ebda.os.*.plist` | Scheduled-job templates (`__HOME__` / `__PATH__` tokens, filled by `ops/install.sh`). | ported (Task 2) |
| `ops/lib/os-config.sh` | `os_config_load`: sources `config/os.env`, then `~/.ebda-os.local.env`. | new (Task 2) |
| `ops/lib/keychain.sh` | `keychain_get <service>`: Keychain read with the hex-decode rule (same rule as ebda-store `scripts/cf/lib/keychain.mjs`). | new (Task 2) |
| `ops/tests/`, `ops/lib/__tests__/`, `tests/remediation/` | The ported suites. Run all: `bash os/tests/run-all.sh`. | ported (Task 2) |
| `tests/no-force-strings.test.sh`, `tests/linux-smoke.test.sh`, `tests/run-all.sh` | Predecessor-string guard, Linux `bash -n` + `--help` smoke, one-command runner. | new (Task 2) |
| `standard/` (242 files: the 95-file base set, the 111+ Ebda 2026-10 graded lens standards, `rules/`), `agents/` (25), `skills/` (benchmark-vet, blast-radius, correct, ebda-loop, THIRD-PARTY.md), `schemas/hooks.schema.json`, `vendor/landlock-run/`, `audit/lenses/` (source packs), `template/VENDOR-PROVENANCE.md` | Standards, lens packs, agents, skills, hook schema, vendored Landlock launcher, vendor-provenance template. `skills/force-audit` is NOT ported (open decision in `docs/history/standards/incidents.md`). | ported (Task 3) |
| `config/local.example.json`, `tests/os-local-list.test.sh` | Placeholder shape of the gitignored per-machine `~/.ebda-os.local.json` (repo lists, health domains, originality entities, deploy-drift services) and the test for its reader `os_local_list`. | new (Task 3 fix 1) |
| `tests/standard-links.test.mjs` | Every relative link in `standard/` and `audit/lenses/` resolves. | new (Task 3) |
| `ops/ebda-logs.mjs`, `ops/lib/ebda-logs-core.mjs`, `ops/lib/ebda-logs-r2.mjs`, `ops/ebda-prod-watch.mjs`, `config/prod-watch.json`, `ops/tests/ebda-logs.test.mjs` | Production log reader (R2 `ebda-logs` via api.cloudflare.com, works where `wrangler tail` is ISP-blocked) and the off-Cloudflare prod watch run by `.github/workflows/prod-watch.yml`. Plan + rulings: `docs/plans/2026-11-10-observability.md`. | new (2026-11-10) |
| dashboard, command-center app, dream cycle, self-heal and heal-watch, watchers, event listener, page-load monitor, daily brief, companion | The AI-OS components beyond the core. | Task 4 |

`ops/` at the repo root (not under `os/`) is the product-library ops (merge gate, host lock, workflow lint) and is untouched.

## Carried to later tasks

| Owner | Item | Source |
|---|---|---|
| Task 6 | Brain alert after N consecutive nightly hands runs in which every job came back `skipped_usage` (a broken usage probe otherwise boots a container every night, refuses and re-queues silently). One message, deduped, through the brain's Telegram policy. | Ruling 4b-6 (`.superpowers/.../task-4b-report.md`), 4b review design note (b) |
| Task 7 | Keep the Mac hands runner (`os/cloud/hands/providers/mac-local.sh`) off repos whose findings carry third-party text until the container path is live. | Ruling 4b-5 |

`os/cloud/brain/` (Worker) and `os/cloud/hands/` (container image, run-batch, providers) are documented in their own READMEs.

## Ported counts (files under `os/ops` and `os/tests`)

| Dir | Files |
|---|---|
| `ops/*.sh` + docs/assets | 111 |
| `ops/lib/` | 59 (+ 50 in `lib/__tests__/`) |
| `ops/tests/` | 33 (+ 2 fixtures) |
| `ops/hooks/` | 10 |
| `ops/git-hooks/` | 1 |
| `ops/remediation/` | 8 |
| `ops/launchd/` | 35 |
| `ops/detectors/` | 10 |
| `ops/journeys/`, `ops/cloud/` | 2 + 2 |
| `tests/remediation/` | 16 (+ 3 new top-level files: string guard, Linux smoke, run-all) |

## Not ported (and why)

- Client or finance data, never moved: client DB backup scripts and plists, the per-client cost model and its client list, the fleet store list (replaced by `config/fleet.example.json`), the bookkeeping app, client store journeys and the client-store monitors with their fixtures and tests. The nightly managed Postgres project list is now read from a per-machine file (`~/.ebda-os.local.backup-projects`) instead of living in the repo.
- Suites trimmed with their subjects: the client-store and bookkeeping cases of the monitors-unreachable suite, the backup-alerts suite (it pins the client project list), the cost-attribution suite, and the event-listener, findings-watch and watchers remediation suites (Task 4 components).
- Task 4 components (also `ops/lib/heal-registry.json`): dashboard, command-center app, dream cycle (`dream*`), self-heal, `heal-*`, `watchers/`, event listener, page-load monitor and its journeys, daily brief.

## Folded open PRs from the predecessor

Applied to the ported files (all generic): #279 guard rebuild backoff, #278 hygiene orphan tests dirs, #275 guest autoheal, #274 start uses fsck if dirty, #264 usage sentinel (script, hook, plist, python engine, test; its `standard/` page goes with Task 3), #263 merge-gate rebase-needed. Not folded: #280 (org-slug rename, superseded by `config/os.env`), #276 and #262 (audit and standard content, Task 3).

## Declared-pending suites (Task 3)

`ops/tests-pending.list` names four suites that need Task 3 content (`agents/`, `template/`, `skills/`, `schemas/`). `run-tests.sh` prints each as SKIP and counts it; Task 3 removes a line when its suite goes green.

## shellcheck baseline

`shellcheck -S warning` on `ops/*.sh ops/lib/*.sh ops/hooks ops/git-hooks ops/remediation` is clean. Real defects found while porting were fixed (SC2318, SC2222, SC2140, SC2088, a bare empty-array expansion) and every SC2164 site now reads `cd ... || exit 1` (or `|| return 1` inside functions). Five stylistic classes the predecessor carried are still suppressed in `os/.shellcheckrc` with their counts (SC2034 39, SC1090 10, SC2207 7, SC2155 7, SC2010 2) so the gate fails on NEW problems; burn them down per file.

## Config contract

`config/os.env` is the single source; `ops/lib/os-config.sh` (`os_config_load`) reads it, then `~/.ebda-os.local.env`, then falls back to built-in defaults that `tests/os-config-parity.test.sh` keeps identical. Every script that needs an identity value (primary org `$OS_ORG`, owners `$OS_ORGS`, `$OS_REPO_SLUG`, `$OS_PROJECTS_DIR`, `$OS_HOME`, `$OS_LAUNCHD_PREFIX`, `$OS_SENTRY_ORG`, `$OS_PERSONAL_OWNER`, `$OS_SERVICES_ENV`) sources it and reads the key. `tests/no-literal-config.test.sh` fails when a literal of those values appears in `ops/` outside tests, fixtures, launchd templates, docs, comments and `os-config.sh`.

## Secret scanning

`gitleaks detect --source .` over the whole branch history reports no leaks, so no `.gitleaksignore` is needed (none exists). If a fixture ever trips it, add that fingerprint only.

## CI footprint added

One job (`os`) in `ci.yml`: a checkout plus one `git diff` on every PR (about 10 s). When `os/` or the workflow changed (and on every push to main) it also runs shellcheck and `os/tests/run-all.sh --quiet` (string and identity-literal guards, config parity, the ops suites, Linux smoke). Measured locally about 9 min on macOS for the suites; budget 25 min per run, so roughly 10 to 15 billable minutes on a hosted runner, or none on the native Mac runners (`EBDA_RUNS_ON`). PRs that do not touch `os/` pay only the diff step.

## macOS-only scripts

These touch launchd, the Keychain `security` tool, `sw_vers`, `xcrun` or similar; the Linux smoke parses them (`bash -n`) but skips `--help`: `ci-runner-guard.sh`, `ecosystem-research-cron.sh`, `os-selftest.sh`, `hung-job-guard.sh`, `install.sh`, `reload-patched-agents.sh`, `statusline.sh`, `runner-restore.sh`, `uninstall.sh`, `lib/job-freshness.sh`, `lib/keychain.sh`.

## Rules for anything ported here

- Read identity and paths from `config/os.env` (via `ops/lib/os-config.sh`); never hard-code a slug, org, launchd label or state path.
- No product, client or customer names outside `docs/history/` (`tests/no-force-strings.test.sh` enforces it).
- Secrets never enter the repo; they live in `OS_SERVICES_ENV`. Telegram helpers read `TELEGRAM_BOT_TOKEN` and `TELEGRAM_ALERT_CHAT_ID` from there.
- A multi-line Keychain secret is read only through `keychain_get`.
- Launchd labels use the `com.ebda.os.` prefix.

Layering and cost-if-wrong: `docs/rulings/FDN-OS-1.md`.

## Installer and the launchd set (Task 5, Amendment A)

`os/install.sh [--dry-run] [--home DIR]` installs the Mac-local part only; the job list is `launchd/mac-local.list` (36 jobs, counted from the file; hands-mac-local is opt-in via the third column `optin=OS_HANDS_LOCAL` and skipped unless `OS_HANDS_LOCAL=1`, ruling INSTALL-1; table below). It copies `ops/**` to `~/.claude/scripts`, `config/os.env` to `~/.claude/os.env`, renders the plists, links `agents/*.md` and `skills/*` from a main-branch checkout, sets `core.hooksPath` and the `OS_GIT_CHAIN_KEY` flag on trusted husky repos, and registers the hooks (`ops/install-hooks.sh`). It refuses while any previous-prefix label is loaded (`run os/cutover.sh`) and removes its own plists that are no longer in the set. `ops/install.sh` is now a one-line shim to it.


## Old-job dispositions (Task 5 fix round 1)

Every job the previous OS ran (the 34 plist templates plus `launchd/unported-jobs.list`) has exactly one row. `ops/cutover-gate-check.sh` parses this table: KEEP-MAC detail = suffix in `launchd/mac-local.list` (or `pending-task-6` until its script lands), PORT-BRAIN detail = watcher id that must exist as `cloud/brain/src/watchers/<id>.ts`, REPLACED-BY detail = a path under `os/` that must exist, DROP needs a reason.

| Job | Disposition | Detail | Reason |
|---|---|---|---|
| acceptance-feedback | KEEP-MAC | acceptance-feedback | reads and writes local feedback files |
| alert-triage | REPLACED-BY | cloud/brain/src/classify.ts | brain classifies findings (urgent vs pre-approved) |
| anomaly-watch | DROP | - | Ahmad 2026-11-06: Force products only |
| audit-pack-daily | KEEP-MAC | audit-pack-daily | assembles the audit pack from local repos |
| social-content | KEEP-MAC | social-content | daily Facebook + LinkedIn drafts for both brands (claude -p + headless Chrome render); the brain gates and publishes (docs/plans/2026-11-11-social-posting.md) |
| cf-workers-watch | PORT-BRAIN | cf-workers | HTTP/API poll of Cloudflare Workers state; brain health.ts covers only 2 URLs |
| ci-alert | REPLACED-BY | cloud/brain/src/relay.ts | CI failures arrive as signed webhooks into the brain relay inbox |
| ci-runner-guard | KEEP-MAC | ci-runner-guard | reports native Mac runner fleet health from the GitHub API |
| main-first | KEEP-MAC | main-first | cancels superseded main CI runs + queued PR runs so a starved main CI gets a heavy runner (+ batch-first: only the drain's next PRs keep their queued runs) (gh API, local ledger, every 5 min) |
| claude-home-export | DROP | - | Ahmad 2026-11-09 turned it off: it wrote a 300 MB tgz to the Desktop every day |
| cost-guard | PORT-BRAIN | cost-guard | billing API poll |
| dead-gate-detect | KEEP-MAC | dead-gate-detect | inspects locally installed hooks and gates |
| deploy-drift | PORT-BRAIN | deploy-drift | compares live /health commit with main over HTTP |
| drain-ebda-store | KEEP-MAC | drain-ebda-store | durable merge loop (`ops/drain.sh`, risky-PR hold, off until `~/.whisky-os-state/drain/ebda-store.enabled` exists) |
| drain-ebda-foundation | KEEP-MAC | drain-ebda-foundation | same loop for this repo with the 6 required checks (`DRAIN_REQUIRED_JSON`) |
| docs-scan | KEEP-MAC | docs-scan | scans local checkouts |
| dr-drill | PORT-BRAIN | dr-drill | checks the age of the last restore-drill PASS (digest after 8 days, one P1 after 14); the drill itself is `restore-drill` below (ruling F-I6) |
| restore-drill | KEEP-MAC | restore-drill | the weekly restore drill needs R2 + age secrets the hands container must not hold; `ops/restore-drill.sh` posts PASS/FAIL to the brain `POST /drill` |
| drift-watch | KEEP-MAC | drift-watch | diffs installed copies against the repo on disk |
| isp-188-watch | KEEP-MAC | isp-188-watch | hourly DoH check that every merchant-facing host resolves outside 188.114.96.0/23 (blocked by the Egyptian ISP, launch map ISP-188); posts `isp-block-range` findings to the brain, skips when nothing changed |
| ebda-cf-backup | DROP | - | Ruling CF-BACKUP-1 (Ahmad 2026-11-11): GitHub cf-backup.yml (02:17) is the backup; app.ebda.cf-backup-pull keeps the local copy |
| ebda-foundation-bump | KEEP-MAC | ebda-foundation-bump | git operations in local checkouts |
| fleet-dep-audit | KEEP-MAC | fleet-dep-audit | runs npm audit inside local checkouts |
| gate-guard | KEEP-MAC | gate-guard | checks gates against local runner and checkouts |
| ghas-guard | DROP | - | Ahmad 2026-11-06: GitHub Advanced Security is never used |
| graph-backfill | KEEP-MAC | graph-backfill | runs graphify and claude over local files |
| hung-job-guard | KEEP-MAC | hung-job-guard | kills hung scheduled jobs |
| instinct-extract | KEEP-MAC | instinct-extract | claude CLI over local sessions |
| journey-monitor | PORT-BRAIN | journey-monitor | synthetic HTTP journey checks |
| mac-maintenance | KEEP-MAC | mac-maintenance | local disk upkeep |
| os-selftest | KEEP-MAC | os-selftest | checks the local install |
| os-watch | KEEP-MAC | os-watch | self-check of the local OS runtime and runner status |
| outside-watch | KEEP-MAC | outside-watch | every 5 min curl probe of the public Ebda hosts from the Mac (off Cloudflare), 2-failure rule, alerts via notify.sh (replaces the disabled hosted prod-watch workflow, F-OBS-1) |
| claude-bundle-sync | KEEP-MAC | claude-bundle-sync | keeps the Claude Code app bundle linked to the newest build so macOS keeps one permission identity; Mac-only by nature (ruling INSTALL-1) |
| pr-shepherd | KEEP-MAC | pr-shepherd | the brain watcher shepherds the brain's orgs; the Mac job covers ONE other org set per machine (`OS_PR_SHEPHERD_ORG`), skips when unset or equal to the brain's org (ruling INSTALL-1) |
| sched-fail-watch | KEEP-MAC | sched-fail-watch | every 10 min: a launchd job (2 consecutive failing runs) or a GitHub scheduled workflow that fails opens ONE review-finding fixer issue per job/day + one Telegram line via notify.sh; no tokens when nothing failed; reads launchctl + the gh API (Cloudflare cron triggers not covered, see the script header) |
| sentry-stale-watch | KEEP-MAC | sentry-stale-watch | stays on the Mac until the brain's `sentry-stale` is configured for the same Sentry org; then a later PR may drop it (ruling INSTALL-1) |
| services-watch | PORT-BRAIN | services | HTTP probes; brain health.ts covers only 2 URLs |
| session-mining | KEEP-MAC | session-mining | claude CLI over local session files |
| usage-sentinel | KEEP-MAC | usage-sentinel | reads local Claude usage |
| workspace-hygiene | KEEP-MAC | workspace-hygiene | local worktrees and disk |
| world-watch | PORT-BRAIN | world-watch | HTTP poll of external sources |
| dream | KEEP-MAC | dream | dream cycle runs the Claude CLI over local memory; findings go to the brain job queue, no messages |
| dream-scan | KEEP-MAC | dream | Ebda product scan (deps, npm audit, untested paths, failing CI, live probes) runs as the first phase of the dream job; `ops/dream-scan.sh`, targets from `dream_products` (fields name, path, url, owner/name; repos in the brain orgs skip npm audit + CI, which the brain already watches) |
| dream-research | KEEP-MAC | dream | ranks the week's scan history into `improvement` findings per product; `ops/dream-research.sh`, second phase of the dream job |
| dream-act | REPLACED-BY | cloud/brain/src/brain-do.ts | the brain job queue: dream findings are POSTed to /findings and the hands do the work |
| dream-fix | REPLACED-BY | cloud/brain/src/brain-do.ts | the hands (nightly run) apply the fix, replacing the local auto-fix dispatcher |
| reflect | KEEP-MAC | reflect | reflect phase of the dream cycle (dream.sh --reflect-only, midweek), same Mac-only inputs |
| daily-brief | REPLACED-BY | cloud/brain/src/brain-do.ts | brain digest alarm (digest) sends the daily message |
| page-load-monitor | PORT-BRAIN | page-load | fetch-based page checks, always-on |
| self-heal | KEEP-MAC | heal-watch | heals services through the redeploy and rollback recipes; launched by heal-watch.sh, reports to the brain |
| heal-watch | KEEP-MAC | heal-watch | watches the heal ledger on local disk; probes the services listed in the local config |
| findings-watch | REPLACED-BY | cloud/brain/src/findings.ts | brain ingests and queues findings |
| app-error-heal | KEEP-MAC | app-error-heal | runs the Sentry class checks from the Mac; findings go to the brain |
| event-listener | REPLACED-BY | cloud/brain/src/relay.ts | signed relay events, drained through /pending |
| dashboard | REPLACED-BY | cloud/brain/public/dash | brain serves the dashboard |
| code-health | KEEP-MAC | code-health | knip/jscpd and the claude judgment pass over local checkouts |
| cost-attribution | DROP | - | per-client cost model was client finance data and was not ported |
| runner-hook-health | KEEP-MAC | runner-hook-health | checks runner hooks on this host |
| predecessor-client-backup-1 | DROP | - | Ahmad 2026-11-06: Force client database backup |
| predecessor-client-backup-2 | DROP | - | Ahmad 2026-11-06: Force client database backup |
| predecessor-product-monitor-1 | DROP | - | Ahmad 2026-11-06: Force product monitor |
| predecessor-product-monitor-2 | DROP | - | Ahmad 2026-11-06: Force product monitor |

Rule (Ahmad 2026-11-06): the Ebda OS never backs up, monitors or alerts on the predecessor business's products (named jobs are in docs/history). A job that exists only for those products or their clients is DROP; a job that watches both keeps only its Ebda/Whisky targets, read from `~/.ebda-os.local.json` lists.
