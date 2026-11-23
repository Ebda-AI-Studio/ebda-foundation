# Charter Guards, Capability Registry and Help Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make lens 192 (AI-native, self-service, help-article) enforceable in CI for Ebda Store and Ebda Chat: one capability registry per product, seeded from the 2026-11-14 catalogues, four ratcheted guards defined once in ebda-foundation, Chat guides published with capability links, and a batched help backfill that ends with the guards blocking for everyone.

**Architecture:** Pure functions plus a Zod schema ship in `@ebda/foundation` (vendored by `ebda-foundation sync`); each product adds a thin adapter that turns its own code into `CodeFacts` (globbed pages, the real route table, MCP tools) and a thin test per guard. Every guard returns `Violation[]`; a per-guard shrink-only baseline file tolerates today's offenders, so anything new fails from day one and "blocking for all" is simply the baseline reaching empty. The baseline cannot be grown by a PR because a pr-quality-style job compares it to the base branch.

**Tech Stack:** TypeScript 5.9, Zod 4.6.7, Vitest 4.1.12 (foundation, Store); Vitest workers pool plus a node project (Chat); plain Node >=20 `.mjs` for CLI and CI scripts; Express 4 route-table walk (Store); Hono `app.routes` (Chat); help site `apps/help` (MDX, static build).

**Spec:** `docs/superpowers/specs/2026-11-14-self-service-and-ebda-assistant-design.md` (sections 6.8, 6.8b, 6.9, 10b.7, Appendix A) and the standard `os/standard/ai-native-self-service.md` (lens 192). Both arrive with branch `docs/self-service-assistant-design`; this plan's branch must be rebased onto main after that merges. This is sub-plan 1 of 4; the Smart Layer engine, the project-1 blockers and projects 3/4 are separate plans.

## Scope and order

Four repos, three kinds of change. Foundation (Tasks 1-10) merges and is tagged v0.2.0 first. Then Store (Tasks 11-14), Chat (Tasks 15-17) and the Chat-source import in Store (Task 18) adopt it; each repo's tasks go in one PR. Then the backfill (Tasks 19-30) and the flip to blocking (Task 31). Work in worktrees (`~/.claude/scripts/new-task-worktree.sh <repo> <branch>`), never the repo roots. No product behaviour changes: registries, tests, help content and CI only.

Not in this plan (belongs to later sub-plans): the Smart Layer engine and its `inverse` handlers (undo handler names are NOT required here), the tools layer, golden-set eval hook, the weekly unanswered-questions report, and the lens-192 probe plus known-bad fixture in the audit fleet (a lens in `os/standard/` grades nothing until that probe exists; tracked as a follow-up to sub-plan 4).

## Global Constraints

- Scope is everything: every existing feature, every new feature, every upcoming product (CRM, ERP, Ads, Invites, Quote Studio); no feature is exempt for being new, small, internal or "later" (standard 192, scope paragraph).
- Assistant policy values, exactly: `free` | `preview` | `confirm` | `forbidden`. Status values, exactly: `live` | `in-pr` | `planned`. Undo classes (spec 6.9): `reversible` | `compensating` | `irreversible`; an `irreversible` action is always `confirm` (or `forbidden`).
- Valid super-admin/operator reasons (spec 7.1): abuse, legal, money-dispute, platform-config, critical.
- A `live` capability needs: a registry entry, a help article in Egyptian Arabic AND English on help.ebda.app (served from ebda-store `apps/help`), and example questions. `planned` counts as an entry and gets its article in the PR that ships it.
- Capability ids are the catalogue ids, unchanged (`onboarding.signup`, `templates.create-submit`).
- Guard shape: baseline ids may only shrink (a fixed violation leaves the baseline in the same PR); CI fails on a new violation and on a baseline that grew.
- Copy: Egyptian Arabic in full sentences, English second; Ebda is night plus gold `#B08D57`, no orange. Never write bare "Ebda"; products are "Ebda Store", "Ebda Chat".
- Dependencies: registry-real, under 12 months old, `npm audit` 0/0/0/0; Zod is pinned `4.6.7` (both products already use it). Foundation modules are pure (no file access); loaders live in products or in `.mjs` CLI code.
- Foundation repo rules: tracked files must pass `os/tests/no-force-strings.test.sh` (no predecessor-business names, no client names); `git add` specific paths only; every new worktree branch starts with an empty commit (the script does it); CI runs lint + typecheck + affected tests only.
- Docs parity: each task ships its docs in the same PR (standard doc, `CHANGELOG.md`, product README line).

## Review Focus

Failure modes the spec implies but the obvious tests would miss, most likely first. Each has a pinning test named in its owning task.

1. **Route path normalisation:** `/stores/:storeId/orders/`, `/stores/:id/orders` and an encoded `/ord%65rs` must resolve to the same capability claim; a route claimed under another param name or with a trailing slash must not show up as "uncovered" (Task 4).
2. **Planned and in-pr entries list APIs that do not exist yet:** the reverse check (entry names a route that is not in code) must fail for `live` entries only (Task 4).
3. **Help in one language only:** an article present in `ar` but missing its `en` twin (or the reverse) must fail, not count as "has an article" (Task 7).
4. **A PR that edits the baseline to hide its own offence:** adding an id to a baseline file must fail even though the test then passes against the edited baseline (Tasks 3 and 5's workflow job).
5. **Re-running the seed generator overwrites human-edited entries** (reviewed questions, undo classes, reasons): a rerun must add missing ids only and never touch an existing file (Task 8).

## File structure

Foundation (`ebda-foundation`):
- `packages/foundation/src/capability.ts` (+ `.test.ts`): Zod schema, enums, `normalizeApi`, `Violation`, guard-config schema.
- `packages/foundation/src/capability-registry.ts`: registry-internal rules (ids, lifecycle, policy, questions, reasons).
- `packages/foundation/src/ratchet.ts`: violation ids, baseline application, baseline growth.
- `packages/foundation/src/capability-coverage.ts`: `CodeFacts`, coverage rules.
- `packages/foundation/src/self-service-routes.ts`: operator/super-admin route reasons.
- `packages/foundation/src/smart-layer-bypass.ts`: direct model-call finder.
- `packages/foundation/src/help-article.ts`: front-matter parser, `checkHelp`, freshness, `helpUrl`.
- `lib/capability-seed.mjs`, `lib/capability-backfill.mjs`: seed and backfill tooling (Node, uses fs).
- `ci/pr-quality/capability-ratchet.mjs` (+ job in `.github/workflows/pr-quality.yml`): base-branch baseline comparison.
- `docs/standard/capability-registry.md`: the adoption standard.
- `bin/ebda-foundation.mjs`: new `capabilities` subcommand.

Each product: `capabilities/<id>.capability.json`, `capabilities/guard.config.json`, `capabilities/baselines/<guard>.json`, a facts adapter, and one test file per guard.

---

### Task 1: Capability schema and enums

**Files:**
- Create: `packages/foundation/src/capability.ts`, `packages/foundation/src/capability.test.ts`
- Modify: `packages/foundation/package.json` (exports `./capability`, `peerDependencies.zod`), root `package.json` (devDependency `zod` `4.6.7`, regenerate `package-lock.json`)

**Interfaces:**
- Produces:
  - `POLICIES`, `STATUSES`, `UNDO_CLASSES = ['reversible','compensating','irreversible','none','unclassified']`, `ROLES = ['public','customer','owner','staff','super_admin','operator']`, `OPERATOR_REASONS`, each `as const`.
  - `capabilitySchema` (Zod) and `type Capability` with fields: `id`, `status`, `pr?`, `plan?`, `area`, `version: number` (int >= 1), `versionDate: string` (ISO date), `titleAr`, `titleEn`, `screens: string[]`, `screenGap?: string`, `api: string[]`, `mcpTool: string|null`, `planGate: string|null`, `roles: Role[]`, `policy`, `undo: { class; note? }`, `operatorReason?: { code: OperatorReason|null; text: string; validUnderRule: boolean }`, `helpArticle: string|null` (slug under the help site, no extension, no language: `account-security`, `whatsapp/templates-and-the-24-hour-window`), `helpGap?: string`, `questions: { ar: string[]; en: string[] }`, `steps: string[]`, `edgeCases: string[]`, `gaps: string[]`, `assistantNote?: string`.
  - `normalizeApi(s: string): string` ("GET /stores/:storeId/orders/" -> `GET /stores/:_/orders`).
  - `interface Violation { rule: string; key: string; message: string }`.
  - `guardConfigSchema` / `type GuardConfig`: `{ product: string; mustConfirm: { method?: string; pattern: string }[]; routeKinds: { match: string; kind: 'public'|'internal'|'merchant'|'super_admin'|'operator' }[]; helpExemptAreas: string[]; smartLayerPaths: string[] }`.
  - `helpUrl(slug: string, lang: 'ar'|'en'): string` -> `https://help.ebda.app/<slug>/` (ar) or `/en/<slug>/`.

- [ ] **Step 1: Write failing tests in `capability.test.ts`:** a minimal valid entry parses; `status: 'live'` with `helpArticle: null` and no `helpGap` still parses (the help rule is a guard, not a schema rule); `policy: 'maybe'` fails; `id: 'Bad Id'` fails (regex `^[a-z0-9]+(\.[a-z0-9-]+)+$`); `versionDate: '14/11/2026'` fails; `normalizeApi('get /stores/:storeId/orders/')` equals `'GET /stores/:_/orders'`, `normalizeApi('GET /ord%65rs')` equals `'GET /orders'`, `normalizeApi('POST //a//b')` equals `'POST /a/b'`; `helpUrl('whatsapp/x','en')` equals `'https://help.ebda.app/en/whatsapp/x/'`.
- [ ] **Step 2: Run** `npx vitest run packages/foundation/src/capability.test.ts`. Expected: FAIL (module missing).
- [ ] **Step 3: Implement** the exports above. `normalizeApi` upper-cases the method, `decodeURIComponent`s the path (leave undecodable text as is), collapses `//`, strips one trailing `/`, replaces every `:name` segment with `:_`. Add `zod` as devDependency in the root workspace (genuine lockfile change; use `npm install -D zod@4.6.7 --save-exact`), `peerDependencies: { "zod": "4.6.7" }` in the package.
- [ ] **Step 4: Run** the same test plus `npm run typecheck`. Expected: PASS, 0 errors.
- [ ] **Step 5: Commit** `feat(capability): registry schema, enums and api normaliser`.

### Task 2: Registry-internal rules

**Files:**
- Create: `packages/foundation/src/capability-registry.ts`, `packages/foundation/src/capability-registry.test.ts`

**Interfaces:**
- Consumes: Task 1 (`Capability`, `GuardConfig`, `Violation`, `normalizeApi`).
- Produces: `checkRegistry(files: { name: string; json: unknown }[], cfg: GuardConfig): { entries: Capability[]; violations: Violation[] }`. Rules (rule ids): `schema` (Zod failure, key = file name), `id-filename` (file must be `<id>.capability.json`), `id-duplicate`, `lifecycle` (`in-pr` needs `pr`, `planned` needs `plan`, `live` may carry neither), `policy-free-writes` (policy `free` while any `api` method is not GET), `policy-must-confirm` (an `api` matching a `cfg.mustConfirm` rule, or any `DELETE`, with a policy other than `confirm`/`forbidden`), `policy-irreversible` (undo `irreversible` with policy `free` or `preview`), `operator-forbidden` (roles contain only `super_admin`/`operator` but policy is not `forbidden`), `operator-reason` (such an entry without `operatorReason.code`), `questions-count` (live: `ar` 3-6 and `en` 1-3; planned and in-pr: at least 1 of each), `undo-unclassified` (class `unclassified`).

- [ ] **Step 1: Failing tests,** one per rule id, each building a minimal entry and asserting exactly one violation with that rule and `key` equal to the id; plus `it('a live entry with 2 Arabic questions fails questions-count')`, `it('operator-only entry with policy confirm fails operator-forbidden')`, `it('a free entry whose api has POST fails policy-free-writes')`, and `it('two files declaring one id yield id-duplicate on the second')`.
- [ ] **Step 2: Run** `npx vitest run packages/foundation/src/capability-registry.test.ts`. Expected: FAIL.
- [ ] **Step 3: Implement `checkRegistry`.** Pure; never throws on bad JSON (schema failure becomes a violation and the entry is dropped from `entries`).
- [ ] **Step 4: Run** the test. Expected: PASS.
- [ ] **Step 5: Commit** `feat(capability): registry rules (lifecycle, policy, reasons, questions)`.

### Task 3: Ratchet

**Files:**
- Create: `packages/foundation/src/ratchet.ts`, `packages/foundation/src/ratchet.test.ts`

**Interfaces:**
- Consumes: `Violation` (Task 1).
- Produces:
  - `violationId(v: Violation): string` -> `` `${v.rule}|${v.key}` ``.
  - `applyBaseline(violations: Violation[], baseline: string[]): { fresh: Violation[]; tolerated: Violation[]; stale: string[] }` (`fresh` = not in baseline; `stale` = baseline ids with no current violation).
  - `baselineGrowth(pr: string[], base: string[]): string[]` (ids in `pr` that `base` lacks).
  - `guardOutcome(r: ReturnType<typeof applyBaseline>): { failures: string[]; warnings: string[] }` (failures: one line per fresh violation and per stale id; warnings: one `::warning::` line per tolerated violation).

- [ ] **Step 1: Failing tests:** a violation in the baseline is tolerated and yields a warning, not a failure; a violation not in the baseline is fresh and fails; a baseline id with no violation is stale and fails (review focus 4, first half); `baselineGrowth(['a','b'],['a'])` equals `['b']`; `guardOutcome` of an empty result is `{ failures: [], warnings: [] }`.
- [ ] **Step 2: Run** `npx vitest run packages/foundation/src/ratchet.test.ts`. Expected: FAIL.
- [ ] **Step 3: Implement** the four functions (set arithmetic, order-preserving).
- [ ] **Step 4: Run** the test. Expected: PASS.
- [ ] **Step 5: Commit** `feat(capability): shrink-only baseline helpers`.

### Task 4: Coverage guard

**Files:**
- Create: `packages/foundation/src/capability-coverage.ts`, `packages/foundation/src/capability-coverage.test.ts`

**Interfaces:**
- Consumes: Tasks 1-2.
- Produces:
  - `interface CodeFacts { pages: string[]; routes: { method: string; path: string; kind: 'merchant'|'public'|'internal'|'super_admin'|'operator' }[]; mcpTools?: string[]; planGates?: string[] }`.
  - `pageMatches(pattern: string, page: string): boolean` (`/stores/[id]/x/*` matches any sub-path; exact otherwise; compare after `normalizeApi`-style param folding of `[id]`, `:id`).
  - `checkCoverage(facts: CodeFacts, entries: Capability[]): Violation[]`. Rules: `page-uncovered` (key = page), `route-uncovered` (kind merchant/super_admin/operator only; key = `METHOD path`), `route-dangling` (a `live` entry names an `api` absent from `facts.routes`; key = `<id> <api>`), `tool-uncovered` (a fact tool that no entry has as `mcpTool`; skipped when `mcpTools` undefined), `plangate-uncovered` (same for `planGate`).

- [ ] **Step 1: Failing tests:** a route `GET /stores/:storeId/orders/` in facts is covered by an entry listing `GET /stores/:id/orders`; `GET /ord%65rs` in facts is covered by `GET /orders` (review focus 1); a `public` route needs no entry; a `planned` entry listing `POST /not-built` yields no `route-dangling` while the same entry as `live` yields one (review focus 2); page `/stores/[id]/marketing/seo` is covered by pattern `/stores/[id]/marketing/*`; an uncovered page and an uncovered MCP tool each yield one violation with the expected key.
- [ ] **Step 2: Run** `npx vitest run packages/foundation/src/capability-coverage.test.ts`. Expected: FAIL.
- [ ] **Step 3: Implement.** Index claimed routes once in a `Set` of `normalizeApi` strings; one pass per fact kind.
- [ ] **Step 4: Run** the test. Expected: PASS.
- [ ] **Step 5: Commit** `feat(capability): coverage guard for pages, routes, tools and plan gates`.

### Task 5: Self-service route guard and the ratchet CI job

**Files:**
- Create: `packages/foundation/src/self-service-routes.ts`, `packages/foundation/src/self-service-routes.test.ts`, `ci/pr-quality/capability-ratchet.mjs`, `test/capability-ratchet.test.ts`
- Modify: `.github/workflows/pr-quality.yml` (new job `capability-ratchet`, same shape as `slop-baselines`), `ci/pr-quality/README.md` (adopt step)

**Interfaces:**
- Consumes: Tasks 1, 3, 4 (`CodeFacts`).
- Produces:
  - `checkSelfServiceRoutes(facts: CodeFacts, entries: Capability[]): Violation[]`. Rules: `superadmin-route-unreasoned` (a route of kind `super_admin` or `operator` that no entry claims in `api`, or whose claiming entry lacks `operatorReason.code`, is not `forbidden`, or has a non-operator role; key = `METHOD path`), `operator-reason-invalid` (entry with `operatorReason.validUnderRule === false`; key = id; these are the self-service gaps that projects 1 and 4 close).
  - `ci/pr-quality/capability-ratchet.mjs --base <base-checkout> --pr <pr-checkout>`: for every `capabilities/baselines/*.json`, exits 1 listing each id the PR file has and the base file lacks (a base with no file yet = adoption PR, allowed). It runs from the base checkout, like `slop-guard.mjs --base-root` (Ruling PRQ-3).

- [ ] **Step 1: Failing tests:** (a) an unclaimed `operator` route yields `superadmin-route-unreasoned`; the same route claimed by an entry with `operatorReason.code: 'platform-config'`, policy `forbidden`, roles `['super_admin']` yields none; a claiming entry with policy `confirm` still yields one. (b) `test/capability-ratchet.test.ts` builds two temp dirs and asserts exit 1 plus the id in stderr when the PR baseline gains an id, exit 0 when it only loses ids, exit 0 when the base has no baselines dir (review focus 4).
- [ ] **Step 2: Run** `npx vitest run packages/foundation/src/self-service-routes.test.ts test/capability-ratchet.test.ts`. Expected: FAIL.
- [ ] **Step 3: Implement** both; the `.mjs` is dependency-free and refuses symlinks via the same `readJsonRegular` approach as `slop-guard.mjs` (import it, do not copy it). Add the workflow job, then `npm run lint:workflows`.
- [ ] **Step 4: Run** the two test files and `npm run lint:workflows`. Expected: PASS, no workflow-lint findings.
- [ ] **Step 5: Commit** `feat(capability): self-service route guard and baseline-growth ci job`.

### Task 6: Smart Layer bypass guard

**Files:**
- Create: `packages/foundation/src/smart-layer-bypass.ts`, `packages/foundation/src/smart-layer-bypass.test.ts`

**Interfaces:**
- Consumes: `Violation`, `GuardConfig.smartLayerPaths`.
- Produces: `MODEL_CALL_PATTERNS: readonly { name: string; re: RegExp }[]` (Workers AI binding `\benv\.AI\b` and `\.AI\.run\(`, `@google/genai`, `@google/generative-ai`, `generativelanguage.googleapis.com`, `api.openai.com`, `api.anthropic.com`, `@anthropic-ai/sdk`, `from 'openai'`, a `"ai":` binding block in `wrangler.jsonc`); `checkModelBypass(files: { path: string; src: string }[], cfg: Pick<GuardConfig,'smartLayerPaths'>): Violation[]`, rule `model-call-outside-smart-layer`, key = `<path>|<pattern name>|<sha1(trimmed line).slice(0,10)>|<ordinal among identical keys>` (content hash, never a line number, so unrelated edits do not churn the baseline). Test files, `.d.ts` and files under `smartLayerPaths` are skipped; comments are stripped first (reuse `stripComments` from `guards.ts`).

- [ ] **Step 1: Failing tests:** `env.AI.run(` in `src/a.ts` yields one violation; the same text in a `//` comment yields none; the same text under a `smartLayerPaths` prefix yields none; two identical lines in one file yield two distinct keys; moving the line down 40 lines leaves the key unchanged; a `wrangler.jsonc` with `"ai": { "binding": "AI" }` yields one violation.
- [ ] **Step 2: Run** `npx vitest run packages/foundation/src/smart-layer-bypass.test.ts`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the test. Expected: PASS.
- [ ] **Step 5: Commit** `feat(capability): smart layer bypass guard`.

### Task 7: Help front-matter, help guard and freshness

**Files:**
- Create: `packages/foundation/src/help-article.ts`, `packages/foundation/src/help-article.test.ts`

**Interfaces:**
- Consumes: Tasks 1, 2.
- Produces:
  - `parseHelpFrontMatter(raw: string): { data: Record<string, string | string[]>; body: string }`: a minimal YAML subset (scalars, quoted scalars, block lists of strings) that must accept the existing Store articles as they are (`title`, `description`, `section`, `order`, `appPath`, `keywords`, `status`) and ignore unknown keys. A file with no front matter returns `data: {}`.
  - `interface HelpArticle { slug: string; lang: 'ar'|'en'; capabilities: { id: string; version: number }[]; appPath?: string }`; `toHelpArticle(slug: string, lang: 'ar'|'en', raw: string): HelpArticle` reading the `capabilities:` list of `id@version` strings.
  - `checkHelp(entries: Capability[], articles: HelpArticle[], cfg: Pick<GuardConfig,'helpExemptAreas'>): Violation[]`. A live entry "needs help" when its roles include something other than `super_admin`/`operator` and its area is not in `helpExemptAreas`. Rules: `help-missing` (needs help, `helpArticle` null; key = id), `help-article-absent` (slug has no article in either language), `help-twin-missing` (present in one language only; key = `<slug>`), `help-unlinked` (article exists but its `capabilities` does not list the entry id; key = `<id>`), `help-stale` (listed version differs from `entry.version`; key = id; deterministic, no clock), `help-orphan` (article lists an id with no entry; key = `<slug> <id>`).

- [ ] **Step 1: Failing tests:** front-matter parse of a real Store article header (copy the first 8 lines of `apps/help/content/ar/3d-models.mdx` into the test) returns `appPath: '/stores'`; `capabilities:\n  - a.b@2\n  - c.d@1` parses to two ids; an `ar`-only article yields `help-twin-missing` (review focus 3); entry `version: 2` with article `a.b@1` yields `help-stale`; an entry in an exempt area yields no `help-missing`; a super-admin-only live entry yields none.
- [ ] **Step 2: Run** `npx vitest run packages/foundation/src/help-article.test.ts`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the test. Expected: PASS.
- [ ] **Step 5: Commit** `feat(capability): help article linkage, twin and freshness guard`.

### Task 8: Seed generator

**Files:**
- Create: `lib/capability-seed.mjs`, `test/capability-seed.test.ts`, `test/fixtures/capability/store-mini.json`, `test/fixtures/capability/chat-mini.json` (six entries each, copied and trimmed from the real catalogues so each normaliser branch appears)

**Interfaces:**
- Consumes: Task 1 (`capabilitySchema`).
- Produces: `seed({ catalogue: string; product: 'store'|'chat'; out: string; today: string }): { written: string[]; skipped: string[]; report: SeedReport }` where `SeedReport = { unclassifiedUndo: string[]; unparsedRoles: string[]; invalidOperatorReasons: string[]; counts: { total: number; needsHelp: number } }`. Mapping decisions:
  - Store `title_en/title_ar` and Chat likewise -> `titleEn/titleAr`; Store `page` split on `;` and Chat `screen` text -> `screens` (Chat additionally gets `view:<name>` for each web `View` name found in the text); `pr_or_plan`/`pr`/`plan` -> `pr` or `plan` (a `ebda-store#NNN` style value becomes `pr`, a path becomes `plan`); `mcp_tool` -> `mcpTool`; `merchant_questions_*` -> `questions`; `steps` string -> one-item array (Chat already arrays); `help_article` -> `helpArticle` slug (`help/account-security` -> `account-security`; `docs/help/{ar,en}/04-templates-and-the-24-hour-window.md` -> `whatsapp/templates-and-the-24-hour-window`; anything else, such as `docs/connectors.md`, -> `null` with `helpGap` = the original text); `version: 1`, `versionDate: today`.
  - `roles`: Store free text and Chat arrays -> `Role[]` by keyword (`owner`, `staff`, `store_admin` -> owner, `super_admin`, `operator`, `public`, `customer`); an unparseable string is listed in `unparsedRoles` and becomes `['owner']` plus a `gaps` line "roles unverified".
  - `undo`: `n/a` or Chat `false` on a GET-only entry -> `none`; text starting `no`/containing `irreversible` -> `irreversible`; `yes` with `inverse|opposite|reversing|adjust|re-?create` -> `compensating`; plain `yes`/`true` -> `reversible`; anything else -> `unclassified` (listed in the report); the original text is kept as `undo.note`.
  - `operatorReason` from `super_admin_reason`/`operator_reason` plus the validity flag: reason text mapped to a code by keyword (`abuse|legal|money|platform|critical|incident`); no match -> `code: null` (counts as unreasoned until a human sets it); `validUnderRule` true when the catalogue says VALID/valid.
  - An existing `<id>.capability.json` in `out` is never read for merging and never overwritten: its id goes in `skipped` (review focus 5).

- [ ] **Step 1: Failing tests:** each mapping bullet above as one `it` against the fixtures (slug mapping for both help formats, `;` split, `pr` vs `plan`, role keywords, the five undo branches, reason keyword mapping, invalid reason flag); every written file passes `capabilitySchema`; `it('a second run skips every id and leaves file bytes identical')`; `it('catalogue counts: store 71 and chat 23 need help')` using the real catalogues when env `EBDA_CATALOGUE_DIR` is set (otherwise `it.skip`), asserting `report.counts.needsHelp` equals 71 for Store and 23 for Chat (Chat's 28 live-without-article merchant-facing entries minus the 5 in area `system`, which `helpExemptAreas` excludes).
- [ ] **Step 2: Run** `npx vitest run test/capability-seed.test.ts`. Expected: FAIL.
- [ ] **Step 3: Implement `seed` in `lib/capability-seed.mjs`** (plain Node, no dependencies except importing the schema through a `tsx`-free path: compile-free validation is done in the test, not the module). Write files with 2-space JSON and a trailing newline, keys in schema order so diffs stay reviewable.
- [ ] **Step 4: Run** the test, then once for real with `EBDA_CATALOGUE_DIR=~/Desktop/projects/Ebda-AI-Studio/business/ebda/audits` to confirm the counts. Expected: PASS.
- [ ] **Step 5: Commit** `feat(capability): seed generator from the 2026-11-14 catalogues`.

### Task 9: Backfill planner and article scaffold

**Files:**
- Create: `lib/capability-backfill.mjs`, `test/capability-backfill.test.ts`

**Interfaces:**
- Consumes: registry JSON on disk, Task 7 rules.
- Produces: `backfillPlan(dir: string, cfg: GuardConfig): { batches: { name: string; ids: string[] }[] }` (needs-help live entries without an article or with a stale one, grouped by area and ordered area then id; the batch table in Tasks 19-30 is its output for the 2026-11-14 catalogues); `scaffoldArticle(entry: Capability, lang: 'ar'|'en'): string` returning an MDX skeleton: front matter (`title` from `titleAr`/`titleEn`, `description` empty, `section`, `order`, `appPath` from the first `screens` entry that starts with `/`, `capabilities: [id@version]`), then `##` headings for steps, a question list from `questions[lang]`, and an edge-case list. The scaffold is a starting point; a human or agent still writes the real text.

- [ ] **Step 1: Failing tests:** a three-entry fixture dir produces batches grouped by area; an entry with an article and matching version is absent; a stale entry is present; `scaffoldArticle` output parses with `parseHelpFrontMatter` and carries `capabilities` as `id@version`.
- [ ] **Step 2: Run** `npx vitest run test/capability-backfill.test.ts`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the test. Expected: PASS.
- [ ] **Step 5: Commit** `feat(capability): help backfill planner and article scaffold`.

### Task 10: CLI, exports, docs, release

**Files:**
- Modify: `bin/ebda-foundation.mjs` (subcommand `capabilities seed|backfill-plan|scaffold`), `packages/foundation/package.json` (exports `./capability`, `./capability-registry`, `./ratchet`, `./capability-coverage`, `./self-service-routes`, `./smart-layer-bypass`, `./help-article`; version `0.2.0`), `CHANGELOG.md`, `test/cli.test.ts`
- Create: `docs/standard/capability-registry.md`

**Interfaces:**
- Consumes: Tasks 1-9. Produces the vendored module set consumers import as `.../foundation/<module>`.

- [ ] **Step 1: Failing tests in `test/cli.test.ts`:** `sync` into a temp target writes `capability.ts` and the other six modules and lists them in the lock; `check` passes after sync; `ebda-foundation capabilities seed --product store --catalogue <fixture> --out <tmp>` writes files and exits 0 and prints the report counts.
- [ ] **Step 2: Run** `npx vitest run test/cli.test.ts`. Expected: FAIL.
- [ ] **Step 3: Implement** the subcommand wiring and exports; `docs/standard/capability-registry.md` follows `docs/standard/slugs.md` (Rule, Why, Registry file, Guards and baselines, Adopting in a product, Gate) and states: one file per capability in `capabilities/`, the five guards, baselines shrink-only, the `id@version` article link, seed once. `CHANGELOG.md` gets a `v0.2.0` section. Update `README.md`'s module list by one line.
- [ ] **Step 4: Run** `npm run typecheck && npm test && npm run lint:workflows && bash os/tests/no-force-strings.test.sh`. Expected: all pass.
- [ ] **Step 5: Commit** `feat(capability): cli subcommand, exports, standard doc, v0.2.0`; open the foundation PR (title `feat: capability registry, charter guards and help pipeline tooling`), merge only through `ops/merge-gate.sh`, then tag `v0.2.0` per the existing release practice. Blast-radius sweep (grep `./capability`, `v0.1.0`, `foundationCommit`, the exports keys) across `lib/`, `parity/`, `create/skeleton/`, `os/ops/ebda-foundation-bump.sh`; state the result in the PR.

---

### Task 11: Store - sync, seed, guard config (repo: ebda-store)

**Files:**
- Modify: `packages/shared/src/foundation/**` and `foundation.lock.json` (by `ebda-foundation sync --target . --dir packages/shared/src/foundation --parity tests/unit/foundation-parity.test.ts`)
- Create: `capabilities/*.capability.json` (185), `capabilities/guard.config.json`, `capabilities/baselines/{registry,coverage,superadmin,bypass,help}.json`

**Interfaces:**
- Consumes: foundation v0.2.0. Produces: the Store registry and config the later Store tasks read.

- [ ] **Step 1: Sync** the vendored foundation and run `npx vitest run tests/unit/foundation-parity.test.ts`. Expected: PASS.
- [ ] **Step 2: Seed:** `node <foundation>/bin/ebda-foundation.mjs capabilities seed --product store --catalogue ~/Desktop/projects/Ebda-AI-Studio/business/ebda/audits/2026-11-14-store-capability-catalogue.json --out capabilities --today 2026-11-14`. Expected: 185 written, report printed.
- [ ] **Step 3: Write `capabilities/guard.config.json`:** `product: 'store'`; `routeKinds` mapping mount prefixes `^/(public|internal|realtime)(/|$)` and `webhook` paths to `public`/`internal`; `mustConfirm` for money routes (payments, refunds, payouts, billing charge, wallet, store credit adjust), customer messaging (campaign send, email send, broadcast) and every `DELETE`; `helpExemptAreas: ['platform']`; `smartLayerPaths: []`.
- [ ] **Step 4: Human review of the seed report,** the only manual step: set `undo.class` for each `unclassified` id, set `operatorReason.code` where the catalogue text gave none, fix `roles` flagged "unverified" against `apps/api/src/middleware/rbac.ts`. Commit the reviewed files; the remaining `unclassified` ids become the `registry` baseline (shrink-only debt).
- [ ] **Step 5: Commit** `feat(capabilities): sync foundation v0.2.0 and seed the store registry`.

### Task 12: Store - code-facts adapter

**Files:**
- Create: `tests/helpers/capability-facts.ts`, `tests/unit/capability-facts.test.ts`

**Interfaces:**
- Consumes: `CodeFacts`, `GuardConfig`. Produces: `storeCodeFacts(cfg: GuardConfig): Promise<CodeFacts>`.
  - `pages`: glob `apps/admin/src/app/**/page.tsx` -> route paths (drop `(group)` segments, keep `[id]`).
  - `routes`: the real router table, walked like `tests/unit/public-mount-admin-route-guard.test.ts` (mount prefix recovered from the layer regexp; `vi.mock('@api/middleware/auth')` wrapping `authorize` to tag the roles it was built for). A route is `super_admin` when its tagged roles are exactly `['super_admin']`, otherwise the kind comes from `cfg.routeKinds`, default `merchant`; HEAD and OPTIONS are dropped; `router.all` expands to one entry per verb in use (GET POST PUT PATCH DELETE).
  - `mcpTools`: names passed to `registerMerchantWriteTool` plus read-tool registrations in `apps/api/src/mcp`; `planGates`: `FEATURE_KEYS_ARRAY`.
  Do not refactor the existing guard test; copy its walker into the helper.

- [ ] **Step 1: Failing test:** the facts contain `/stores/[id]` and at least 150 pages, route `GET /stores/:storeId/orders` (or its real path) with kind `merchant`, a route tagged `super_admin` from `platform-tax.routes.ts`, no HEAD/OPTIONS verbs, and two merchant MCP tool names read from `apps/api/src/mcp/tools` (pick them when writing the test).
- [ ] **Step 2: Run** `npx vitest run tests/unit/capability-facts.test.ts`. Expected: FAIL.
- [ ] **Step 3: Implement** the helper.
- [ ] **Step 4: Run** the test. Expected: PASS.
- [ ] **Step 5: Commit** `test(capabilities): derive code facts from the real route table`.

### Task 13: Store - guard tests, baselines, CI

**Files:**
- Create: `tests/unit/capability-registry.test.ts`, `tests/unit/capability-coverage.test.ts`, `tests/unit/self-service-routes-guard.test.ts`, `tests/unit/smart-layer-bypass-guard.test.ts`, `tests/helpers/capability-guard.ts` (loads `capabilities/*.capability.json` and a baseline, runs `applyBaseline`, prints `guardOutcome` warnings as `::warning::`, asserts no failures)
- Modify: `.github/workflows/pr-quality.yml` (copy the foundation job `capability-ratchet`; `jobs:` stays identical to foundation's), `.github/pr-quality/` (add `capability-ratchet.mjs`), `capabilities/baselines/*.json`

**Interfaces:**
- Consumes: Tasks 2-6, 11, 12. Each test calls its foundation check, then `applyBaseline` with its own baseline, and fails on `fresh` or `stale`.

- [ ] **Step 1: Write the four tests** (bypass walks `apps` and `packages` plus every `wrangler.jsonc`; self-service uses the facts from Task 12). Generate each baseline with a small script printing `violationId` for current violations; save them. Add `it('the five baselines contain only ids that currently violate')` (this is the stale check) and `it('a deliberately unregistered fake page fails coverage')` using a fact list plus one invented page (the mutation proof that the guard can fail).
- [ ] **Step 2: Run** `npx vitest run tests/unit/capability-registry.test.ts tests/unit/capability-coverage.test.ts tests/unit/self-service-routes-guard.test.ts tests/unit/smart-layer-bypass-guard.test.ts`. Expected: PASS with the baseline warnings listed; record the baseline sizes in the PR body.
- [ ] **Step 3: Mutation-check once by hand:** temporarily delete one registry file and confirm coverage fails naming that route; restore it. State the result in the PR (VERIFIED or NOT VERIFIED).
- [ ] **Step 4: Wire CI:** the tests live under `tests/unit` so `ci.yml` already runs them; add the pr-quality job. Run `bash scripts/check-action-pins.sh`.
- [ ] **Step 5: Commit** `test(capabilities): registry, coverage, self-service and bypass guards with baselines`.

### Task 14: Store - help linkage, manifest, freshness (repo: ebda-store)

**Files:**
- Modify: `apps/help/scripts/build.mjs` (emit `out/help-manifest.json`), existing articles in `apps/help/content/{ar,en}/*.mdx` that already map to a capability (add `capabilities:` front matter)
- Create: `tests/helpers/help-articles.ts`, `tests/unit/capability-help-guard.test.ts`

**Interfaces:**
- Consumes: `toHelpArticle`, `checkHelp`. Produces: `help-manifest.json` = `{ generatedAt, articles: [{ slug, lang, capabilities: string[], appPath, contentHash }] }`, deployed at `https://help.ebda.app/help-manifest.json` (Task 18 and the publication-lag check read it).

- [ ] **Step 1: Failing test** `capability-help-guard.test.ts`: loads articles from `apps/help/content/{ar,en}/**` (slug = path without extension, so `whatsapp/<name>`), runs `checkHelp`, applies `capabilities/baselines/help.json` (the 71 needs-help ids as `help-missing|<id>`), fails on fresh or stale; plus `it('the built manifest lists every article in both languages')` after a build.
- [ ] **Step 2: Run** `npx vitest run tests/unit/capability-help-guard.test.ts`. Expected: FAIL (no linkage yet, no baseline).
- [ ] **Step 3: Add `capabilities:` front matter** to the 30 existing Store articles from the seed's `helpArticle` mapping (a one-off script, reviewed by hand: an article may cover several capabilities); implement the manifest in `build.mjs`; generate `help.json` baseline.
- [ ] **Step 4: Run** the test, then `npm run build -w apps/help && npm run check -w apps/help` (build, a11y, search). Expected: PASS; unknown front-matter keys do not break the build (this is the thing to prove first).
- [ ] **Step 5: Commit** `feat(help): capability links in article front matter and a published manifest`.

### Task 15: Chat - sync, seed, guard config (repo: ebda-whatsapp)

**Files:**
- Modify: `foundation/**`, `foundation.lock.json` (by sync, dir `foundation`, parity `test/foundation-parity.test.ts`)
- Create: `capabilities/*.capability.json` (172), `capabilities/guard.config.json`, `capabilities/baselines/*.json`

**Interfaces:** same as Task 11 for Chat.

- [ ] **Step 1: Sync** and run `npx vitest run test/foundation-parity.test.ts`. Expected: PASS.
- [ ] **Step 2: Seed** with `--product chat --catalogue .../2026-11-14-chat-capability-catalogue.json`. Expected: 172 written.
- [ ] **Step 3: Write `guard.config.json`:** `routeKinds`: `^/operator(/|$)` -> `operator`, `^/(webhooks|track|health)` -> `public`/`internal`, everything under `/stores/:storeId` -> `merchant`; `mustConfirm`: wallet, packages, instapay, refunds, campaign send/resume, template submit, `POST` on messages, every `DELETE`; `helpExemptAreas: ['system']`; `smartLayerPaths: []`.
- [ ] **Step 4: Review the seed report by hand** as in Task 11 step 4 (the 21 operator entries carry reasons already; the 4 `gap` ones stay `validUnderRule: false`).
- [ ] **Step 5: Commit** `feat(capabilities): sync foundation v0.2.0 and seed the chat registry`.

### Task 16: Chat - facts adapter and guard tests

**Files:**
- Create: `test/helpers/capability-facts.ts`, `test/capability-routes.test.ts` (workers project: route coverage and self-service, registry via `import.meta.glob('../capabilities/*.capability.json', { eager: true })`, no fs), `test/capability-registry.test.ts` (node project, uses fs: registry rules, help, Smart Layer bypass over `src` and `web/src` and `wrangler.jsonc`)
- Modify: `vitest.config.mts` (add `test/capability-registry.test.ts` to the workers project `exclude` list and to the node project `include`, the same way `test/guards.test.ts` is handled), `.github/workflows/ci.yml` or `pr-quality.yml` (ratchet job as in Task 13), `capabilities/baselines/*.json`

**Interfaces:**
- Consumes: Tasks 2-7, 15. Produces: `chatCodeFacts(cfg: GuardConfig, registryRoutesFrom: typeof apiRoutes)`: `routes` from the Hono table (`apiRoutes.routes`: method + path, `/api/v1` prefix removed; kind from `cfg.routeKinds`; `ALL` expands as in Task 12), `pages` from the members of `export type View = ...` in `web/src/components/Rail.tsx`, extracted by a regex over source as `view:<name>`.

- [ ] **Step 1: Failing tests:** the facts hold `view:inbox` and `view:operator`; an `/operator/...` route has kind `operator`; the coverage test fails before the baselines exist.
- [ ] **Step 2: Run** `npx vitest run test/capability-routes.test.ts` and `npx vitest run test/capability-registry.test.ts`. Expected: FAIL.
- [ ] **Step 3: Implement** helper and tests; generate baselines; keep the existing `test/integrator-tokens.test.ts` and `test/route-decisions.test.ts` untouched (they own scopes; this guard owns capabilities).
- [ ] **Step 4: Run** both files plus `npm run typecheck`. Expected: PASS. Run the same one-file mutation check as Task 13 step 3 and report it.
- [ ] **Step 5: Commit** `test(capabilities): chat registry, coverage, self-service and bypass guards`.

### Task 17: Chat - guide front matter, guide 15, publication-lag check

**Files:**
- Modify: `docs/help/{ar,en}/01..15-*.md` (add front matter: `capabilities: [id@version]`, `appPath`), `docs/help/README.md` (document the keys), `.github/workflows/nightly.yml` (job `help-publication-lag`)
- Create: `scripts/help-publication-lag.mjs`, `test/help-publication-lag.test.ts`

**Interfaces:**
- Consumes: `https://help.ebda.app/help-manifest.json` (Task 14), `toHelpArticle`. Produces: exit 1 plus an alert line when a `docs/help` source's `contentHash` differs from the published article of the same slug for more than 48 hours (the hash of the converted body, as `import-wa-help.mjs` emits it, computed by the same function exported from the Store script; copy its algorithm and pin it with a test vector).

- [ ] **Step 1: Failing test** `help-publication-lag.test.ts` with an injected manifest: same hash -> ok; differing hash within 48 hours -> ok with a warning; differing beyond 48 hours -> failure naming the slug; manifest unreachable after 3 retries -> failure (never fail open).
- [ ] **Step 2: Run** `npx vitest run test/help-publication-lag.test.ts`. Expected: FAIL.
- [ ] **Step 3: Implement the script and nightly job; add front matter** to all 15 guides in both languages. Chat's guard (Task 16) checks the SOURCE at PR time (`docs/help/{ar,en}/<NN>-<slug>.md` exists in both, links the entry); the Store import (Task 18) is what publishes it, and this nightly job is the proof it happened.
- [ ] **Step 4: Run** the test and `npx vitest run test/capability-registry.test.ts`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(help): capability links in chat guides and a publication-lag check`.

### Task 18: Store - import Chat guides with front matter, add guide 15 (repo: ebda-store)

**Files:**
- Modify: `apps/help/scripts/import-wa-help.mjs` (`convert` parses and re-emits the source front matter: `capabilities`, `appPath`; H1 detection must skip the front-matter block), `tests/unit/support-wa-help-drift.test.ts` (re-pin all 30 hashes), `apps/help/wa-source/**`, `apps/help/content/{ar,en}/whatsapp/*.mdx`
- Create: `apps/help/content/{ar,en}/whatsapp/your-products-on-whatsapp.mdx` (by the import), `tests/unit/import-wa-help.test.ts`

**Interfaces:**
- Consumes: Task 17's sources. The Chat section already exists on help.ebda.app (14 guides imported; commit `8a778fcf0`); this task adds guide 15 and the capability links, it does not create the section.

- [ ] **Step 1: Failing test** `import-wa-help.test.ts`: `convert` of a source with front matter `capabilities: [a.b@1]` and `appPath: /x` yields MDX whose front matter carries both plus the existing `title`, `description`, `section`, `order`; the H1 inside the body still gives the title; a source without front matter converts exactly as today (byte-compare against a stored fixture so no existing page changes).
- [ ] **Step 2: Run** `npx vitest run tests/unit/import-wa-help.test.ts`. Expected: FAIL.
- [ ] **Step 3: Implement the converter change, run the import** against the Chat checkout's `docs/help`, update the pins, run the Task 14 help guard (it now sees Chat articles under `whatsapp/`).
- [ ] **Step 4: Run** `npx vitest run tests/unit/import-wa-help.test.ts tests/unit/support-wa-help-drift.test.ts tests/unit/capability-help-guard.test.ts` and `npm run check -w apps/help`. Expected: PASS; the built site lists 15 Chat guides in both languages.
- [ ] **Step 5: Commit** `feat(help): import chat guides with capability links and publish guide 15`.

---

## Help backfill (Tasks 19-30)

The guards stay in ratchet mode until Task 31. New capabilities are already blocked; these tasks pay down the baseline. Counts come from `ebda-foundation capabilities backfill-plan` (Store 71, Chat 23 plus 5 stale guides); a count that differs at execution time means the registry changed, so re-run the planner and adjust the batch, do not drop ids.

**Backfill batch procedure (every batch task follows it):**
1. In a fresh worktree of the product, list the batch ids: `capabilities backfill-plan` output for the named areas.
2. For each id: `capabilities scaffold <id> --lang ar` and `--lang en`; write the article from the entry's `steps`, `questions` and `edgeCases` only after reading the live screen: open the real page in the running product (Chrome, console and network capture armed first), walk the steps, and fix any step the screen does not match. Egyptian Arabic in full sentences; English second; no invented behaviour, anything not built is marked as such.
3. Set the entry's `helpArticle` slug, keep `version` unless the walk found the entry itself wrong (then bump `version` and the article's `id@version` together), and merge several capabilities into one article only when they are one task for the merchant (list every id in `capabilities:`).
4. Run: `npm run build -w apps/help && npm run check -w apps/help` (Store) and the product's help guard test; remove the batch's ids from `capabilities/baselines/help.json` (the guard fails if one stays after it is fixed).
5. One PR per batch, body lists ids, the screens walked, and what could not be verified; commit `docs(help): <batch name> articles`.

| Task | Repo | Batch | Ids |
|---|---|---|---|
| 19 | store | S1 marketing | 12 |
| 20 | store | S2 store, storefront, seo | 12 |
| 21 | store | S3 inventory, products, commerce, shipping | 11 |
| 22 | store | S4 account, onboarding, billing, team, notifications | 11 |
| 23 | store | S5 content, builder, customers, b2b | 11 |
| 24 | store | S6 finance, payments, analytics | 8 |
| 25 | store | S7 orders, returns, integrations | 6 |
| 26 | chat | C1 inbox | 11 |
| 27 | chat | C2 access, otp, notifications | 7 |
| 28 | chat | C3 contacts, campaigns, templates, numbers, compliance | 5 |
| 29 | chat | C4 stale guides: fix 04, 05, 06, 07 and 11, 09 | 5 guides |
| 30 | store | S8 Chat section check: every Chat guide lists its capabilities and is live | n/a |

Each of Tasks 19-28 has: **Files:** `apps/help/content/{ar,en}/<slug>.mdx` (Chat batches: `docs/help/{ar,en}/NN-<slug>.md` in ebda-whatsapp, then Task 18's import in Store), `capabilities/<id>.capability.json`, `capabilities/baselines/help.json`; **Interfaces:** consumes Task 9 scaffold and Task 14/17 guard; **Steps:** the procedure above. Test = the product's help guard test failing before the batch (ids in `help-missing`) and passing after with a smaller baseline.

Task 29 specifics: the five stale guides are marked by setting their capability entries to `version: 2` before writing (the guard then reports `help-stale` for them), rewriting each guide against the current UI (the guide 04 templates screen does not exist until sub-plan 3 builds it, so 04 must say so honestly and keep the API route facts), then setting the article's `id@2`. Task 30 is a read-only reconciliation in Store: run the help guard and manifest check and confirm all 15 Chat slugs show `capabilities` lists; no content changes unless a gap is found.

### Task 31: Flip the guards to blocking

**Files:**
- Modify: `capabilities/baselines/help.json` in both products (to `[]`), `docs/standard/capability-registry.md` in foundation (status "all products blocking"), `os/standard/ai-native-self-service.md` "How to check" (one line pointing at the guard tests)
- Test: `tests/unit/capability-help-guard.test.ts` (Store), `test/capability-registry.test.ts` (Chat)

**Interfaces:** consumes all of the above.

- [ ] **Step 1: Failing test:** in each product add `it('help baseline is empty: every live capability has a fresh published article')` asserting `capabilities/baselines/help.json` equals `[]`.
- [ ] **Step 2: Run** it. Expected: FAIL if any id remains (then finish that batch, never edit the test).
- [ ] **Step 3: Empty the baseline;** run the full guard set in both products. Expected: PASS with zero `help-*` warnings.
- [ ] **Step 4: Verify against production** (rule F): `curl -s https://help.ebda.app/help-manifest.json` lists every live capability's slug in both languages; list what could not be checked (for example an article whose page needs a login to compare with the screen).
- [ ] **Step 5: Commit** `feat(capabilities): help guard blocks for every live capability`; update the program register row for lens 192 enforcement.

## Self-review

**Spec coverage.** 6.8 registry fields (Task 1: id, area, titles, screens, api, plan gate, roles, policy, undo, help, questions, edge cases, status; `version` added for 6.9 freshness), 6.8 planned counts and lifecycle (Task 2), CI guard for pages/routes/actions (Tasks 4, 12, 16), 6.8b help rule and one help site (Tasks 7, 14, 17, 18), backfill 71 + 23 + 5 stale (Tasks 19-30), warn-to-blocking (Task 31), 10b.7 self-service guard with baseline (Task 5), 192.6 bypass guard with baseline (Task 6), 6.9 undo classes (Tasks 1, 2, 8) and help freshness (Task 7), 6.8 first registry from the catalogues (Tasks 8, 11, 15). Deliberately later: `inverse` handler names, the golden eval hook, the weekly report, the lens probe (see Scope).

**Spec-silent decisions taken here (Ahmad may override):**
1. Registry is one JSON file per capability in `capabilities/` (the catalogue's own proposal; avoids the shared-list conflict magnet), camelCase fields, catalogue ids unchanged.
2. Guards are pure functions in `@ebda/foundation` (Zod, vendored by sync); each product supplies a facts adapter and thin tests; file and glob loading stays in products (Chat's workers project cannot read files).
3. Every guard is a ratchet with a shrink-only baseline: new offenders fail from day one, existing ones warn; "blocking for all" means the baseline reaches empty (stricter than the spec's warn-then-block, never weaker).
4. The super-admin "annotation" is the registry entry bound to the route (reason code + text), not a source marker; super-admin routes are recognised by Store's existing `authorize('super_admin')` and Chat's `/operator` prefix. Standard 192.2 says "annotated at the route"; its wording should read "at the route or in its registry entry" (follow-up edit in the spec PR).
5. Freshness is deterministic version equality (`id@version` in the article's front matter against the entry's `version`), not a time threshold, because a time rule would fail unrelated PRs.
6. "Published" is checked at PR time as source existence in both languages; Chat guides reach help.ebda.app through the existing import, proven by a nightly publication-lag check against the deployed `help-manifest.json` (a PR-time live fetch would be flaky and circular).
7. The Chat section on help.ebda.app already exists (14 guides imported); this plan adds capability links, guide 15 and the manifest instead of building a new section.
8. Chat's "23" is 28 live merchant-facing entries without an article minus 5 in area `system` (exempt by config).
9. Undo text in the catalogues is free-form; the seed classifies by keyword and marks the rest `unclassified`, which is baselined debt.

**Step scan and types.** Names used across tasks match their defining Interfaces block: `Violation`, `CodeFacts`, `GuardConfig`, `applyBaseline`, `guardOutcome`, `checkRegistry`, `checkCoverage`, `checkSelfServiceRoutes`, `checkModelBypass`, `checkHelp`, `toHelpArticle`, `seed`, `backfillPlan`, `scaffoldArticle`, `storeCodeFacts`, `chatCodeFacts`. Guard names for baselines (`registry`, `coverage`, `superadmin`, `bypass`, `help`) are used identically in Tasks 11, 13, 15, 16, 31.

**Review Focus coverage.** Item 1 Task 4, 2 Task 4, 3 Task 7, 4 Tasks 3 and 5, 5 Task 8.

**Proportion.** Spec about 32 KB; this plan is smaller; code appears only as signatures, rule lists and assertions.
