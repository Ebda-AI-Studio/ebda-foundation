# observability — Observability & Alerting Rubric

tags: [BOTH]
sources: PLAYBOOK §8, CLAUDE.md (Production Reality gates 6/7/11/12), reference-iceberg-audit.md (terms 23–26: Logging/Alerting/Incident response/Instrumentation), reference-force-ai-production-grade-standard.md (layer 7: observability)

## What "solid" looks like
Sentry wired day 1 on every job failure, webhook, and money mutation; an external uptime monitor with a P0 notification channel before any customer goes live; a log drain with verified ≥30-day retention documented in `docs/DEPLOYMENT.md`; the external-alert bridge token set in prod with a boot-time warning if missing; a defined SLO (p95 latency + error rate) with a queue-depth watch on async jobs; and every monitor distinguishing **"I could not reach it"** from **"it is broken"**.

## Unreachable is not broken (2026-09-16)

An alert is only worth the trust it keeps. On 2026-09-16 the monitoring Mac lost network access and seven scheduled monitors reported their targets as broken, each naming a different and contradictory cause — "auth is broken for all users", "check RAILWAY_API_TOKEN", "check POSTHOG_API_KEY", "0 succeeded, 5 failed". Every service was healthy. The tell was in the same logs: the Telegram sends carrying those alerts failed with `curl: (6) Could not resolve host: api.telegram.org`.

**The rule.** `curl` exit 5/6/7/28/35/56, or `%{http_code}` == `000`, means *this host could not connect*. It is not evidence that the service is down, and it is never evidence that a credential is wrong — a probe that got no HTTP response has not tested the credential at all.

Three classes, never two (`ops/lib/net-probe.sh`, `net_class_for`):

| class | meaning | alerting |
|---|---|---|
| `ok` | 2xx/3xx — answered as expected | silent |
| `http_error` | 4xx/5xx — **the service answered**. A 401 means auth really is broken; a 500 means it really is failing | fails and pages, exactly as before |
| `unreachable` | no HTTP status obtained | fails and pages **when the host is online**, worded as UNKNOWN; suppressed to one line when the host is offline |

**Host pre-flight.** Before believing a transport failure, a monitor asks whether *it* has DNS and egress (`host_online`). Two requirements, both learned the hard way: the pre-flight targets must be **hostnames**, or a DNS outage — the actual 2026-09-16 failure — sails straight past a gate that cannot fail; and it must be consulted **lazily**, only after a probe has actually come back unreachable, so a healthy run adds no network calls.

**A blind run does not page.** When the host is offline the notification channel is offline by the same cause, so the page is undeliverable by construction. The run prints one `host offline — … target state unknown` line and records `write_status <job> warn`; the dashboard and `heal-watch`'s staleness sweep read it, and the next healthy run reports the truth. Seven service-down pages for one local outage is the failure mode being prevented.

**Monitors that MUTATE need this most.** `heal-watch` hands off to `self-heal.sh`, whose recovery is `railway-redeploy` — an unguarded local outage would redeploy production services that were never down. Full rationale and rulings: `docs/plans/2026-09-16-monitors-unreachable-vs-broken.md`.

## Criteria
| # | Criterion | Solid (grade 2) | Gap detection | Severity |
|---|---|---|---|---|
| 1 | Error monitoring wired day 1 | Sentry initialized and capturing on every job failure, webhook, and money mutation | grep for `Sentry.init`/`@sentry/` import in app bootstrap; grep money/webhook/job handlers for a capture call (`captureException`/`Sentry.`) | Critical |
| 2 | Uptime monitor + P0 channel | External uptime monitor (UptimeRobot/BetterStack) + a P0 notification channel (Telegram/PagerDuty) live before any customer | check `docs/DEPLOYMENT.md` for a named uptime monitor; grep for the P0 channel config (`TELEGRAM_*`/PagerDuty webhook); confirm not in-code-only ping | High |
| 3 | Log drain with ≥30-day retention | Log drain (Axiom/equivalent) configured; retention window ≥30 days verified, not assumed | grep `docs/DEPLOYMENT.md` for a stated retention figure ≥30 days; confirm a drain config key (`AXIOM_*`/drain token) exists, not just console logging | High |
| 4 | Retention window documented | The ≥30-day retention is written down in `docs/DEPLOYMENT.md` (verified) | file-exists `docs/DEPLOYMENT.md` + grep it for an explicit retention statement (e.g. `retention`/`30-day`/`30 days`) | Medium |
| 5 | External-alert bridge token in prod | Alert bridge token set in production; boot-time warning logged if missing | grep boot/startup for an `ALERTS_WEBHOOK_TOKEN`/alert-bridge env check that warns when unset; confirm the var name exists in prod env list | High |
| 6 | SLO defined (p95 + error rate) | p95 latency target and error-rate target codified, not informal | grep `docs/`/`*.md` for a stated p95 latency + error-rate SLO; confirm a number, not prose intent | Medium |
| 7 | Queue-depth watch on async jobs | Async/queue jobs have a queue-depth watch that alerts on backlog | grep worker/queue code for a depth/backlog metric or alert (`queue.getJobCounts`/depth gauge); confirm an alert threshold exists | Medium |
| 8 | Correctness probe on the critical path | Every product has a synthetic probe of its critical path (auth login→/me, checkout, order-create) that FAILS on a wrong-but-200/401 — not just a `/health` ping — plus a deploy-drift check (running commit vs main HEAD) | grep monitor scripts for an authed/critical-path probe asserting 200 + expected role/body; flag health-only monitors | High |
| 9 | Transport failure ≠ service failure | Every monitor classifies a probe into `ok` / `http_error` / `unreachable` (`ops/lib/net-probe.sh`), reports an unreachable target's state as UNKNOWN rather than DOWN, never names a credential it did not test, and runs a hostname-based host-connectivity pre-flight that collapses a blind run to ONE non-paging line | grep monitor scripts for curl/`%{http_code}` failure branches that say "DOWN"/"FAILED"/"check &lt;TOKEN&gt;" without inspecting the curl exit code; flag any that treat `000` as a verdict about the service, and any pre-flight whose targets are IP literals | High |
| 10 | A mutating monitor is pre-flight gated | Any watcher whose failure path triggers a WRITE (redeploy, rollback, restart) confirms its own connectivity before acting, so a local network outage cannot mutate production | grep for watchers that invoke a recovery/redeploy script on a probe failure; confirm a connectivity or external-prober check gates the hand-off | Critical |

## Evidence (filled during audit, per repo)
- FWB: …
- WBS: …
