# How to build a new product in the suite

1. **Gate questions.** Does the audience already exist? Which named buyer's monthly cost does it delete? Is it one operator's real workflow? Is it depth on an existing bet? A "no" on the first two is a stop.
2. **Name and brand.** The full product name (for example Ebda CRM), the Arabic spelling, host `<x>.ebda.app`. Add it to `PRODUCTS` in `packages/foundation/src/brand` and to `RESERVED_SLUGS` if it is a platform host: a foundation PR first, tagged, before the repo exists.
3. **Scaffold.** From a checkout of the latest tag: `node bin/ebda-foundation.mjs new ebda-crm`. You get a Hono Worker, a D1 binding, a Durable Object, CI, nightly audit, gitleaks, a vendored foundation and its lock, and a private repo under Whisky-11 with `EBDA_RUNS_ON` set. Use `--no-remote` to stay local.
4. **Identity.** Register the client with accounts.ebda.app (contract v1.4): audience and scopes.
5. **Suite contract.** If the product needs Store events or RPC, extend the contracts in the foundation first.
6. **Data.** D1 and Durable Object layout; the controller assigns migration numbers; add erasure registry entries from day one.
7. **Guards.** Rate limits, request shape, Zod at the edge, PII masking before any model call.
8. **Observability.** Telegram and Sentry wired, Logpush for at least 30 days, a status-page probe.
9. **CI on the shared runner.** `EBDA_RUNS_ON`, `scripts/foundation/workflow-lint.mjs`, the pre-push gate, `scripts/foundation/merge-gate.sh`.
10. **Deploy and verify.** The deploy job green, `/health` commit equals the tip of main, live cron schedules match wrangler (no weekday names), one scheduled tick seen.
11. **Legal.** Shared clauses plus the product's own documents, provisional markers kept.
12. **Launch.** Work through `checklists/launch.md`; flags stay off until proven.
13. **Register.** Add a row to SUITE-PARITY and to the bump bot's consumer list.
