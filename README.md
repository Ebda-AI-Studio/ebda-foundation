# ebda-foundation

The shared base every Ebda AI Studio product starts from: brand, tokens, phone, buyer key, Arabic text folding and slugs today; more modules follow the plan in `business/ebda/plans/2026-10-26-ebda-foundation.md`. One package, `@ebda/foundation`, TypeScript source with no build step.

## Modules

| Import | What it gives | Example |
|---|---|---|
| `@ebda/foundation/brand` | company and product names (en/ar), domains, `brandName`, `productName`, `brandFrom`, the bare-brand guard regexes `BARE_EN` / `BARE_AR` | `productName('crm', 'ar')` |
| `@ebda/foundation/tokens` and `tokens.css` | night, brand gold, metallic greys, radius, motion; no orange | `TOKENS.color.gold` |
| `@ebda/foundation/phone` | `normaliseE164` (valid Egyptian numbers without a prefix, anything else needs + or 00), `isE164`, `asciiDigits` | `normaliseE164('٠١٠٠١٢٣٤٥٦٧')` gives `+201001234567` |
| `@ebda/foundation/buyer` | `buyerKey(secret, e164)`: HMAC-SHA256 hex, the same customer key in every product | `await buyerKey(env.BUYER_KEY, e164)` |
| `@ebda/foundation/text` | `foldArabic` (the Store fold, canonical), `indexTokens`, `phoneDigits` | `foldArabic('مسئول')` gives `مسيول` |
| `@ebda/foundation/slugs` | `slugify`, `validateSlug`, `RESERVED_SLUGS`, `isReservedSlug` | `validateSlug('api')` is `SLUG_RESERVED` |

Shared behaviour is pinned by vector files in `vectors/` (phone and buyer-key come byte-identical from ebda-whatsapp commit 3f7878d, sha256 asserted in the tests).

**Not shared:** anything that would import a product's database, env or domain types (tenant, checkout, billing, schemas, migrations, product copy, full legal documents). If a module needs one of those, it is not foundation.

## How a product consumes it

Vendored copy plus a lock (Ruling FDN-DIST-1): `ebda-foundation sync` writes `foundation/`, `scripts/foundation/` (ops scripts) and the parity test into the product, and `foundation.lock.json` holds the tag, the commit and the sha256 of every file. The product never edits those files; `check` and the parity test fail when it does. No registry, no credentials, no network at install time. Moving to a registry later is mechanical because the package name and import paths do not change.

## Commands

```
node bin/ebda-foundation.mjs sync   [--target dir] [--dir foundation] [--ops scripts/foundation] [--parity test/foundation-parity.test.ts] [--to vX.Y.Z] [--commit sha]
node bin/ebda-foundation.mjs check  [--target dir]            # exit 1 and the file name on any drift
node bin/ebda-foundation.mjs status <repoDir>...              # store v1.3.0 · whatsapp v1.2.0 · latest v1.3.0 · skew 2 d
node bin/ebda-foundation.mjs new    ebda-crm [--no-remote]    # scaffold, vendor, git init, private repo, EBDA_RUNS_ON
```

Run the CLI from a checkout of the tag you want to vendor. `promote` (turn a consumer diff into a foundation branch) is not built yet.

## Versioning

Semver. MAJOR is a breaking export or contract change and needs both consumer bump PRs open the same day; MINOR may skew up to 7 days. Changing a vector file is at least MINOR and carries a CHANGELOG line saying why.

## Consumers

| Product | Tag | Status |
|---|---|---|
| Ebda Store | none yet | adopts at step F3 (after the Cloudflare cutover) |
| Ebda WhatsApp | none yet | adopts at step F2 |

See `docs/new-product.md` to build a new product and `CONTRIBUTING.md` to change the foundation.
