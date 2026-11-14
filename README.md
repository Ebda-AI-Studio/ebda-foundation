# ebda-foundation

The shared base every Ebda AI Studio product starts from. Source of truth for code that two or more Ebda products must run identically (phone to E.164, the buyer key, Arabic folding, reserved slugs, brand names and tokens), plus the `new` generator for the next product.

Consumers (vendored, sha-pinned): Ebda Store `packages/shared/src/foundation`, Ebda Chat (repo `ebda-whatsapp`) `foundation/`. Both carry a `foundation.lock.json` and the same `foundation-parity` test.

## Two layers, one repo

| Layer | Path | What it is | Who uses it |
|---|---|---|---|
| AI OS | `os/` (config in `os/config/os.env`, manifest in `os/MANIFEST.md`) | The operating tooling: merge gate, standards, audits, hooks, scheduled jobs. Ported in from the frozen predecessor. | Every business under Ebda AI Studio |
| Product library | `packages/`, `create/`, `vectors/`, `parity/` | The code two or more Ebda products must run identically, plus the `new` generator. | Every Ebda product, by vendoring |

Why one repo: Ruling FDN-OS-1 (`docs/rulings/FDN-OS-1.md`). The OS port is in progress; history of the move is in `docs/history/`.

## Modules (`@ebda/foundation/…`)

| Module | Exports | Example |
|---|---|---|
| `brand` | `EBDA` (names en/ar, products, colours, domains), `brandName`, `BARE_EN`, `BARE_AR` | `brandName('ar')` |
| `tokens` | `TOKENS`, `isOrange`, `tokens.css` (night, gold, lift, cream; no orange) | `isOrange('#FF6E01')` |
| `phone` | `normaliseE164`, `isE164`, `isEgyptianNational`, `asciiDigits`, `stripBidi` | `normaliseE164('٠١٠٠١٢٣٤٥٦٧')` |
| `buyer` | `buyerKey`, `buyerKeyProbe` (HMAC-SHA256 of the E.164, lowercase hex) | `await buyerKey(secret, '+201001234567')` |
| `text` | `foldArabic`, `indexTokens`, `phoneDigits` | `foldArabic('أحذية')` |
| `slugs` | `RESERVED_SLUGS`, `isReservedSlug`, `isDemoShowroomSlug`, `slugFormatError` | `isReservedSlug('wa')` |
| `capability` + `capability-registry`, `capability-coverage`, `self-service-routes`, `smart-layer-bypass`, `help-article`, `ratchet` | `capabilitySchema`, `normalizeApi`, `checkRegistry`, `checkCoverage`, `checkSelfServiceRoutes`, `checkModelBypass`, `checkHelp`, `applyBaseline` (lens 192 guards; `docs/standard/capability-registry.md`) | `checkRegistry(files, cfg)` |
| `smart-layer` (`@ebda/foundation/smart-layer`) | `runTurn`, the rails (`detectSecrets`, `maskForModel`, `scopeCheck`, `fence`, `checkBindingClaims`, `renderReply`, `allowLinks`), the execution gates (`validateCall`, `effectivePolicy`, `applyPreview`, `undoApplied`, `issueApproval`, `confirmApproval`), `resolveControls`, `computeReleaseId`, the eval harness (`releaseGate`, `passHatK`, `cohensKappa`) | `runTurn(adapter, ctx, { text })` (`docs/smart-layer.md`) |
| `instapay-extract` | `parseReceiptExtraction`, `parseAmountMinor`, `cairoWallTimeToEpoch`, `normalizeReference`, `INSTAPAY_EXTRACT_PROMPT`, `INSTAPAY_EXTRACT_JSON_SCHEMA` | `parseAmountMinor('١٬٢٠٠٫٥٠') === 120050`; `'1.200'` is `null` (ambiguous), never guessed |
| `instapay-decision` | `decideInstapay`, `normalizeHandle`, `REASON_ORDER` | pure money decision: auto-confirm iff zero reasons; every comparison fails closed |
| `instapay-state` | `nextAutoState`, `autoConfirmKey`, `revertKey`, `revertGraceUntil`, `firstPaymentCapMinor`, `isCleanPayment`, `unusedCreditsToRemove` | lifecycle table, 48 h grace, first-payment cap, 24 h clean-payment rule |
| `instapay-dedupe` | `DuplicateIndex`, `D1DuplicateIndex`, `MemoryDuplicateIndex`, `DEDUPE_SCHEMA_SQL`, `duplicateIndexContract` | platform-global reference + image index; each product runs the contract on its real D1 |
| `instapay-digest` | `formatDigest`, `formatWaiting`, `encodeTap`, `decodeTap`, `signBridge`, `verifyBridge` | digest text, `ip:` Telegram tap codec, HMAC bridge signature with a 5 minute window |

`vectors/*.json` are the shared test vectors (phone, buyer-key, buyer-key-probe, arabic, slugs, instapay-decision, instapay-extract). Not shared yet (planned, see the program plan): search hooks, studio pages, legal clauses, contracts, identity, observe, erasure, guard, ops scripts.

**Not shared:** anything that imports a product's DB, env or domain types (tenants, checkout, payments, schema, migrations, flags, `wrangler.jsonc`, full legal documents, product copy).

## Consumed by vendoring, not a registry

`node bin/ebda-foundation.mjs sync --target <repo> --dir <vendored dir> --parity <test path>` copies the tagged source (no tests; flat: `<dir>/phone.ts`, `<dir>/buyer.ts`, …) plus `vectors/` into the consumer, stamps `foundationCommit` into the vendored `package.json`, copies `parity/foundation-parity.test.ts`, and writes `foundation.lock.json` (`tag`, `commit`, `dir`, `files` sha256). A consumer never edits vendored files: its parity test fails on any changed, missing or extra file, on a tag/commit mismatch, and on any shared-vector failure.

## Commands

- `sync --target <repo> --dir <dir> --parity <path>` (needs a clean, committed foundation checkout; the lock records its commit)
- `check [--target <repo>]` lock vs files, naming the offending file
- `status <repo>...` locks of the repos, the latest tag (`git ls-remote`) and whether the vendored content is identical
- `new ebda-<x> [--display "Ebda X"] [--display-ar "…"] [--no-remote] [--no-install] [--out <dir>]` scaffold a Hono + D1 + Durable Object Worker, vendor the foundation, `git init`, and (unless `--no-remote`) create `Ebda-AI-Studio/ebda-<x>` privately and set `EBDA_RUNS_ON`

## Versioning

Semver. MAJOR = a breaking export or vector change: both consumer bump PRs open the same day. MINOR = additive. Every change lands with a CHANGELOG line and its vectors.

## Smart Layer API

`@ebda/foundation/smart-layer` is the engine behind the Ebda assistant (plan 4, `docs/smart-layer.md`). A product writes ONE adapter (`SmartLayerAdapter`: registry view, tools, help search, controls, quota, `checkRefs`, handoff, the Workers AI binding, storage) and calls:

```ts
import { runTurn, applyPreview, confirmApproval, undoApplied, resolveControls, computeReleaseId, resolveModels } from '@ebda/foundation/smart-layer';

const result = await runTurn(adapter, ctx, { text, untrusted: [{ kind: 'customer_message', text: inbound }] }, { onApprovalToken: (t) => res.setConfirmToken(t) });
// result.status: answered | refused | not_covered | handoff | off | limited; result.segments render; result.previews are cards.
```

- A turn never applies a change. A non-free tool call returns a preview card; the merchant's button calls `applyPreview` (preview class) or `confirmApproval(approvalId, token)` (confirm class) on its own route, and `undoApplied` within 24 h.
- The confirm token leaves only through `onApprovalToken`. Never persist it, log it, or put it in a prompt.
- `SmartLayerStorage` needs atomic `transitionPreview`, `claimApproval` and `closeApproval` (a SQL `UPDATE .. WHERE status = from`); `smart-layer/eval/memory-storage` is the reference behaviour.
- Model ids are configuration (`resolveModels`, ruling SL-MODEL-0: provisional bake-off leaders until SL-MODEL-1). Roll out with `resolveControls` (off, answer-only, suggest, act, per-store flag, product and global kill, tool kill, shadow).
- Add the vendored `smart-layer/` directory to the product's `capabilities/guard.config.json` `smartLayerPaths`.
