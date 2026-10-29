# How to build a new Ebda product

1. Gate questions: does the audience already exist? Which named buyer's KWD/month cost do we delete? Whose one workflow is it? Is it depth on an existing bet? A "no" on the first two is a STOP.
2. Name and brand: "Ebda <X>", Arabic "ابدأ <X>", host `<x>.ebda.app`. Add the product to `brand` and the host to `RESERVED_SLUGS` in a foundation PR first.
3. `new` refuses unless the slug is already in `RESERVED_SLUGS` (otherwise a store could claim `<x>.ebda.app` first): land that foundation PR and tag first. `node bin/ebda-foundation.mjs new ebda-<x>` from a clean tagged foundation checkout (`npx --yes github:Whisky-11/ebda-foundation new ebda-<x>` once the repo is fetchable). You get a Hono Worker, D1 + Durable Object bindings, CI, the vendored foundation and its parity test.
4. Identity: register the client with accounts.ebda.app (contract), audience, scopes.
5. Suite contract: if it needs Store events/RPC, extend the contracts first.
6. Data: D1/DO layout, migration registry, erasure registry entries from day 1.
7. Guards: rate limits, request shape, Zod at the edge, PII masking before any LLM.
8. Observability: Telegram + Sentry, Logpush >= 30 days, status-page probe.
9. CI on Umbra: `EBDA_RUNS_ON`, workflow lint, pre-push gate, merge gate.
10. Deploy and verify: deploy job green, `/health` commit equals main, live cron schedules (no weekday names), one scheduled tick.
11. Legal: shared clauses plus the product's own documents, provisional markers.
12. Launch checklist: `checklists/launch.md`; flags off until proven.
13. Add the product to the suite parity table and to the foundation consumers list in the README.
