# Standard: one Store-Chat contract, one request-protection toolkit, one erasure vocabulary (F5, F9)

**Rule.** The Store <-> Chat event contract (`@ebda/foundation/contracts/wa-v1`, v1.6) is ONE file, vendored into both products; neither edits its copy. A contract change is a foundation PR plus a release plus a re-vendor in both products. The manual sha pin (Ruling WA-CONTRACT-1) is retired when a product consumes the vendored file, because `foundation-parity` already pins every vendored file by sha. The foundation keeps `WA_V1_CONTRACT_SHA256` and a test so the bytes cannot drift unnoticed before that.

| Module | Owns |
|---|---|
| `contracts/wa-v1` | `storeEventSchema`, `outboundStoreEventSchema`, `parseStoreEvent`, `CONTRACT_VERSION` (bytes identical to the pre-F5 copies) |
| `contracts/wa-v1-verify` | `parseOutboundStoreEvent`, `WA_V1_CONTRACT_SHA256` |
| `identity-claims` | `Principal`, `IdentityError`, `IdentityVerifier`, `claimAt`, `claimStrings`, `mapRole`, `isIdToken` (signature checking stays in each product: it needs its own JWKS) |
| `request-guard` | `checkRequestShape`/`guardShape` (413 oversize, 415 wrong type), `readCapped`, `bodyShapeViolation`, `Buckets` (isolate-local, BOUNDED-stale), `FixedWindowLimiter` over a `RateLimitStore` with an explicit `failMode` (`closed` for money routes), `clientKey` |
| `erasure` | `Subject`, `ErasureSurface`, `SurfaceResult`, `erasureOutcome`, `unlistedPersonalTables` (PDPL checklist: every table with phone/buyer_key/email is a target or exempt with a written reason), `unclassifiedTables`, `scrubGaps` |

**How a product uses the checklist.** Its test reads the live schema (table -> columns) and fails on any entry of `unlistedPersonalTables(columns, targets, exempt)`. An exemption with an empty reason does not count.

**Residual.** `Buckets` is per isolate (up to isolates x rate); never use it for money or permissions. Chat's tracked-link and webhook limits and Store's 24 express limiters keep their own limits and keys; they adopt these helpers one by one in the consumer PRs.
