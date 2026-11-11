# 2026-11-10 Observability: read production, alert from outside Cloudflare

## Finish line

- **Must work:** anyone (and the OS) can read what every Ebda Worker did in any window from this Mac; an alert reaches Ahmad's Telegram
  within ~20 min of a storefront 5xx burst, API 429s, an exception spike, a dead log pipeline or a public host going down, even when all of
  Cloudflare is down; an alert drill proves the path end to end.
- **Exercised:** `os/ops/ebda-logs.mjs` against the live `ebda-logs` bucket; `os/ops/ebda-prod-watch.mjs --dry-run` against the live hosts
  and bucket; `os/ops/tests/ebda-logs.test.mjs` fixtures (each rule: must fire / must not fire); `workflow-lint` on the new workflow.
- **Must NOT change:** any deployed Worker, the brain's Telegram policy, the CI lanes, the merge gate.
- **Done:** PR green; the secrets list is in the approvals queue; the first scheduled run after the secrets land is red-or-green for a real
  reason (missing secret = red, by design).

## Why the readings were missing (measured)

1. `wrangler tail` opens a WebSocket to `tail.developers.workers.dev`, which resolves to 188.114.96.6 / .97.6: the Cloudflare range the
   Egyptian ISP blocks (launch map row ISP-188). Ebda's own hosts resolve to 172.67.x / 104.21.x and work. Not an auth problem.
2. The wrangler OAuth token has no Logs/Observability scope, but it CAN list and read R2 objects, and Logpush job `ebda-workers-trace`
   already writes every trace event of nine Workers to `ebda-logs` (30-day lifecycle). Nothing read it.
3. The Cloudflare API allows 1200 requests / 5 min per user. A naive parallel reader trips error 971 within a minute (measured), so the reader
   paces itself at 3 req/s (a full day, ~1,600 objects, is ~9 min).
4. The job's filter omits `ebda-wa` and `ebda-os-brain`, and its fields omit `CPUTimeMs` / `WallTimeMs` (ebda-store PR fixes the job script,
   ebda-whatsapp PR turns `logpush` on, this PR turns it on for the brain). `ebda-marketing` / `-help` / `-docs` are asset-only: no records
   while assets answer, by design.

## What ships here

| File | Role |
|---|---|
| `os/ops/ebda-logs.mjs` | Reader CLI: window + `--script/--status/--path` filters; aggregates by script x kind, outcome, script x status, top 5xx/429 paths, exceptions, error/warn lines, RPC methods, CPU/wall p50/p95 when present; `--callers <script>:<status>` (shared RayID), `--minutes <script>`; `--json`. |
| `os/ops/lib/ebda-logs-core.mjs` | Pure aggregation + alert rules + dedupe (`decide`) + digest. No I/O. |
| `os/ops/lib/ebda-logs-r2.mjs` | R2 list/get through api.cloudflare.com, paced, gunzip-tolerant; credentials from env or the wrangler login, never printed. |
| `os/ops/ebda-prod-watch.mjs` + `os/config/prod-watch.json` | The watch: probes, last Logpush window, rules, Telegram, digest, drill; optional brain `/findings` copy. |
| `.github/workflows/prod-watch.yml` | Every 10 min on GitHub-hosted runners; `workflow_dispatch` modes `watch`, `digest`, `drill`. Dedupe state in the Actions cache. |
| `ops/workflow-lint.mjs` | Allows `runs-on: ubuntu-latest` only under `# hosted-only: <reason>` and never on `pull_request`. |
| `os/cloud/brain/wrangler.jsonc` | `logpush: true` (takes effect when the job filter lists `ebda-os-brain`). |

Usage: `node os/ops/ebda-logs.mjs --since 2h --script ebda-web --status 5xx`; `--since 2026-11-10T00:00:00Z --callers ebda-api:429`;
`--minutes ebda-web`. Installed to `~/.claude/scripts/` by `os/install.sh` (it copies `os/ops/**`). Run `npx wrangler whoami` first so the
OAuth token is fresh, or set `EBDA_LOGS_CF_TOKEN` + `CLOUDFLARE_ACCOUNT_ID`.

## Alert rules (thresholds in `DEFAULT_RULES`)

| Key | Severity | Fires when (15-min window, ending 5 min ago for Logpush lag) |
|---|---|---|
| `storefront-5xx` | P1 | `ebda-web` 5xx >= 5 and >= 2% of its fetches |
| `api-429` | P2 (P1 at >= 20) | `ebda-api` answered 429 >= 3 times |
| `exceptions:<script>` | P1 | >= 10 non-ok outcomes (not `canceled`) for one Worker |
| `logs-silent:all` / `logs-silent:<script>` | P1 | zero records in 30 min, or `ebda-api` / `ebda-status` (cron Workers) silent |
| `probe:<name>` / `probe:all` | P1 | 2 consecutive failed probes; every host failing = ONE `probe:all` |

Delivery: P1 once on open, again after 6 h if still firing, one "resolved"; P2 only in the daily digest (first run after 05:00 UTC); at most
6 messages a day, past that alerts fold into the digest, except `probe:all`. An unreadable log source never resolves a log alert.

## Rulings

Ruling OBS-1 - The alert job runs on GitHub-hosted runners, not in the brain Worker and not on Umbra. Evidence: the brain, status.ebda.app and
every Ebda host share one Cloudflare account, so a Cloudflare-wide outage silences all of them (iceberg terms 23-26); Umbra runs on the Mac
behind the ISP block and sleeps with it; Telegram and GitHub are off Cloudflare. Cost if wrong: ~4,300 of the org's 50,000 Actions minutes
a month, and GitHub cron can drift a few minutes late.

Ruling OBS-2 - Telegram receives only P1s and one daily digest (6/day cap, outage exempt), in line with Ahmad's 2026-11-05 rule. Evidence:
status.ebda.app already messages every incident open AND resolve (50 incidents in 14 days, up to ~100 messages), which is the noise this
avoids. Cost if wrong: a P2 (a handful of 429s) waits up to a day to be seen.

Ruling OBS-3 - A missing required secret makes the run red, never green, while probes still run. Evidence: "a declared-but-unwired gate fails
open" (standing rule); GitHub mails the workflow owner on a failed scheduled run, a second channel when Telegram is the missing piece.
Cost if wrong: red runs every 10 min until the secrets land.

Ruling OBS-4 - The reader paces at 3 req/s instead of retrying on 429. Evidence: 16-way parallel reads hit API error 971 within a minute on
2026-11-10; the limit (1200 / 5 min / user) is shared with deploys. Cost if wrong: a full-day read takes ~9 min.

## Not done here (owned elsewhere)

Backups and runbooks (another agent). Deploying the brain config (SERVICE_TARGETS, PAGE_LOAD_TARGETS, GITHUB_TOKEN ...) and the GitHub org
webhook repoint are Ahmad's actions, listed in the approvals queue.
