# Changelog

## Unreleased
- `create/skeleton` (Worker, D1, Durable Object, CI, nightly, gitleaks) and `ebda-foundation new`, with an end-to-end test (`npm run test:new`, nightly).
- README, CONTRIBUTING, `docs/new-product.md`, `checklists/launch.md`.

## v0.2.0
- CLI `bin/ebda-foundation.mjs`: `sync`, `check`, `status`; lock format `foundation.lock.json`; parity test template `parity/foundation-parity.test.ts` (vendored into products); `ops/workflow-lint.mjs`, `ops/merge-gate.sh`, `merge-gate-required.mjs`, `host-lock.sh` ship to products as `scripts/foundation/`.

## v0.1.0
- Seed modules: `brand`, `tokens`, `phone` (PHONE-2), `buyer`, `text` (Store fold, FDN-TEXT-1), `slugs`, with vectors `phone.json`, `buyer-key.json`, `arabic.json`, `slugs.json`.
