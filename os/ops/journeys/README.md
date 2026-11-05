# ops/journeys — Semantic Golden-Journey Monitor

Part of the **Whisky AI OS** observability stack. Journeys assert **OUTCOMES**, not HTTP status codes. A storefront that returns 200 with an error page still fails here.

## How it works

`ops/journey-monitor.sh` discovers all `*.mjs` files in this directory (excluding `_*.mjs` templates), runs each with `node`, and collects the JSON result line from stdout.

Each journey must print **exactly one JSON line** to stdout:

```json
{"journey":"<name>","ok":true|false,"detail":"one-line human summary"}
```

On `ok:false` the runner emits a **HIGH** finding (`class: "journey-fail"`) to `~/.whisky-os-state/journey-findings.json` and speaks it to Zero (revenue path broken = immediate alert). On `ok:true` it counts as passing. The runner always exits 0 — it is fail-open and never crashes the OS fleet.

## Writing a new journey

1. Copy `_template.mjs` to `<descriptive-name>.mjs` (e.g. `wbs-login.mjs`).
2. Name the `JOURNEY_NAME` constant to match the file basename.
3. Pick the required env var(s) — document them below and in `~/.whisky-services.env`.
4. If env is unset → print `{ok:true, skipped:true, detail:"..."}` and `process.exit(0)`. Never fail on missing creds.
5. Use global `fetch` (Node 18+ built-in). No `npm install` — journeys must be zero-dep.
6. Assert OUTCOMES not status codes: check body content, response shape, downstream effects.
7. Exit 0 on pass/skip, non-zero on assertion failure.

### Playwright journeys (future)

For flows that require a real browser (login with JS-heavy auth, checkout form submission), guard at the top:

```js
let chromium;
try { ({ chromium } = await import('playwright')); }
catch { /* skip — Playwright not installed */ }
if (!chromium) {
  console.log(JSON.stringify({journey: NAME, ok:true, skipped:true, detail:"playwright not installed"}));
  process.exit(0);
}
```

The framework is ready; Playwright journeys are the next evolution.

## Environment variables — plug into `~/.whisky-services.env`

Set these in `~/.whisky-services.env` on the monitoring Mac to enable real prod journeys. The runner sources this file automatically (with `set -a`, so plain `KEY=value` lines reach the journeys; `export` is not needed). A run in which every journey skipped is reported as **WARN (blind)**, not as healthy.

### FWB (Force Store) journeys

```bash
# fwb-storefront-smoke.mjs  -- REQUIRED: with this unset every journey SKIPS and
# journey-monitor reports WARN "BLIND: all journeys skipped" (nothing was checked).
JOURNEY_FWB_STORE_URL="https://wadyaljuz.com"

# Future: add-to-cart outcome journey (needs API base + a product ID)
JOURNEY_FWB_API_BASE="https://api.force-ai.co/api/v1"
JOURNEY_FWB_PRODUCT_ID=""          # a real product ID in the prod store
JOURNEY_FWB_STORE_DOMAIN="wadyaljuz.com"

# Future: authenticated admin journey (checks merchant dashboard renders)
JOURNEY_FWB_ADMIN_URL="https://admin.forcemediakw.com"
JOURNEY_FWB_ADMIN_EMAIL=""         # test merchant account
JOURNEY_FWB_ADMIN_PASSWORD=""      # test merchant password
```

### WBS (WhatsApp Bulk Sender) journeys

```bash
# Future: WBS login outcome journey
JOURNEY_WBS_URL="https://wbs.forcemediakw.com"
JOURNEY_WBS_EMAIL=""               # test user email
JOURNEY_WBS_PASSWORD=""            # test user password
```

### General

```bash
# _template.mjs example vars (only needed if you test the template directly)
JOURNEY_TEMPLATE_URL=""
JOURNEY_TEMPLATE_MARKER=""
```

> NOTE: These are **prod creds for a dedicated test account** — never use a real merchant's account. Create a `force-os-monitor@forcemediakw.com` test account on each system and revoke it if compromised.

## Registered journeys

| File | Env required | What it asserts |
|---|---|---|
| `fwb-storefront-smoke.mjs` | `JOURNEY_FWB_STORE_URL` | GET store URL → HTTP 200 AND structural storefront markers in HTML (product grid / cart / nav) — not just 200 |

## Scheduling

Scheduled every 30 minutes via `ops/launchd/com.ebda.os.journey-monitor.plist`. Install:

```bash
cp ops/launchd/com.ebda.os.journey-monitor.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.ebda.os.journey-monitor.plist
```

Or use `ops/install.sh` (registers `journey-monitor` in RUNTIME_SCRIPTS).

## Output

- `~/.whisky-os-state/journey-monitor-status.json` — current health
- `~/.whisky-os-state/journey-findings.json` — findings (HIGH on fail)
- `~/.whisky-os-state/events.ndjson` — bus event on every run
- `~/.whisky-os-state/zero-inbox.ndjson` — spoken alert on failure
