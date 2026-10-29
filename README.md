# ebda-foundation

The shared base every Ebda AI Studio product starts from. Source of truth for code that two or more Ebda products must run identically (phone to E.164, the buyer key, Arabic folding, reserved slugs, brand names and tokens), plus the `new` generator for the next product.

Consumers (vendored, sha-pinned): Ebda Store `packages/shared/src/foundation`, Ebda WhatsApp `foundation/`. Both carry a `foundation.lock.json` and the same `foundation-parity` test.

## Modules (`@ebda/foundation/…`)

| Module | Exports | Example |
|---|---|---|
| `brand` | `EBDA` (names en/ar, products, colours, domains), `brandName`, `BARE_EN`, `BARE_AR` | `brandName('ar')` |
| `tokens` | `TOKENS`, `isOrange`, `tokens.css` (night, gold, lift, cream; no orange) | `isOrange('#FF6E01')` |
| `phone` | `normaliseE164`, `isE164`, `isEgyptianNational`, `asciiDigits`, `stripBidi` | `normaliseE164('٠١٠٠١٢٣٤٥٦٧')` |
| `buyer` | `buyerKey`, `buyerKeyProbe` (HMAC-SHA256 of the E.164, lowercase hex) | `await buyerKey(secret, '+201001234567')` |
| `text` | `foldArabic`, `indexTokens`, `phoneDigits` | `foldArabic('أحذية')` |
| `slugs` | `RESERVED_SLUGS`, `isReservedSlug`, `isDemoShowroomSlug`, `slugFormatError` | `isReservedSlug('wa')` |

`vectors/*.json` are the shared test vectors (phone, buyer-key, buyer-key-probe, arabic, slugs). Not shared yet (planned, see the program plan): search hooks, studio pages, legal clauses, contracts, identity, observe, erasure, guard, ops scripts.

**Not shared:** anything that imports a product's DB, env or domain types (tenants, checkout, payments, schema, migrations, flags, `wrangler.jsonc`, full legal documents, product copy).

## Consumed by vendoring, not a registry

`node bin/ebda-foundation.mjs sync --target <repo> --dir <vendored dir> --parity <test path>` copies the tagged source (no tests) plus `vectors/` into the consumer, stamps `foundationCommit` into the vendored `package.json`, copies `parity/foundation-parity.test.ts`, and writes `foundation.lock.json` (`tag`, `commit`, `dir`, `files` sha256). A consumer never edits vendored files: its parity test fails on any changed, missing or extra file, on a tag/commit mismatch, and on any shared-vector failure.

## Commands

- `sync --target <repo> --dir <dir> --parity <path>` (needs a clean, committed foundation checkout; the lock records its commit)
- `check [--target <repo>]` lock vs files, naming the offending file
- `status <repo>...` locks of the repos, the latest tag (`git ls-remote`) and whether the vendored content is identical
- `new ebda-<x> [--display "Ebda X"] [--display-ar "…"] [--no-remote] [--no-install] [--out <dir>]` scaffold a Hono + D1 + Durable Object Worker, vendor the foundation, `git init`, and (unless `--no-remote`) create `Whisky-11/ebda-<x>` privately and set `EBDA_RUNS_ON`

## Versioning

Semver. MAJOR = a breaking export or vector change: both consumer bump PRs open the same day. MINOR = additive. Every change lands with a CHANGELOG line and its vectors.
