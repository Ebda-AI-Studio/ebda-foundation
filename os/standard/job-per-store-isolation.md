# job-per-store-isolation - a sweep over stores isolates each store, rotates the start, alerts once

Pack: reliability | Probe type: S | Source: Ebda AI Studio issue #619 + P1s 2026-11-11 (billing-renewal-daily, search-log-purge-daily)

## Claim
A job that visits "every store" must never let one store's error stop the stores after it, and must never visit them in a fixed order.

## Scenario
`acrossStores` rejected the whole sweep on the first store error and always walked the directory in the same order, so every store behind a bad one was starved on every tick (abandoned-cart and payments-reconcile every 15 min, PII retention daily). A closed store (`STORE_STORAGE_REMOVED` 410) failed `billing-renewal-daily` and `search-log-purge-daily` whole.

## Rules
1. The shared cross-store runner isolates per store BY DEFAULT: catch, record in `result.failures`, continue.
2. The start offset rotates each tick (time-based, stateless Workers), so no store is always last. Results stay in directory order.
3. One summary log line per sweep with counts (failed of total + a short sample), never one alert per store. A cron wrapper that must fail loudly throws once AFTER the sweep.
4. All-or-nothing is an EXPLICIT per-call flag (`abortOnError: true`), allowed only where a partial result is a wrong answer (admin totals, reference sets an orphan sweep deletes against). A test lists the allowed callers; a cron may not set it.
5. A store that is gone (410/404) or has no data on this runtime is SKIPPED with a log, not failed (shared `isStoreGoneError`).

## Source candidate
- (high) A loop over stores with `try` outside the loop, or a store runner that rejects on the first error.
- (high) A cron passing the abort-all flag.

## Enforcement
Ebda Store `tests/unit/across-stores-isolation.test.ts` (isolation, rotation, one summary line, abort opt-in, caller allow-list) and `tests/unit/store-looping-jobs-gone-store-guard.test.ts`.
