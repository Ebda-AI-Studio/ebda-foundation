# page-load-monitor — runbook

Fleet page-load health monitor. Catches the *200-but-broken* class — pages that
return HTTP 200 but are actually broken for shoppers (blocked client-side API
calls, error toasts, failed sections) — plus insecure (non-HTTPS-redirecting)
origins, across every FWB store. Motivated by the pecannbee.com.kw incident where
an HTTP (insecure) origin blocked the store's own API/websocket calls while every
page still returned 200.

## What it checks

Per store, two layers:

- **Layer 1 — liveness** (`ops/journeys/page-load/fleet-liveness.mjs`, dep-free
  `fetch`, whole fleet every tick):
  - `http://<domain>/` **must 301/308 → https** (the insecure-origin guard). A
    plain 200 on port 80 fails with `insecure-origin` — fix by enabling Cloudflare
    **"Always Use HTTPS"** on that zone.
  - each of home / PLP / PDP / cart / checkout → 200, not an error page, and (for
    home/PLP/PDP) contains a storefront SSR marker. Markers are the platform's
    schema.org JSON-LD + OpenGraph tags (`application/ld+json`, `og:site_name`,
    `"@type":"Store"/"Product"/"ItemList"`), which are server-rendered and stable
    across themes — not theme class names.
- **Layer 2 — deep journey** (`ops/journeys/page-load/fleet-deep.mjs`, Playwright,
  rotating shard + any Layer-1-flagged store): drives home→PLP→PDP→add-to-cart→
  cart→checkout in headless chromium and fails on a blocked/4xx/5xx call to the
  store's own API hosts, a console error, an incident error-toast, or a missing
  section (reviews/related/add-to-cart/checkout total). Fail-open: if Playwright
  isn't installed it skips (Layer 1 still runs).

## Runner & schedule

- Runner: `ops/page-load-monitor.sh` (installed to `~/.claude/scripts/`). Fail-open
  — always exits 0. `--notify` sends Telegram via `notify.sh`; `DRY_RUN=1` skips
  state writes; `--dry-notify` prints instead of sending.
- Schedule: launchd `com.ebda.os.page-load-monitor`, every 1800s. Installed +
  scheduled by `ops/install.sh` (which substitutes HOME/PATH — PATH includes nvm
  node 24 per the headless-node convention).
- **Flap control:** a store must fail **2 consecutive ticks** before it alerts
  (first-tick failures are logged as `warn`, suppressed). No single-blip spam.
- Status surfaces in the command center as **Page-load monitor**
  (`~/.whisky-os-state/page-load-monitor-status.json`).

## Fleet list

`ops/lib/fleet-domains.sh` resolves the fleet: platform API
(`FLEET_STORES_API_URL` + `FLEET_STORES_API_TOKEN` in `~/.whisky-services.env`) →
30-min cache → committed `ops/fleet-stores.json` fallback. Add stores to the
fallback JSON, or wire the API token so new stores are auto-covered. Representative
PLP/PDP URLs per store are resolved from `/sitemap.xml`.

## Env keys

| Key | Purpose |
|---|---|
| `FLEET_STORES_API_URL` / `FLEET_STORES_API_TOKEN` | platform store-list API (optional; falls back to `fleet-stores.json`) |
| `DEEP_SHARD_SIZE` | Layer-2 stores per tick (default 8) |
| `WHISKY_OS_STATE_DIR` | state dir override (default `~/.whisky-os-state`) |

## Run manually

```bash
# Layer-1 smoke for one store (read-only; no browser)
FLEET_LIVENESS_DOMAINS="$(printf 'pecannbee.com.kw\tcustom')" \
  node ~/.claude/scripts/journeys/page-load/fleet-liveness.mjs

# full runner, no writes / no send
DRY_RUN=1 ~/.claude/scripts/page-load-monitor.sh --dry-notify
```

## Enable Layer 2 (Playwright)

`fleet-deep.mjs` does `import("playwright")`, so the **package** must be resolvable
by node (not just the browser binary). Install it in the runtime dir so the
journey resolves it by walking up parent dirs; then download chromium:

```bash
cd ~/.claude/scripts
npm init -y -q            # once, if no package.json yet
npm i playwright@latest   # the importable package (node_modules here resolves for journeys/page-load/*)
npx playwright install chromium   # the browser binary (~150MB)

# smoke one store
FLEET_DEEP_DOMAINS="$(printf 'pecannbee.com.kw\tcustom')" DEEP_SHARD_SIZE=1 \
  node ~/.claude/scripts/journeys/page-load/fleet-deep.mjs
```
Until this is done the deep journey fails-open (`skipped: no-playwright`) and only
Layer 1 runs. NOTE: `ops/install.sh` does not yet perform this Playwright install —
it is a manual per-runner step (follow-up: wire an opt-in into install.sh).
Per-theme add-to-cart / cart / checkout selectors in `driveStore()` are tuned
during this live smoke; capture the working selectors here as they're confirmed.

## Triage

- `insecure-origin` → enable Cloudflare "Always Use HTTPS" for that store's zone;
  confirm with `curl -I http://<domain>` returning `301 → https`.
- `<page>: 200 but no storefront marker` → the store rendered but lacks the SSR
  JSON-LD/OG markers; check whether the theme regressed structured-data output
  before assuming a real outage (this is the most likely false-positive source —
  re-verify markers against a known-good store).
- Layer-2 `request failed` / `error toast` → open the store, reproduce the flow;
  the detail names the failing request/toast.
