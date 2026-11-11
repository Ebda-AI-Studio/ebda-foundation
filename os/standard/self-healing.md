# self-healing — the OS medic (auto-remediation, not just alerting)

The observability fleet (`services-watch`, `msg-monitor`, `checkout-monitor`, `cf-workers-watch`, `anomaly-watch`) **detects + alerts** — it never mutates. This layer **acts**: when a hosted service is confirmed down, it runs a bounded, compute-only recovery and reports the outcome. So a service that falls at 3am is *fixed by 3:03am*, and Ahmad wakes to "🔧 I fixed it," not "🚨 it's broken."

**"Confirmed down" excludes "I could not reach it."** A probe that got no HTTP response (curl exit 5/6/7/28/35/56, or `000`) says nothing about the service — it may only mean the monitoring Mac lost DNS. Because the recovery here is `railway-redeploy`, believing such a probe would **redeploy production services that were never down**. Two independent guards enforce this, deliberately kept separate:

- **`heal-watch`** consults the shared host pre-flight (`host_online`, `ops/lib/net-probe.sh`) before forming any DOWN verdict, and while this Mac is offline it records nothing and hands off nothing — see `standard/observability.md` § "Unreachable is not broken".
- **`self-heal.sh` §1.5** keeps its own, *stricter* baseline check: a baseline host must answer in under 2.5s, so a network that is degraded-but-technically-up is also caught. It is not refactored onto the shared helper precisely because it is stronger, and this is the one script that mutates production (2026-07-06: a Mac network blip faked an a previous storefront product API outage and would have redeployed prod).

**Strategy (Ahmad, 2026-07-05): heal-immediately-then-notify.** On confirmed-down, recover right away, then Telegram the result. Escalate only if healing fails.

## Components (`ops/`)
- **`heal-watch.sh`** — launchd heartbeat (`com.ebda.os.heal-watch`, every 180s). Probes each registered service's health; on DOWN, hands off to `self-heal.sh`.
- **`self-heal.sh <id> [reason]`** — the medic. Confirm-still-down (anti-flap) → cooldown/attempt check → platform recovery → re-verify → `🔧 self-healed` / `🚨 auto-heal failed` via `notify.sh`. `DRY_RUN=1` simulates with no mutation; `HEAL_REG=<path>` overrides the registry for tests.
- **`lib/heal-registry.json`** — the service registry. Add a service = add an entry.
- **`heal-review.sh [status|log|test|registry]`** — inspect: live probe, audit log, dry-run all, dump registry.

## Recovery playbooks (compute only — NEVER data)
| platform | recovery | action |
|---|---|---|
| railway | `railway-redeploy` | `railway redeploy --from-source` (proven; also the fix for a crash-loop or the managed Postgres-creds-drift outage) |
| vercel  | `vercel-rollback`  | `vercel rollback` to the last-good production deploy |
| cloudflare | `wrangler-rollback` | `wrangler rollback` |
| any | `escalate-only` | no auto-action — alert only (safe default for unmapped/ambiguous services) |

## Guardrails (why it can't make things worse)
- **Anti-flap**: re-probes N times before acting — a transient blip is ignored.
- **Cooldown** (600s) + **max attempts** (3): no redeploy loops; exhaustion → escalate to a human.
- **Compute-only**: redeploy/rollback/restart. Never touches data, migrations, or ambiguous states.
- **Full audit log** (`~/.whisky-os-state/heal.log`) + Telegram on every heal/escalation.
- Complements (does not replace) the detect+alert monitors — they stay as an independent signal.

## Registered services (2026-07-05)
`msg-api` (Railway, redeploy) · `msg-web` (Cloudflare Worker, wrangler rollback) · `store-web` (Cloudflare Worker, wrangler rollback) · `store-api` (Railway, redeploy). To add: append to `heal-registry.json` with `health`, `expect`, `recovery`, and the platform's service identifiers.
