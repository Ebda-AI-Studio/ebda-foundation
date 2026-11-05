# os/ manifest

The AI OS layer of ebda-foundation: the operating tooling that every business (Ebda AI Studio, Whisky 11, Force AI) runs under. It is ported in from the frozen predecessor at tag `final-before-ebda`; see the freeze note in `docs/history/`.

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
| `standard/`, `audit/`, `schemas/`, `skills/`, `agents/`, `template/`, `vendor/` | Standards, audit lenses, schemas, skills, agents, vendor template. | Task 3 |
| dashboard, command-center app, dream cycle, self-heal and heal-watch, watchers, event listener, page-load monitor, daily brief, companion | The AI-OS components beyond the core. | Task 4 |

`ops/` at the repo root (not under `os/`) is the product-library ops (merge gate, host lock, workflow lint) and is untouched.

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
