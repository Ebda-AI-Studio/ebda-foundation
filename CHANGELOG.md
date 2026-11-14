# Changelog

## Unreleased
- UMBRA-RETIRE: Umbra (the local Linux CI VM) is retired. `ci-runner-guard.sh` now judges the native Mac runner fleet from the GitHub API (`orgs/<org>/actions/runners`) and no longer reads the `runner-fleet-paused` marker (which raised a false "PARKED ... queue FOREVER" alarm every cycle). Removed: guest-wedge-watch (+ launchd entry), guest-wedge / guest-rebuild / umbra-provisioning / safe-prune / runner-fleet / clock-drift libs, runner-focus, runner-reregister, the Linux-guest runner hooks, workspace-hygiene's VM trim, mac-maintenance's VM prune, `OS_UMBRA_VMS` / `OS_VM`. `create/new.mjs` now sets `EBDA_RUNS_ON` to `["self-hosted","ebda-mac"]`. Ruling UMBRA-RETIRE-1.
- CHAT-FDN: product `whatsapp` is now "Ebda Chat" / "ابدأ شات" (key and `whatsapp.ebda.app` unchanged); `BARE_EN`/`BARE_AR` allow Chat, no longer allow "Ebda WhatsApp". The consumers' other local edits (legal names, `foundedOn`) are NOT adopted: "Ebda Studio" trips the shipped-copy guard and needs its own decision. Consumers must re-run `ebda-foundation sync` to re-lock.

## v0.1.0
- Modules: `brand`, `tokens`, `phone` (Ebda Chat's `normaliseE164`, canonical), `buyer`, `text` (the Store's fold, canonical), `slugs`.
- Vectors: phone (36), buyer-key (8), buyer-key-probe, arabic (35), slugs.
- `buyerKeyProbe` throws below `MIN_PROBE_SECRET_LENGTH` (64); `/health` callers omit the field on error. `new` refuses a slug that is not in `RESERVED_SLUGS`.
- CLI: `sync`, `check`, `status`, `new`. `parity/foundation-parity.test.ts` (lock integrity + vectors).
- Skeleton for `new`: Hono Worker + D1 + SQLite Durable Object + static assets, CI on Umbra.
