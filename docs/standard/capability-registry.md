# Standard: one capability registry per product

**Rule.** Every merchant capability of an Ebda product (live, in a PR or planned) has one file `capabilities/<id>.capability.json`, validated by `capabilitySchema` from `@ebda/foundation/capability`. Ids are the catalogue ids, unchanged (`onboarding.signup`). A page, route, MCP tool or plan gate without an entry fails CI. The product never writes its own registry rules: it imports the guards below and adds a thin adapter that turns its code into `CodeFacts`.

**Why.** Lens 192 (`os/standard/ai-native-self-service.md`): the Ebda AI Smart Layer can only answer "how do I" and act for the merchant for what the registry knows, and every feature needs a published help article in Egyptian Arabic and English. Without one registry shape and shared guards, each product drifts to its own format and "documented" becomes a claim nobody checks.

**Registry file.** Fields: `id`, `status` (`live` | `in-pr` | `planned`; `in-pr` needs `pr`, `planned` needs `plan`), `area`, `version` and `versionDate`, `titleAr`/`titleEn`, `screens`, `api`, `mcpTool`, `planGate`, `roles`, `policy` (`free` | `preview` | `confirm` | `forbidden`), `undo` (`reversible` | `compensating` | `irreversible` | `none`), `operatorReason` (code abuse, legal, money-dispute, platform-config or critical, for staff-only capabilities), `helpArticle` (slug under help.ebda.app, no language), `questions` (live: 3 to 6 Arabic, 1 to 3 English), `steps`, `edgeCases`, `gaps`. A POST that only reads (for example a sync that pulls remote state into local state) is declared with `readOnlyPost: { routes: ["POST /s/sync"], reason }`: it excuses only the routes it names (each must be a POST in `api`), every other write in the entry still counts, and it never excuses PUT, PATCH or DELETE. A screen wildcard must be `/<path>/*` with a concrete base; `/*` is rejected (`screen-wildcard`). `must-confirm` patterns are matched against the normalised route (case, trailing and double slashes, `:id`/`[id]`/`{id}` all fold to `:_`). `versionDate` must be a real date and `roles` non-empty. Seed the files once from the catalogue with `ebda-foundation capabilities seed`; a rerun never touches an existing file.

**Guards and baselines.** Five guards, each returns `Violation[]` (`{ rule, key, message }`):

| Guard | Module | Catches |
|---|---|---|
| registry | `capability-registry` | schema, lifecycle, policy vs writes/money/delete/irreversible, operator reasons, question counts, unset undo |
| coverage | `capability-coverage` | page, route, MCP tool or plan gate with no entry; a `live` entry naming a route that is not in code |
| superadmin | `self-service-routes` | staff-only route without a written reason; a reason the standard rejects |
| bypass | `smart-layer-bypass` | a direct model call outside `smartLayerPaths` |
| help | `help-article` | missing article, one language only, entry not linked in the article, stale version, orphan link |

Each guard has a baseline `capabilities/baselines/<guard>.json` (`{ "ids": ["rule|key", ...] }`) listing today's offenders. A violation in the baseline warns; a violation not in it fails; a baseline id that no longer violates also fails, so a fix leaves the baseline in the same PR. A baseline may only shrink: the `capability-ratchet` job (`ci/pr-quality/capability-ratchet.mjs`, run from the base checkout) fails a PR whose baseline holds an id the base lacks, rejects a NEW baseline file with ids once the base has any baseline, and treats a file that is not `{ "ids": [...] }` as invalid. The adoption PR (no script on the base yet) passes with a notice. The bypass guard detects Workers AI bindings (`env.AI`, `env["AI"]`, `const { AI } = env`, wrangler json/jsonc/toml), provider hosts (AI Gateway, OpenRouter, Groq, Mistral, Cohere, Together, Vertex, Bedrock, OpenAI, Anthropic, Gemini) and provider SDK imports (`from`, `require`, dynamic `import`, `@ai-sdk/*`); only `*.test.*`, `*.spec.*`, `.d.ts`, `__tests__/` and `__mocks__/` are exempt by name, a `test/` or `fixtures/` directory under `src/` is scanned. "Blocking for everyone" is the baselines reaching empty.

**Article link.** A help article lists the capabilities it explains in its front matter as `capabilities:` with `id@version` items. Bumping an entry's `version` makes its article `help-stale` until the article is updated and re-linked (deterministic, no clock). `ebda-foundation capabilities backfill-plan` lists what still needs an article, grouped by area; `scaffold` prints an MDX skeleton.

**Adopting in a product.**
1. Add `zod` `4.6.7` (exact) to the product's `package.json` BEFORE `ebda-foundation sync` (v0.2.0 or later): the vendored capability modules import it. `ebda-foundation check` and the parity test fail when it is missing or at another version.
2. Seed once: `ebda-foundation capabilities seed --product <store|chat> --catalogue <file> --out capabilities`, review the report (unclassified undo, unparsed roles, invalid reasons).
3. Write `capabilities/guard.config.json` (`guardConfigSchema`): `mustConfirm` money and customer-messaging routes, `routeKinds`, `helpExemptAreas`, `smartLayerPaths`.
4. Add a facts adapter and one thin test per guard that loads the files and a baseline and fails on `guardOutcome(...).failures`.
5. Copy `capability-ratchet.mjs` and `slop-guard.mjs` to `.github/pr-quality/` and add the `capability-ratchet` job from `.github/workflows/pr-quality.yml`.

**Gate.** Each product has the guard tests above in CI, and the `capability-ratchet` job on every PR. Foundation pins the rules in `packages/foundation/src/*.test.ts` and `test/capability-*.test.ts`.

sources: project-ebda-self-service-ai-native, project-ebda-program-register.
