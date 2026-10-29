# Contributing to ebda-foundation

- Changes start here, never in a consumer's vendored copy (its parity test would fail).
- Every module has tests; every behaviour shared across products has a vector file in `vectors/`. Changing a vector is a MAJOR or MINOR version with a CHANGELOG line saying why.
- Code must not import product DB/env/domain types. Worker-safe only (no Node built-ins outside `bin/`, `lib/`, `create/`); React only under a future `web/`.
- No orange and no bare "Ebda" (`tokens` and `brand` tests). Arabic-first: no per-letter animations; RTL mirrored.
- Dependencies: registry-real, under 12 months old, `npm audit` 0, versions pinned exactly.
- Merge only through the gate (`merge-gate.sh`); tag after the merge (`git tag vX.Y.Z`, push the tag); then bump each consumer with `sync`.
- Every rule override is written as a Ruling (`docs/rulings/<ID>.md`) with "cost if wrong".
- Docs parity: README module table + CHANGELOG in the same PR.
- Tests: `npm test` (module tests, CLI tests, and a fixture proving the parity template passes on a fresh sync and fails after a 1-byte edit). `sync` needs the foundation tree committed, so commit before running the CLI tests.
