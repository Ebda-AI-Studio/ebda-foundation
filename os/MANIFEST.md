# os/ manifest

The AI OS layer of ebda-foundation: the operating tooling that every business (Ebda AI Studio and its sibling businesses) runs under. It is ported in from the frozen predecessor at tag `final-before-ebda`; see the freeze note in `docs/history/`.

## Layout

| Path | Purpose | State |
|---|---|---|
| `config/os.env` | Single source for the OS identity: repo slug, orgs, launchd prefix, git chain key, state dir, services env path. | present |
| `ops/*.sh`, `ops/lib/`, `ops/hooks/`, `ops/git-hooks/`, `ops/remediation/`, `ops/detectors/`, `ops/journeys/`, `ops/cloud/` | The generic OS core: monitors, guards, installer, merge gate, worktree and runner tooling. | ported (Task 2) |
| `ops/launchd/com.ebda.os.*.plist` | Scheduled-job templates (`__HOME__` / `__PATH__` tokens, filled by `ops/install.sh`). | ported (Task 2) |
| `ops/lib/os-config.sh` | `os_config_load`: sources `config/os.env`, then `~/.ebda-os.local.env`. | new (Task 2) |
| `ops/lib/keychain.sh` | `keychain_get <service>`: Keychain read with the hex-decode rule (same rule as ebda-store `scripts/cf/lib/keychain.mjs`). | new (Task 2) |
| `ops/tests/`, `ops/lib/__tests__/`, `tests/remediation/` | The ported suites. Run all: `bash os/tests/run-all.sh`. | ported (Task 2) |
| `tests/no-force-strings.test.sh`, `tests/linux-smoke.test.sh`, `tests/run-all.sh` | Predecessor-string guard, Linux `bash -n` + `--help` smoke, one-command runner. | new (Task 2) |
| `standard/` (242 files: the 95-file base set, the 111+ Ebda 2026-10 graded lens standards, `umbra-guest-integrity`, `rules/`), `agents/` (25), `skills/` (benchmark-vet, blast-radius, correct, THIRD-PARTY.md), `schemas/hooks.schema.json`, `vendor/landlock-run/`, `audit/lenses/` (source packs), `template/VENDOR-PROVENANCE.md` | Standards, lens packs, agents, skills, hook schema, vendored Landlock launcher, vendor-provenance template. `skills/force-audit` is NOT ported (open decision in `docs/history/standards/incidents.md`). | ported (Task 3) |
| `config/local.example.json`, `tests/os-local-list.test.sh` | Placeholder shape of the gitignored per-machine `~/.ebda-os.local.json` (repo lists, health domains, originality entities, deploy-drift services) and the test for its reader `os_local_list`. | new (Task 3 fix 1) |
| `tests/standard-links.test.mjs` | Every relative link in `standard/` and `audit/lenses/` resolves. | new (Task 3) |
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

- Client or finance data, never moved: client DB backup scripts and plists, the per-client cost model and its client list, the fleet store list (replaced by `config/fleet.example.json`), the bookkeeping app, client store journeys and the client-store monitors with their fixtures and tests. The nightly Neon project list is now read from a per-machine file (`~/.ebda-os.local.backup-projects`) instead of living in the repo.
- Suites trimmed with their subjects: the client-store and bookkeeping cases of the monitors-unreachable suite, the backup-alerts suite (it pins the client project list), the cost-attribution suite, and the event-listener, findings-watch and watchers remediation suites (Task 4 components).
- Task 4 components (also `ops/lib/heal-registry.json`): dashboard, command-center app, dream cycle (`dream*`), self-heal, `heal-*`, `watchers/`, event listener, page-load monitor and its journeys, daily brief.

## Folded open PRs from the predecessor

Applied to the ported files (all generic): #279 guard rebuild backoff, #278 hygiene orphan tests dirs, #275 guest autoheal, #274 start uses fsck if dirty, #264 usage sentinel (script, hook, plist, python engine, test; its `standard/` page goes with Task 3), #263 merge-gate rebase-needed. Not folded: #280 (org-slug rename, superseded by `config/os.env`), #276 and #262 (audit and standard content, Task 3).

## Declared-pending suites (Task 3)

`ops/tests-pending.list` names four suites that need Task 3 content (`agents/`, `template/`, `skills/`, `schemas/`). `run-tests.sh` prints each as SKIP and counts it; Task 3 removes a line when its suite goes green.

## shellcheck baseline

`shellcheck -S warning` on `ops/*.sh ops/lib/*.sh ops/hooks ops/git-hooks ops/remediation` is clean. Real defects found while porting were fixed (SC2318, SC2222, SC2140, SC2088, a bare empty-array expansion) and every SC2164 site now reads `cd ... || exit 1` (or `|| return 1` inside functions). Five stylistic classes the predecessor carried are still suppressed in `os/.shellcheckrc` with their counts (SC2034 39, SC1090 10, SC2207 7, SC2155 7, SC2010 2) so the gate fails on NEW problems; burn them down per file.

## Config contract

`config/os.env` is the single source; `ops/lib/os-config.sh` (`os_config_load`) reads it, then `~/.ebda-os.local.env`, then falls back to built-in defaults that `tests/os-config-parity.test.sh` keeps identical. Every script that needs an identity value (primary org `$OS_ORG`, owners `$OS_ORGS`, `$OS_REPO_SLUG`, `$OS_PROJECTS_DIR`, `$OS_HOME`, `$OS_LAUNCHD_PREFIX`, `$OS_UMBRA_VMS` / `$OS_VM`, `$OS_SENTRY_ORG`, `$OS_NEON_ORG`, `$OS_PERSONAL_OWNER`, `$OS_SERVICES_ENV`) sources it and reads the key. `tests/no-literal-config.test.sh` fails when a literal of those values appears in `ops/` outside tests, fixtures, launchd templates, docs, comments and `os-config.sh`.

## Secret scanning

`gitleaks detect --source .` over the whole branch history reports no leaks, so no `.gitleaksignore` is needed (none exists). If a fixture ever trips it, add that fingerprint only.

## CI footprint added

One job (`os`) in `ci.yml`: a checkout plus one `git diff` on every PR (about 10 s). When `os/` or the workflow changed (and on every push to main) it also runs shellcheck and `os/tests/run-all.sh --quiet` (string and identity-literal guards, config parity, the ops suites, Linux smoke). Measured locally about 9 min on macOS for the suites; budget 25 min per run, so roughly 10 to 15 billable minutes on a hosted runner, or none on the Umbra runner (`EBDA_RUNS_ON`). PRs that do not touch `os/` pay only the diff step.

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

`os/install.sh [--dry-run] [--home DIR]` installs the Mac-local part only; the job list is `launchd/mac-local.list` (24 jobs: 23 KEEP-MAC plus the new hands-mac-local; table below). It copies `ops/**` to `~/.claude/scripts`, `config/os.env` to `~/.claude/os.env`, renders the plists, links `agents/*.md` and `skills/*` from a main-branch checkout, sets `core.hooksPath` and the `OS_GIT_CHAIN_KEY` flag on trusted husky repos, and registers the hooks (`ops/install-hooks.sh`). It refuses while any previous-prefix label is loaded (`run os/cutover.sh`) and removes its own plists that are no longer in the set. `ops/install.sh` is now a one-line shim to it.


## Old-job dispositions (Task 5 fix round 1)

Every job the previous OS ran (the 34 plist templates plus `launchd/unported-jobs.list`) has exactly one row. `ops/cutover-gate-check.sh` parses this table: KEEP-MAC detail = suffix in `launchd/mac-local.list` (or `pending-task-6` until its script lands), PORT-BRAIN detail = watcher id that must exist as `cloud/brain/src/watchers/<id>.ts`, REPLACED-BY detail = a path under `os/` that must exist, DROP needs a reason.

| Job | Disposition | Detail | Reason |
|---|---|---|---|
| acceptance-feedback | KEEP-MAC | acceptance-feedback | reads and writes local feedback files |
| alert-triage | REPLACED-BY | cloud/brain/src/classify.ts | brain classifies findings (urgent vs pre-approved) |
| anomaly-watch | DROP | - | Ahmad 2026-11-06: Force products only |
| audit-pack-daily | KEEP-MAC | audit-pack-daily | assembles the audit pack from local repos |
| cf-workers-watch | PORT-BRAIN | cf-workers | HTTP/API poll of Cloudflare Workers state; brain health.ts covers only 2 URLs |
| ci-alert | REPLACED-BY | cloud/brain/src/relay.ts | CI failures arrive as signed webhooks into the brain relay inbox |
| ci-runner-guard | KEEP-MAC | ci-runner-guard | drives Umbra and the runner service |
| claude-home-export | KEEP-MAC | claude-home-export | exports local ~/.claude state |
| cost-guard | PORT-BRAIN | cost-guard | billing API poll |
| dead-gate-detect | KEEP-MAC | dead-gate-detect | inspects locally installed hooks and gates |
| deploy-drift | PORT-BRAIN | deploy-drift | compares live /health commit with main over HTTP |
| docs-scan | KEEP-MAC | docs-scan | scans local checkouts |
| dr-drill | PORT-BRAIN | dr-drill | weekly restore-drill trigger; API calls only |
| drift-watch | KEEP-MAC | drift-watch | diffs installed copies against the repo on disk |
| ebda-cf-backup | KEEP-MAC | ebda-cf-backup | pulls the Cloudflare backup to local disk |
| ebda-foundation-bump | KEEP-MAC | ebda-foundation-bump | git operations in local checkouts |
| fleet-dep-audit | KEEP-MAC | fleet-dep-audit | runs npm audit inside local checkouts |
| gate-guard | KEEP-MAC | gate-guard | checks gates against local runner and checkouts |
| ghas-guard | DROP | - | Ahmad 2026-11-06: GitHub Advanced Security is never used |
| graph-backfill | KEEP-MAC | graph-backfill | runs graphify and claude over local files |
| guest-wedge-watch | KEEP-MAC | guest-wedge-watch | Umbra guest wedge detection |
| hung-job-guard | KEEP-MAC | hung-job-guard | kills hung runner jobs via Umbra |
| instinct-extract | KEEP-MAC | instinct-extract | claude CLI over local sessions |
| journey-monitor | PORT-BRAIN | journey-monitor | synthetic HTTP journey checks |
| mac-maintenance | KEEP-MAC | mac-maintenance | local disk and Umbra upkeep |
| os-selftest | KEEP-MAC | os-selftest | checks the local install |
| os-watch | KEEP-MAC | os-watch | self-check of the local OS runtime and Umbra |
| pr-shepherd | PORT-BRAIN | pr-shepherd | GitHub API poll of open PRs |
| sentry-stale-watch | PORT-BRAIN | sentry-stale | Sentry API poll |
| services-watch | PORT-BRAIN | services | HTTP probes; brain health.ts covers only 2 URLs |
| session-mining | KEEP-MAC | session-mining | claude CLI over local session files |
| usage-sentinel | KEEP-MAC | usage-sentinel | reads local Claude usage |
| workspace-hygiene | KEEP-MAC | workspace-hygiene | local worktrees, disk and Umbra prune |
| world-watch | PORT-BRAIN | world-watch | HTTP poll of external sources |
| dream | KEEP-MAC | pending-task-6 | dream cycle runs the Claude CLI over local memory; script lands in Task 6 |
| reflect | KEEP-MAC | pending-task-6 | reflect phase of the dream cycle, same Mac-only inputs; Task 6 |
| daily-brief | REPLACED-BY | cloud/brain/src/brain-do.ts | brain digest alarm (digest) sends the daily message |
| page-load-monitor | PORT-BRAIN | page-load | fetch-based page checks, always-on |
| self-heal | KEEP-MAC | pending-task-6 | heals Mac services through the Claude CLI; Task 6 |
| heal-watch | KEEP-MAC | pending-task-6 | watches the heal ledger on local disk; Task 6 |
| findings-watch | REPLACED-BY | cloud/brain/src/findings.ts | brain ingests and queues findings |
| app-error-heal | KEEP-MAC | pending-task-6 | runs the Claude CLI against app errors; Task 6 |
| event-listener | REPLACED-BY | cloud/brain/src/relay.ts | signed relay events, drained through /pending |
| dashboard | REPLACED-BY | cloud/brain/public/dash | brain serves the dashboard |
| code-health | KEEP-MAC | code-health | knip/jscpd and the claude judgment pass over local checkouts |
| cost-attribution | DROP | - | per-client cost model was client finance data and was not ported |
| runner-hook-health | KEEP-MAC | runner-hook-health | checks runner hooks on this host |
| neon-backup | DROP | - | Ahmad 2026-11-06: only Force/client Neon databases; the Ebda OS never backs up Force products |
| predecessor-client-backup-1 | DROP | - | Ahmad 2026-11-06: Force client database backup |
| predecessor-client-backup-2 | DROP | - | Ahmad 2026-11-06: Force client database backup |
| predecessor-product-monitor-1 | DROP | - | Ahmad 2026-11-06: Force product monitor |
| predecessor-product-monitor-2 | DROP | - | Ahmad 2026-11-06: Force product monitor |

Rule (Ahmad 2026-11-06): the Ebda OS never backs up, monitors or alerts on the predecessor business's products (named jobs are in docs/history). A job that exists only for those products or their clients is DROP; a job that watches both keeps only its Ebda/Whisky targets, read from `~/.ebda-os.local.json` lists.
