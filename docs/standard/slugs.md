# Standard: one slugifier

**Rule.** Every Ebda product derives slugs with `slugify` / `slugifyWithFallback` from `@ebda/foundation/slugs`. No product writes its own regex for a slug. A new need becomes an option on the shared function and a vector in `vectors/slugs.json`.

**Why.** Ebda Store carried nine copies (audit M-106, 2026-11-12): the blog field stripped a trailing hyphen while you typed, so a hyphen could not be entered; an Arabic title gave an empty slug; categories kept Arabic letters and stores did not.

**Options.** `ascii` for anything that becomes a host label or an ASCII URL (store address, blog); default keeps Arabic letters (product and category URLs). `max` cuts and never ends on a hyphen. `keepTrailingHyphen` is for live typing only; clean on submit.

**Persisting callers** use `slugifyWithFallback` (never `''`, which gives an unreachable URL and `-1`, `-2` duplicates). **Validators stay separate**: `slugFormatError` and the server regexes check a slug, they never derive one.

**Gate.** Each product has a guard test that fails when app code defines its own `slugify` or `generateSlug` (store: `tests/unit/slugify.test.ts`).

sources: store ruling SLUG-1.
