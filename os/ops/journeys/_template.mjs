#!/usr/bin/env node
/**
 * _template.mjs — Journey script template for ops/journey-monitor.sh
 *
 * CONTRACT (read this before writing a new journey):
 *
 *   1. READ ENV — target URL and any credentials come from env vars.
 *      Required env vars must be documented in ops/journeys/README.md.
 *
 *   2. IF ENV UNSET — skip cleanly: print {ok:true, skipped:true, detail:"..."}
 *      and exit 0. Never fail because creds aren't wired yet.
 *
 *   3. PERFORM STEPS — use the global `fetch` (Node 18+ built-in). No deps.
 *      If you need Playwright, guard with: try { require('playwright') } catch { skip }.
 *
 *   4. ASSERT OUTCOME — e.g. HTTP 200 AND body contains a known marker.
 *      A 200 with an error page still fails. That's the whole point.
 *
 *   5. PRINT ONE JSON RESULT LINE to stdout:
 *        {"journey":"<name>","ok":<bool>,"detail":"<one-line human summary>"}
 *      The runner reads ONLY this line. Other stdout/stderr is ignored.
 *
 *   6. EXIT — exit 0 on success or skip, non-zero on assertion failure or
 *      uncaught error. The runner treats non-zero as a failed journey.
 *
 * Example result lines:
 *   {"journey":"my-journey","ok":true,"detail":"product grid found (42 items)"}
 *   {"journey":"my-journey","ok":false,"detail":"HTTP 200 but no cart element in body"}
 *   {"journey":"my-journey","ok":true,"skipped":true,"detail":"JOURNEY_MY_URL not set — skipping"}
 *
 * Keep journeys focused: one user goal per file. A journey should take < 10s.
 * Name the file after the journey: ops/journeys/store-add-to-cart.mjs
 */

// ---- 1. Read env ----
const TARGET_URL = process.env.JOURNEY_TEMPLATE_URL;
const JOURNEY_NAME = "template";

// ---- 2. Skip if env unset ----
if (!TARGET_URL) {
  console.log(JSON.stringify({
    journey: JOURNEY_NAME,
    ok: true,
    skipped: true,
    detail: "JOURNEY_TEMPLATE_URL not set — skipping (set it in ~/.whisky-services.env)",
  }));
  process.exit(0);
}

// ---- 3. Perform steps ----
async function run() {
  let res;
  try {
    res = await fetch(TARGET_URL, { signal: AbortSignal.timeout(15000) });
  } catch (err) {
    console.log(JSON.stringify({
      journey: JOURNEY_NAME,
      ok: false,
      detail: `fetch failed: ${err.message}`,
    }));
    process.exit(1);
  }

  const body = await res.text();

  // ---- 4. Assert OUTCOMES ----
  // Example: assert HTTP 200
  if (res.status !== 200) {
    console.log(JSON.stringify({
      journey: JOURNEY_NAME,
      ok: false,
      detail: `expected HTTP 200, got ${res.status}`,
    }));
    process.exit(1);
  }

  // Example: assert body contains a known marker (edit this to match YOUR page)
  const EXPECTED_MARKER = process.env.JOURNEY_TEMPLATE_MARKER || "<!DOCTYPE html>";
  if (!body.includes(EXPECTED_MARKER)) {
    console.log(JSON.stringify({
      journey: JOURNEY_NAME,
      ok: false,
      detail: `HTTP ${res.status} but expected marker "${EXPECTED_MARKER}" not found in body (${body.length} bytes)`,
    }));
    process.exit(1);
  }

  // ---- 5. All assertions passed ----
  console.log(JSON.stringify({
    journey: JOURNEY_NAME,
    ok: true,
    detail: `HTTP ${res.status}, marker found (${body.length} bytes)`,
  }));
  process.exit(0);
}

run().catch((err) => {
  // Uncaught error — report as failure, exit non-zero
  console.log(JSON.stringify({
    journey: JOURNEY_NAME,
    ok: false,
    detail: `uncaught error: ${err.message}`,
  }));
  process.exit(1);
});
