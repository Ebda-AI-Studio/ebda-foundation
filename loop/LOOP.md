# The loop

foundation -> build -> QA -> finding -> foundation. ebda-foundation is the source of truth and the home of this loop.

1. **QA** on the QA store (Amelia Aurum, `1bb14d0e-0cb8-4cb4-b939-e889c4bc2ebc`, ameliaaurum.com + store.ebda.app admin) finds an issue.
   Every pass covers every button, API path, branch and page, at 390/820/1280/1440, admin <-> storefront <-> marketing.
2. **Classify**: UX / money / auth / data / ops / feature. Build priority: money > auth > data > ops > UX.
3. **Check the foundation first**: `design/` (tokens, component rules; present once #20 merges), `design/references/`
   (six DESIGN.md, reference only), `os/standard/`, `docs/RULINGS.md`, the guards.
4. **If the answer is missing, add it to the foundation first**: a token, component rule, backend standard, ruling or guard.
   The finding is not fixed until the rule that would have prevented it exists.
5. **The product consumes it**: themed PR into main (never stacked) with a test that fails on the old code; the drain loop
   merges green PRs; deploy is automatic; confirm the live commit (`/health`) equals the main tip.
6. **Re-verify live** on Amelia (or the live site) before the item moves to CLOSED. A merge is not a deploy, a deploy is not a fix.
7. **Never idle while STILL-OPEN or FOUND is non-empty.** New QA findings go to FOUND in `loop/REGISTER.md`, then step 2.

## How to run: say "loop"

Say **loop** (or "run the loop" / "start the loop") and the controller follows the `ebda-loop` skill (`os/skills/ebda-loop/SKILL.md`, installed to `~/.claude/skills/ebda-loop` by `os/install.sh`). It is NOT the built-in `/loop <interval>` timer skill. One cycle: re-triage STILL-OPEN + FOUND -> dispatch Sonnet builders (money > auth > data > ops > UX) -> merge through the drains + review gate -> deploy verify -> QA on Amelia -> audits on cadence -> alerts -> exit check. It stops only when `loop/exit-check.sh` passes all 6 criteria. Status at any time: `bash os/ops/loop-status.sh` (also on the brain status page when present).

## Review gate (CI, not the controller's laptop)
Every PR except an all-safe one (markdown, docs/, tests) gets the label `risky-path` and is reviewed by `.github/workflows/ai-review.yml` (`ci/ai-review/README.md`). Pass = label `ai-review-passed` (stripped on every new push). No secret or any infra error = the check fails (Ruling AIR-1). The drain holds a `risky-path` PR until it carries `ai-review-passed`.

## Exit criteria
The loop stops ONLY when ALL are true, each measured, not claimed (Ahmad 2026-11-11):
1. STILL-OPEN is empty (audits/still-open re-triaged against main the same day), except items BLOCKED-ON-PAPERS or explicit product decisions Ahmad made.
2. FOUND is empty and every RE-VERIFY item is CLOSED with live evidence on the QA store.
3. Zero open GitHub issues labelled review-finding (backfill audits + PR reviews) and every risky PR merged with ai-review-passed.
4. main CI green on the latest commit; every deploy pipeline's live /health commit = main tip; prod-smoke-journey green 3 runs in a row.
5. One full QA pass on the QA store touches every admin page, every button, every storefront page, checkout (COD + delivery), orders lifecycle, editor, billing/upgrade, search, emails, Arabic + English, at 390/820/1280/1440, and finds nothing new.
6. The AI OS brain shows no open P0/P1 findings and no platform alert for 72 h.
Then: Ahmad's two items (launch assets, 10-minute merchant test) -> launch.

`loop/exit-check.sh` measures 3a, 4 and 6 (PASS/FAIL each; `/api/state` has no severity, so any open brain finding fails 6) and prints 1, 2, 3b and 5 as `manual: needs controller evidence`. It exits non-zero unless every measured condition passes and `--manual-ok` asserts the controller holds that evidence.

## Drain loop (durable)
`os/ops/drain.sh` is the merge loop, one launchd job per repo (`com.ebda.os.drain-ebda-store`, `com.ebda.os.drain-ebda-foundation`, installed by `os/install.sh`). It survives the session, takes a lock per repo and per PR, merges only through the merge gate, and holds `risky-path` PRs until `ai-review-passed`. It is OFF until `~/.whisky-os-state/drain/<name>.enabled` exists: switch over by stopping the controller's own loops first (`touch ~/.claude/handoff/drain.stop`, kill only the PIDs you started), then `touch` the marker; `rm` it or `touch <name>.stop` to halt. Heartbeat: `~/.whisky-os-state/drain/<name>.heartbeat` every cycle and a findings snapshot to the brain every 10 minutes. 60+ minutes with green PRs waiting and no merge opens ONE `drain-stall` finding (the brain alerts once and resolves it when the next snapshot omits it); a risky PR held 120+ minutes opens a `drain-held` digest finding.


## Watchers and wake-ups (Ruling LOOP-WATCH-1)
- **Hard rule:** any wake-on-exit watcher (`os/ops/alert-wait.sh`, `os/ops/loop-watchdog.sh`, gates) runs ONLY as a harness-tracked background task (`Bash run_in_background`), NEVER `nohup` / `&` / `disown`. A detached process's exit wakes nobody; on 2026-11-11 that hid 21 P1 alerts and stalled the loop 2 h (0 merges, ~20 approved PRs).
- **Session start:** `loop-status.sh`, then arm `alert-wait.sh` and `loop-watchdog.sh`, then confirm the drain jobs.
- **On every wake:** run `loop-status.sh`, check main CI and the last-merge time, act, re-arm both watchers (they exit once per event).
- `loop-watchdog.sh` exits (wakes the controller) when main CI is red, no `<OS_LAUNCHD_PREFIX>.drain-*` job or drain process is alive, `alert-wait.sh` is dead, or 40 min pass without a merge while `ai-review-passed` PRs wait. Ack file `$OS_STATE_DIR/loop-watchdog.ack` (reason kinds) keeps a known issue from re-waking; it clears when the loop is healthy.
- **Brain backstop (no session needed):** the `loop-stall` watcher (every 15 min) raises `loop-main-red` (main CI red 30+ min) and `loop-merge-stall` (no merge 60+ min with approved PRs): ONE deduped P1 to Ahmad per incident, also written to `/api/alerts` as `brain/<kind>` so `alert-wait.sh` wakes the controller (LOOP-WATCH-2), resolved when it clears. It complements the drain's own `drain-stall`.
- `loop-watchdog.sh` also wakes when a root checkout under the projects dir has `core.bare=true` (it silently breaks `merge-gate.sh`; Ruling LOOP-WATCH-3). Fix: `git -C <path> config core.bare false`.
