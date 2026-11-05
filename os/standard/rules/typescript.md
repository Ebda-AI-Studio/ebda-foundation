# typescript — Language Rule Pack

tags: [BOTH]
scope: any `.ts`/`.tsx` file, any project on the TS toolchain (Next.js apps, Express APIs, shared packages)
sources: CLAUDE.md (code-quality rules 1–2), `security.md` (criteria 3, 11, 11a), `deps.md`, MEMORY.md feedback-fwb-apiget-double-unwrap, feedback-withrlsbypass-callback-signature, feedback-npm-override-major-pin-trap, feedback-npm-overrides-tilde-constraint-trap, feedback-pnpm-react18-19-types-coexistence, feedback-jsonparse-any-poisoning

## Must Always
- Validate every API-edge input with Zod (or Yup) BEFORE it touches business logic — `.parse()`/`.safeParse()` on body/query/params, never a bare `as`-cast on `req.body`. When a shared union/enum widens, widen the Zod schema in the **same commit** — TS is compile-time only, the validator is the real runtime gate.
- Write exhaustive `switch`/`if` chains over any enum/union with a `default: assertNever(x)` (or equivalent) so adding a new enum value is a **compile error** everywhere it's unhandled, not a silent fallthrough.
- When a shared helper module gets a new export that request-path code depends on (a tx wrapper, a bypass helper), grep every `vi.mock('<module>')`/`jest.mock('<module>')` factory in the SAME commit and add the export there too — typecheck passes on an `any`-shaped mock even when the real symbol is missing; only the test run catches it (see `feedback-tx-wrapper-breaks-prisma-mocks` in `prisma-postgres.md`).
- Trace a callback-shaped helper (`withRlsBypass(fn: (tx) => Promise<T>)`) to its actual signature before calling it. Passing a bare Prisma promise instead of a callback type-checks as `unknown` and cascades TS18046 downstream — the type error you see is often several call-sites removed from the actual mistake.
- Confirm what an API wrapper actually returns before typing the caller. If `apiGet<T>` already unwraps `{ success, data }`, the caller's payload **is** `T` — re-typing as `apiGet<{ data: T }>` and reading `.data` again silently resolves to `undefined` forever (a real a previous storefront product P0: the whole page rendered its "failed to load" state on every successful 200, because the double-unwrap swallowed the real payload).
- Any npm `overrides` entry pinning a CVE fix must be **major-pinned** (`^7.28.0`), never a bare `>=7.28.0` — a bare floor resolves to the newest major and breaks peers still pinned to the old one.
- In a pnpm monorepo mixing React majors (Expo/RN 18 + Next 19), pin `@types/react` per-workspace via `.npmrc` `hoist-pattern[]=!@types/react` + `packageExtensions` — never a single global override; that forces one React major's types onto every workspace and breaks the other.
- Give any cache-wrapped function (`return JSON.parse(cached)` before the real query) an **explicit return type** annotation — an untyped early `JSON.parse` return infers the whole function's return as `any`, and every caller compiles against fiction until the cache is later removed or typed (`feedback-jsonparse-any-poisoning`).

## Must Never
- Never leave `any` at a function boundary that receives request input, DB rows, or a third-party SDK response. Push the `any` to the single narrowest conversion point (a `parse()`/mapper) and type everything downstream.
- Never trust `npm audit fix --force`'s suggested "fix" if it downgrades a framework major (Next/React/Express) — override the vulnerable transitive leaf instead (nested-override form in a monorepo).
- Never assume a range override (`>=X`) lifts an already-locked transitive dependency — npm treats a range as a constraint to satisfy with whatever's already resolved, not a forcing function. Use an **exact** pin (`"tmp": "0.2.7"`) when a range silently doesn't move the lockfile.
- Never spread an object and then set a key that also exists on the spread source without ordering it last (`{ id: m.id, ...m.user, createdAt: m.createdAt }` — spread first, override last) — TS2783 duplicate-key errors are a sign the intended override is in the wrong position, and getting the order backward silently keeps the spread's stale value.

## Patterns
- **Narrow-cast at the edge, not the core.** One `schema.parse(input)` call per route handler produces a fully-typed object for everything downstream — resist re-validating or re-casting deeper in the call stack.
- **Wrapper-return audit before typing a caller.** Before writing `useT<Wrapper<T>>`, open the wrapper's source and read what it actually returns. Grep `apiGet<{ data:` (or similar double-wrap shape) across a codebase periodically — every hit is a candidate double-unwrap bug.
- **Mock-factory parity check.** `grep -rn "vi.mock('@pkg/db'" | ` then diff the mock's exported keys against the real module's exports whenever the real module changes.

## Traps
- A callback-typed helper called with a value instead of a function type-checks as `unknown`, not as an error at the call site — the resulting cascade of `unknown`-typed errors downstream is the actual signal; fix the root call, not each cascade site.
- Silent double-unwrap: any `payload?.data` / `data.data` read where the wrapper's JSDoc or source says it already unwraps — grep for the pattern, don't assume the obvious shape.
- A monorepo's `pnpm.packageExtensions`/`pnpm.overrides`/`pnpm.auditConfig` config can silently live in **either** `pnpm-workspace.yaml` (pnpm 10+) or `package.json`'s `pnpm` field (pnpm 9.x) depending on the installed pnpm version — dual-write both locations until every CI runner + local dev is confirmed on pnpm 10.
- Deleting a cache/parse layer from a function that had no explicit return type surfaces type errors in untouched callers — that's the `any` poison draining, not the diff being wrong; fix the type at the source, never `as unknown as` at the call site (`feedback-jsonparse-any-poisoning`).

Cross-links: `../rls.md` (RLS-aware TS helpers), `../deps.md` (full 5-point dependency gate), `prisma-postgres.md` (mock-factory drift on tx wrappers), `react-nextjs.md` (React/TS coexistence).
