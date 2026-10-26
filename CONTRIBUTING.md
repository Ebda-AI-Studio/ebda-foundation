# Contributing to ebda-foundation

- Changes start here, never in a consumer's vendored copy (the drift test fails it).
- Every module has tests; every behaviour shared across products has a vector file in `vectors/`. Changing a vector is a MINOR or MAJOR version with a CHANGELOG line saying why.
- Code must not import a product's database, env or domain types. Worker-safe only (no Node built-ins outside `ops/` and `bin/`); React only under `web/` once that module exists.
- No orange and no bare master brand name: the guard tests in `test/` and `packages/foundation/src/tokens` enforce both.
- Arabic first: no per-letter animations, mirror for RTL.
- Dependencies: registry-real, younger than 12 months is not required but the package must be maintained, licence checked, versions pinned exactly, `npm audit` at 0. Peer dependencies for react, hono, jose, zod.
- Merge only through `ops/merge-gate.sh <pr> <head-sha>`; tag after the merge (`vX.Y.Z`, matching `packages/foundation/package.json`); the bump bot then opens the consumer PRs.
- Any call that overrides a plan, rejects a finding or accepts a residual is written in `docs/RULINGS.md` as `Ruling <id> - <decision>. <evidence>. Cost if wrong: <one sentence>.`
- Docs parity: the README module table and the CHANGELOG are updated in the same PR.
- Branch and PR flow: work in a worktree branch, empty first commit, PR to `main`, never commit on the root checkout.
