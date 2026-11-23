# ci-alert - CI failures reach Ahmad from outside the fleet

tags: [BOTH]
scope: every repo whose CI runs on the self-hosted native Mac runner fleet
sources: incident I15 (2026-10-26)

**Why a Mac-side poller.** A `notify-failure` job runs on the fleet it reports on. A dead fleet leaves required checks QUEUED forever; a
queued run never turns red, so nothing fires. Hosted runners are billing-rejected on both orgs, so `ops/ci-alert.sh` (launchd, every 5 min,
GitHub API only) is the primary path.

**Pages** (via `notify.sh`, deduplicated per run in `~/.whisky-os-state/ci-alert/seen.json`):
- `failed-main`: default-branch / schedule / dispatch run concluded failure or timed_out (deploy workflows included), created < 24 h ago.
- `failed-pr`: a pull_request run red on attempt >= 2.
- `queued`: any run queued/waiting > 20 min (no age cap).
- `unknown`: a repo's runs could not be read (gh failure, invalid JSON, an API error object); repeats at most every 6 h. Never "no alerts".
Never pages: cancelled (the merge train cancels on purpose), skipped, neutral, success, in_progress.
At most 5 pages per tick, then one summary; a failed delivery is retried next tick.

Repos: `CI_ALERT_REPOS` (default ebda-store, ebda-foundation).
**Enforcement.** `ops/tests/ci-alert.test.sh` (27 cases, 3 mutation controls: cancelled-as-red, no dedup, no queued rule).
