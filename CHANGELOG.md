# Changelog

## Unreleased
- UMBRA-RETIRE: Umbra (the local Linux CI VM) is retired. `ci-runner-guard.sh` now judges the native Mac runner fleet from the GitHub API (`orgs/<org>/actions/runners`) and no longer reads the `runner-fleet-paused` marker (which raised a false "PARKED ... queue FOREVER" alarm every cycle). Removed: guest-wedge-watch (+ launchd entry), guest-wedge / guest-rebuild / umbra-provisioning / safe-prune / runner-fleet / clock-drift libs, runner-focus, runner-reregister, the Linux-guest runner hooks, workspace-hygiene's VM trim, mac-maintenance's VM prune, `OS_UMBRA_VMS` / `OS_VM`. `create/new.mjs` now sets `EBDA_RUNS_ON` to `["self-hosted","ebda-mac"]`. Ruling UMBRA-RETIRE-1.
- CHAT-FDN: product `whatsapp` is now "Ebda Chat" / "ابدأ شات" (key and `whatsapp.ebda.app` unchanged); `BARE_EN`/`BARE_AR` allow Chat, no longer allow "Ebda WhatsApp". The consumers' other local edits (legal names, `foundedOn`) are NOT adopted: "Ebda Studio" trips the shipped-copy guard and needs its own decision. Consumers must re-run `ebda-foundation sync` to re-lock.

## v0.2.0
- Capability registry and charter guards (lens 192; plan 2026-11-14-charter-guards-registry-help): modules `capability` (Zod schema, enums, `normalizeApi`, `helpUrl`, guard config), `capability-registry`, `ratchet`, `capability-coverage`, `self-service-routes`, `smart-layer-bypass`, `help-article`. `zod` 4.6.7 is a peer dependency of `@ebda/foundation`.
- Registry rule `policy-free-writes` allows a declared read-only POST through a per-entry `readOnlyPost: { routes, reason }` flag naming the excused routes (for example Chat `templates.sync`); PUT, PATCH, DELETE and unnamed POSTs are never excused. New rules `readonlypost-unknown-route` and `screen-wildcard`; `must-confirm` runs on the normalised route; `normalizeApi` folds `[id]` and `{id}` too; the schema rejects impossible dates and empty `roles`.
- Bypass guard covers `env["AI"]`, destructured `AI`, AI Gateway and other provider hosts, provider SDK imports in every form, wrangler.toml, and no longer skips `test/` or `fixtures/` directories under `src/`.
- Ratchet rejects a new baseline file with ids after adoption and a baseline without `ids`; the workflow job passes with a notice on the adoption PR. Seed fails on duplicate or path-unsafe ids. Vendoring products must declare `zod` 4.6.7: `check`, the parity test and the `new` skeleton enforce it.
- CLI: `ebda-foundation capabilities seed | backfill-plan | scaffold` (`lib/capability-seed.mjs`, `lib/capability-backfill.mjs`). Seed against the real 2026-11-14 catalogues: Store 185 and Chat 172 entries, 71 and 23 live merchant entries without a help article.
- CI: `ci/pr-quality/capability-ratchet.mjs` and a `capability-ratchet` job in `pr-quality.yml` (baselines may only shrink, judged against the base branch).
- Standard: `docs/standard/capability-registry.md`.

## v0.1.0
- Modules: `brand`, `tokens`, `phone` (Ebda Chat's `normaliseE164`, canonical), `buyer`, `text` (the Store's fold, canonical), `slugs`.
- Vectors: phone (36), buyer-key (8), buyer-key-probe, arabic (35), slugs.
- `buyerKeyProbe` throws below `MIN_PROBE_SECRET_LENGTH` (64); `/health` callers omit the field on error. `new` refuses a slug that is not in `RESERVED_SLUGS`.
- CLI: `sync`, `check`, `status`, `new`. `parity/foundation-parity.test.ts` (lock integrity + vectors).
- Skeleton for `new`: Hono Worker + D1 + SQLite Durable Object + static assets, CI on Umbra.
