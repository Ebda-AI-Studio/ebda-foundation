# Launch checklist (every product in the suite)

A gate ends "done (evidence)" or "skip: reason". Flags stay off until the gate is proven.

1. Legal: terms, privacy and refund pages live as real URLs; shared clauses present (VAT-0, InstaPay, controller identity, no backdating, governing law); every provisional clause is marked and signed off.
2. Brand: no bare master name in any user-facing string (the foundation guard regexes pass), no orange, Arabic is the default locale where the product serves Egypt.
3. Identity: the client is registered with accounts.ebda.app (audience, scopes); one real sign-in tested on production.
4. Alerts: a deliberate error reaches Telegram and Sentry, phones and emails masked.
5. Logpush: enabled, retention at least 30 days.
6. Backup drill: restore into a scratch database from the latest backup, row counts match.
7. Erasure drill: export and erase one test subject; the completeness test lists every table or column holding a phone or buyer key.
8. Guards: rate limits fail closed on money routes; oversize body gives 413, wrong content type gives 415; Zod at every edge.
9. CI: runs on the shared runner via `EBDA_RUNS_ON`; `workflow-lint` clean; merge only through `scripts/foundation/merge-gate.sh`; `npm audit` at 0.
10. Deploy and verify: `/health` commit equals the tip of main, live cron schedules equal wrangler (no weekday names), one scheduled tick seen.
11. Status page probe added; SUITE-PARITY row added; the product is in the bump bot's consumer list.
12. Feature flags: all off by default, each turned on only after its own proof.
