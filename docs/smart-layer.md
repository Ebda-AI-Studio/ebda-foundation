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
