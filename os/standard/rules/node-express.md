# node-express — Language/Framework Rule Pack

tags: [BOTH]
scope: Express (or any Node HTTP framework) API services — route handlers, middleware, webhooks, background workers
sources: `security.md` (criteria 4, 10), `scaling.md` (criteria 2–6, 10), CLAUDE.md (rules 2, 5–13), MEMORY.md feedback-db-pool-starvation-webhook-storm-starves-auth, feedback-redis-io-inside-rls-transaction-timeout, feedback-csrf-guard-method-aware, feedback-csrf-merchant-domain, feedback-jest-ci-hang-debugging-and-root-causes

## Must Always
- Keep webhook/inbound routes THIN: verify signature → persist to an inbox row (idempotency key) or enqueue → return 200 fast. Do the heavy DB/3rd-party work in a worker on its OWN Prisma pool. A webhook route that does interactive-transaction work inline shares its pool with auth — a provider storm holds every connection and login starts timing out with P2024, which reads externally as "auth is broken for everyone."
- Give auth its own dedicated (or generously-sized) connection pool, separate from any high-volume webhook/background path, as defense-in-depth even after the thin-webhook fix ships.
- Treat a CSRF guard's `Origin` check as method-aware: Origin present + allowlisted → OK; Origin present + not allowlisted → 403; Origin missing + mutating method (POST/PUT/PATCH/DELETE) → 403; Origin missing + safe method (GET/HEAD/OPTIONS) → OK. Browsers don't reliably send `Origin` on same-origin GET — a uniform "no Origin = 403" self-inflicts 403s on your own admin panel's read calls.
- In a multi-tenant platform, extend the CSRF trusted-origin predicate to also consult the CORS-allowlisted merchant custom-domain cache (not just hardcoded platform origins) for guest/bearer-token/public routes — otherwise a merchant's custom-domain checkout silently 403s on every request from day one.
- Return generic error messages to clients; log the real DB/stack error server-side only. Never let an Express error-handling middleware forward a raw Prisma/Postgres error string to the response body — it leaks schema/constraint names and can mask a real bug (e.g. an RLS 42501/FK violation) as a generic 500 the caller can't diagnose.
- Set `helmet()` (or equivalent) in prod with CSP, HSTS, and `X-Content-Type-Options: nosniff`.
- Export every module-level `setInterval`/`setTimeout` handle and clear it in a shutdown hook — both for graceful process shutdown AND so `jest.setup.ts`'s `afterAll` can clear it (see `bash-ops.md` / testing rubric for the Jest side).

## Must Never
- Never wrap Redis calls, per-row `$queryRaw` loops, or any network I/O inside an interactive DB transaction (`withRlsBypass`/`$transaction` callback) — an interactive tx is a time budget (commonly 30s). N sequential Redis round-trips or per-row queries inside it will eventually exceed the ceiling under a large dataset, throwing "Transaction already closed: expired" in production long after it worked fine in dev on a small table. Read rows → close the tx → batch/pipeline the I/O outside it.
- Never fall back from `Origin` to `Referer` in a CSRF guard — `Referer` is trivially spoofable by any non-browser caller (curl/scripts), defeating the entire point of using `Origin`.
- Never let a route handler's `catch` block call an error-response helper with the wrong argument order/signature (e.g. `errorResponse(res, err)` when the signature is `errorResponse(res, statusCode, err)`) — the mismatched call can itself throw INSIDE the catch, which is now uncaught, so the handler never sends a response at all. The request just hangs forever (visible in tests as an indefinite `supertest` await, in CI as a job that never completes and times out with zero useful output).
- Never assume a constructor-injected dependency (`this.prisma`) was actually assigned — a `this.x` read with no constructor assignment plus an outer `catch (error) { logger.error(...) }` silently swallows the `undefined` deref, and the feature is broken in prod while `/health` stays green and unit tests (which inject a fake directly) never catch it.

## Patterns
- **Diagnose pool starvation vs load**: `/health` fast+200 but login slow-then-500 = pool starvation, not a dead DB. Test login WITH a proper `Origin` header (without it you get a fast 403 from the CSRF gate, which looks "healthy" and hides the real hang). Check `pg_stat_activity` `idle in transaction` row AGE — young rows (~0.2s) = genuine load (add pool capacity); old/growing rows = a transaction LEAK (find the uncommitted tx).
  ```bash
  curl -m15 -w "%{http_code} %{time_total}\n" -X POST .../api/auth/login \
    -H 'Content-Type: application/json' -H 'X-Requested-With: XMLHttpRequest' \
    -H 'Origin: https://<frontend-host>' -d '{"email":"x@y.com","password":"x"}'
  ```
- **Jest hang bisection** (a suite with zero output that never completes): reproduce with each test file run standalone + a watchdog kill (`npx jest <file> & ` + poll `kill -0` up to ~35s); `--runInBand` stalling at byte 0 = hang at module-load or the first suite's setup; a per-test ENTER/EXIT trace (`beforeEach`/`afterEach` writing to `process.stderr`) pins the exact hanging test; a CPU sample (`sample <pid> 2` on macOS) parked at 0% in `kevent`/`uv__io_poll` = waiting on a handle/never-resolving promise, not a sync infinite loop.
- **Thin webhook shape**: `verify signature → persist inbox row (unique key) → enqueue → 200`. Catch the inbox's own P2002 (race on concurrent same-key delivery) OUTSIDE any transaction and re-read the winner's row — still ACK 200, don't 500 into a provider retry storm.

## Traps
- `--forceExit` on a Jest hang only fires AFTER the run completes — it does nothing for a test that hangs mid-run. Don't mistake "added forceExit" for "fixed the hang"; it's a symptom mask, not a fix.
- Moving webhook processing from inline to async widens duplicate-notification races — anything that relied on the inline handler completing before a sibling path ran now has a real multi-second window. A per-key concurrency limiter is NOT the same as idempotency; use an atomic claim (`UPDATE ... SET notified_at=now() WHERE notified_at IS NULL`) per entity.
- A webhook that returns 5xx gets RETRIED by the provider — a transient outage amplifies itself into a storm. ACK 200 fast even on internal processing failure (log + dead-letter instead).

Cross-links: `../rls.md` (bypass helper timeout budget), `../cicd.md` (Jest teardown discipline in CI), `../security.md` (CSRF, secrets, headers), `prisma-postgres.md` (the transaction-timeout mechanics), `bash-ops.md` (Jest CI hang bash-level debugging).
