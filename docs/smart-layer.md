# Smart Layer engine

`@ebda/foundation/smart-layer` (`packages/foundation/src/smart-layer/`): one ordered input / plan / execute / output pipeline that Ebda Store and Ebda Chat plug into. Pure TypeScript, no Cloudflare bindings, no npm dependencies, no `node:` imports, extensionless relative imports (the Store compiles the vendored copy with CJS-mode `tsc`). Rulings: `docs/rulings/SL-*.md`.

## Pipeline (fixed order, tested)

```
controls -> rate/budget -> secrets -> mask -> scope -> fence -> help retrieval -> select tools (<= 15)
  -> model/tool loop [ validate args + refs -> policy gate -> preview | approval -> apply -> journal ]
  -> register (one regenerate) -> binding claims -> ui-truth -> link allowlist -> audit (masked, release id) -> quota
```

## Adapter contract

A product implements `SmartLayerAdapter` (`types.ts`): registry view (`toRegistryView` over its `capabilities/*.capability.json`), `tools()`, `helpSearch`, `bindingSources`, `merchantDomains`, `controls`, `quota`, `checkRefs`, `handoff`, the Workers AI binding `ai`, `models` (`resolveModels`) and `storage` (`SmartLayerStorage`). The engine never touches a database or a binding itself.

## Adding a tool

A `ToolSpec` declares its policy (`free | preview | confirm`, never in a prompt), `undo` class, `args` schema (`SchemaLike`, Zod in the adapter), `refs` (ids the model named, checked for existence and ownership), and `read` (free) or `preview` + `apply` + `inverse`. `forbidden` capabilities get no tool and are never offered. Big-change triggers (more than 20 affected items, checkout, price, money, delete, customer messaging, irreversible) escalate `preview` to `confirm`.

## Bypass guard

Every file that calls Workers AI must live under a path in the product's `capabilities/guard.config.json` `smartLayerPaths`. Consumers add the vendored engine directory (Store `packages/shared/src/foundation/smart-layer/`, Chat `foundation/smart-layer/`) with the reason "the engine is the Smart Layer" next to the adapter paths. `types.test.ts` runs `checkModelBypass` over the engine with exactly that allowlist.

## Models

Ids are configuration (`models.ts`, ruling SL-MODEL-0: provisional bake-off leaders until SL-MODEL-1). No model id appears elsewhere in the engine.

## Stages, files and what each one guarantees

| Stage | File | Guarantee (tested) |
|---|---|---|
| controls | `controls.ts` | default off; global kill > product kill > store flag; read again at apply time; shadow never applies |
| rate | `plan/budget.ts` | message <= 2,000 chars; 10 turns/user/min; 40 turns/conversation; adapter quota |
| secrets | `rails/secrets.ts` | passwords, MFA codes, card numbers, API keys, JWTs, PEM keys become `[secret]` before anything else sees the text; Arabic prefixes (والباسورد) and Franco handled |
| mask | `rails/mask.ts` | phones, e-mails, cards become placeholders (byte-identical to Ebda Chat) |
| handoff | `handoff.ts` | asked-for-a-human and frustration hand off before any model call |
| scope | `rails/scope.ts`, `rails/franco.ts` | injection / super-admin / abuse / off-topic blocked by the lexicon in Arabic, Franco, English; the classify model runs only when the lexicon is undecided and fails open |
| fence | `rails/fence.ts` | untrusted text is wrapped and cannot close its own fence |
| help | `help.ts` | grounding verdict; below 0.35 the answer is "not covered", the second time a handoff |
| select | `plan/select-tools.ts` | at most 15 tools; only live, non-forbidden, non-killed; answer-only = free only; untrusted context = free only |
| model/tools | `loop.ts`, `exec/validate.ts` | args parsed then every id checked in this store; errors list paths, never values |
| preview | `exec/policy.ts`, `exec/journal.ts` | big-change triggers; apply = etag re-preview + CAS claim; undo 24 h |
| confirm | `exec/approval.ts` | token hash only, single use, 15 min, bound to the payload hash; token leaves only via `onApprovalToken` |
| register | `rails/register.ts` | one regenerate if score < 0.6, then ship with the score in the audit row (SL-REG-1) |
| binding | `rails/binding-claims.ts` | amounts, percents, durations, plan names, refund/legal sentences survive only if sourced |
| render | `rails/ui-truth.ts` | screens and articles only through `[[cap:id]]` / `[[help:id]]`; unknown ids, raw paths, invented button labels removed |
| links | `rails/links.ts` | https on ebda.app + merchant domains only; images dropped to alt text |
| audit | `audit.ts`, `release.ts` | masked again, release id on every row |

## Adapter obligations the engine cannot enforce

- `SmartLayerStorage.transitionPreview`, `claimApproval`, `closeApproval` MUST be atomic (SQL `UPDATE .. WHERE status = from`, checked rows). Two presses must apply once.
- `tool.apply` must run the product's normal authorization and throw `ToolForbidden` on refusal; `tool.preview` must return an `etag` that changes when the item changes and a real `affectedCount` (Arabic-Indic digits folded).
- `checkRefs` runs under the merchant's tenant context and must not throw for "not found" (return it in `missing`).
- The HTTP confirm route must pass the merchant's own session `ctx` (role re-read per request) and show the token only to the browser that rendered the card.
- Never persist or log the value given to `onApprovalToken`.

## Rollout (spec 6.10)

Stage 0: internal stores `act` with manual audit review. Stage 1: allowlist `answer-only`. Stage 2: `suggest`. Stage 3: `act`, with a daily review of the first 100 confirms; widen from there. Safety classes must be 100% pass^5 (`releaseGate`) before `act` is enabled for confirm tools.
