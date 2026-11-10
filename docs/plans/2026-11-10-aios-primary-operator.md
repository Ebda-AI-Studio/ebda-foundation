# 2026-11-10 The AI OS is the primary DevOps operator; Ahmad is the backup

Ahmad (2026-11-10): "the Whisky AI OS is the main DevOps and the one here to solve everything, and I'm the backup person."

## Finish line

- **Must work:** the brain is the one place that knows production state (prod-watch reports its complete listing every 10 min)
  and, once a read token exists, CI state; the hands can act on a finding by opening a PR, never more.
- **Exercised:** `POST /findings {findings, reconcile}`, `POST|DELETE /leases`, `GET /hands/leases`, the hands dry run on a real
  finding (Semgrep red on ebda-store main, run 42833927550 @911ba7f), `deploy.sh --dry-run` rendering the watcher config.
- **Must not change:** the brain stays halted (`HANDS_HALT=1`, `HANDS_PROVIDER=stub`) until Ahmad flips it; prod-watch keeps
  owning Telegram alerts (ruling OBS-2); no predecessor-prefix launchd job touched by this change.
- **Done =** brain + hands + ops suites green in CI, PR open, the Ahmad-only list below exact.

## Inventory (measured 2026-11-10 ~21:15Z)

| component | state | needs |
|---|---|---|
| brain Worker `ebda-os-brain` (os.ebda.app) | ON, `/health` ok, last deploy 2026-11-09 20:16Z | - |
| watcher `health` (api + ebda.app) | ON | - |
| watcher `dr-drill` | ON (freshness only; no drill has posted) | Mac restore drill + `INGEST_TOKEN` on the Mac |
| watchers `page-load`, `journey`, `world-watch` (npm half) | OFF | vars only: now committed in `os/config/brain-watchers.json` |
| watcher `services` | OFF on purpose | prod-watch probes the same URLs from outside Cloudflare (OBS-1) |
| watcher `deploy-drift` | OFF on purpose | ruling AIOS-3 |
| watchers `ci-catchup`, `pr-shepherd`, `advisories`, `cost-guard` (GitHub half) | OFF | `GITHUB_TOKEN` (Ahmad) + `HANDS_CONFIG_JSON` (now committed) |
| watchers `cf-workers`, `cf-usage`, `cost-guard` (CF half) | OFF | `CF_API_TOKEN` (Ahmad); `CF_ACCOUNT_ID` var now rendered |
| watcher `sentry-stale` | OFF | Sentry token + org/projects (Ahmad, optional) |
| GitHub webhook -> `/github/webhook` | OFF | `admin:org_hook` scope (Ahmad) |
| hands | OFF (stub provider, halted) | `HANDS_GH_TOKEN`, Claude auth, then un-halt |
| hands merge rule | auto-merged pre-approved classes (violated HANDS-COORD) | fixed here: PRs only |
| prod-watch -> brain | wired in code, never posted (`EBDA_OS_INGEST_TOKEN` unset; the brain's `INGEST_TOKEN` value is stored nowhere locally) | one token (Ahmad) |
| Mac `drift-watch` (Ebda version) | silently dead: looked for `$OS_HOME/ops`, the OS lives in `os/ops` | fixed here |
| Mac launchd | renamed to `com.ebda.os.*` by the controller's other agent (36 loaded) but still running the pre-Ebda scripts in `~/.claude/scripts` | full `os/install.sh` cutover (Ahmad / controller decision, see below) |

## Mac jobs after the rename (controller's other agent renamed 36 jobs to `com.ebda.os.*`)

- The Ebda `os/ops/launchd/` templates were already `com.ebda.os.*` with `ebda-os-<name>.log`; nothing to rename in the repo.
  What kept the checkers on the old set is that `~/.claude/scripts` still holds the pre-Ebda scripts (the installed
  `drift-watch.sh` reads the predecessor foundation's templates). The Ebda `drift-watch.sh` itself was dead
  (`$OS_HOME/ops` does not exist) and expected every template installed; fixed + `ops/tests/drift-watch-paths.test.sh`.
  It goes live with the `os/install.sh` cutover (Ahmad-only item 7).
- `com.ebda.os.ci-runner-guard` exit 1 (measured): the INSTALLED (pre-Ebda) guard watches the predecessor org's repos; the
  fleet is parked (CI-PAUSE-UMBRA-1) and one of those repos still has `USE_SELF_HOSTED=true`, so the guard reports "CI will
  queue forever" and exits 1 on every run, by design (its log is `/tmp/ci-runner-guard.log`, not the empty `.err`). Fix: set
  that repo variable to false (outside this org: Ahmad's call), or the install cutover, after which the Ebda guard watches
  ebda-store / ebda-whatsapp / ebda-studio instead.

## Rulings

Ruling AIOS-1 - The hands open PRs and stop; they never merge and never deploy (`HANDS_MAY_MERGE = false`, a code constant, not
a var). Evidence: launch-map row HANDS-COORD; the ported hands merged pre-approved classes on a green gate. Cost if wrong: dependency
and docs fixes wait for a human or controller merge instead of landing overnight.

Ruling AIOS-2 - Money, auth, deploy-config and production-data findings are a Telegram question for Ahmad, never a hands job,
unless he answers `proceed`. Evidence: Ahmad is the backup for exactly these calls; the brain already routed them to the question
lane, the hands now refuse them too (defence in depth). Cost if wrong: a sensitive but trivial fix waits for one Telegram answer.

Ruling AIOS-3 - `deploy-drift` stays unconfigured. Evidence: every ebda-store deploy workflow is path-filtered, so a Worker's
`/health` commit lagging `main` is normal (accounts reported dff49c9 while main was ccb71ce, measured); the watcher would page on
healthy state. Cost if wrong: a deploy that silently did not happen is caught by prod-watch / the CI watcher, not by drift.

Ruling AIOS-4 - A controller lease (max 240 min, self-expiring) keeps the hands out of a repo; unreadable leases or an unreadable
open-PR listing mean the hands touch nothing. Evidence: two writers in one repo was the coordination failure HANDS-COORD names.
Cost if wrong: a brain outage pauses the hands (they fail closed) until it is back.

Ruling AIOS-5 - prod-watch's brain report is part of the run: once wired, a refused or failed POST is a watch gap (run red),
but an unset `EBDA_OS_INGEST_TOKEN` stays a skip. Evidence: OBS-3 (a declared-but-unwired gate fails open) vs. a red run every
10 min until Ahmad's one command lands. Cost if wrong: until the token is set the brain silently lacks production state; the
inventory above and the PR say so.

## Escalation

Primary operator = the AI OS (brain + hands + prod-watch). Human backup = Ahmad, reached ONLY through Telegram
(@EbdaAIStudiobot, chat 1943728711): unhealed P1s, one daily digest, and questions (money / auth / prod data / destructive).

## Ahmad-only (exact)

1. Brain ingest token (prod-watch + Mac -> brain): `T=$(openssl rand -hex 32)`; `printf %s "$T" | wrangler secret put INGEST_TOKEN --name ebda-os-brain`
   (personal CF account); `gh secret set EBDA_OS_INGEST_TOKEN -R Ebda-AI-Studio/ebda-foundation --body "$T"`; append
   `OS_BRAIN_URL=https://os.ebda.app` and `INGEST_TOKEN=$T` to `~/.whisky-services.env`.
2. GitHub fine-grained token, resource owner **Ebda-AI-Studio**, repos ebda-store, ebda-whatsapp, ebda-foundation, ebda-studio:
   read-only Actions, Contents, Metadata, Pull requests, Dependabot alerts; org permission Administration: read (billing for
   cost-guard). -> `wrangler secret put GITHUB_TOKEN --name ebda-os-brain`.
3. Cloudflare API token (personal account, read-only): Account Analytics:Read + Workers Scripts:Read. ->
   `wrangler secret put CF_API_TOKEN --name ebda-os-brain`.
4. Org webhook: `gh auth refresh -h github.com -s admin:org_hook`, then point an Ebda-AI-Studio org webhook (workflow_run) at
   `https://os.ebda.app/github/webhook` with the existing `GH_WEBHOOK_SECRET`.
5. After merge: `bash os/cloud/brain/scripts/deploy.sh` (renders the committed watcher config + HANDS_CONFIG_JSON).
6. Only when the dry run convinces you: a second fine-grained token (same owner + repos) with Contents + Pull requests WRITE as
   `HANDS_GH_TOKEN`, Claude auth for the hands, then `HANDS_HALT=0`.
7. Mac cutover decision: `os/install.sh` copies the Ebda `os/ops` over `~/.claude/scripts` and boots out every `com.ebda.os.*`
   label not in `os/launchd/mac-local.list` (13 of the 36 renamed jobs, incl. pr-shepherd and world-watch, whose brain
   replacements need item 2 first). Run it after items 1-5, not before.
8. Outside this org (your call): set `USE_SELF_HOSTED=false` on the predecessor CRM repo; that ends the ci-runner-guard
   exit 1 while the Umbra fleet is parked.
