# react-nextjs — Language/Framework Rule Pack

tags: [BOTH]
scope: any `.tsx`/`.jsx` file, any Next.js App Router route, any React component — admin dashboards, storefronts, PWAs
sources: `frontend-quality.md`, `scaling.md` (criterion 9 edge cache), CLAUDE.md (Arabic UTF-8 edit rule), MEMORY.md feedback-tailwind-tracking-breaks-arabic, feedback-i18n-dataattr-textcontent-flatten-trap, feedback-migrate-before-deploy-and-force-dynamic, feedback-tailwind-v4-css-vars, feedback-tailwind-v4-jit-dynamic-classes, feedback-store-i18n-duplicate-key-block-trap (indexed)

## Must Always
- Declare `export const dynamic = "force-dynamic"` on any page that reads `cookies()`/`headers()` (locale switch, auth-aware rendering) — these pages are inherently per-request. Never pair such a page with a `generateStaticParams` that queries the DB at build time; that couples render-mode to build-time DB reachability, and when the build-time query fails, Next silently compiles the page into a broken mode that 500s at runtime with a masked `DYNAMIC_SERVER_USAGE` digest even though the build reported success.
- Set `dir="rtl"`/`dir="ltr"` at the layout root driven by locale, on BOTH admin and storefront — not just one surface. Any carousel/slider component must keep `dir="ltr"` internally regardless of page direction (RTL carousels invert scroll direction if they inherit `dir="rtl"`).
- Every i18n key must exist in BOTH locale catalogs (en + ar) with the SAME path — diff the key sets (`jq -S 'keys' en.json ar.json`) before shipping any copy change. A key present in one and missing in the other silently falls back to the raw key string in prod.
- Put `data-en`/`data-ar` (or any textContent-swap i18n) attributes ONLY on leaf text nodes, never on a parent element that also has child elements — `el.textContent = ...` replaces ALL child nodes with one text node, silently flattening nested markup (a real incident: a CTA button's subline vanished because the parent button carried translate attrs alongside its own child spans that already translated independently).
- Bump Arabic-locale font-size +1–2px whenever you strip `tracking-*`/`uppercase` for the Arabic branch, so optical weight matches the English small-caps styling it's replacing.
- Pre-compose every responsive/conditional Tailwind class as a literal string in source (a token lookup table with one full literal per branch). Tailwind's JIT scanner only sees literal strings in source files — it cannot follow string concatenation, `.split().join()`, or template-literal composition of class fragments.
- Use `bg-(--name)` (paren shorthand) or `bg-[var(--name)]` for Tailwind v4 arbitrary CSS-variable utilities — `bg-[--name]` compiles to a literal invalid CSS property and silently drops.
- Apply an additive (new table/column) migration to prod BEFORE or WITH the deploy that adds the query using it — never defer the migration to "after merge." A deferred migration means the build compiles against the OLD schema; the build reports success but the route is poisoned and 500s at runtime even after the migration is later applied (requires a fresh redeploy to actually fix).

## Must Never
- Never gate `tracking-[X]`/`tracking-wider`/`uppercase` styling identically across locales on a bilingual surface — positive letter-spacing severs Arabic OpenType glyph-joining (every word renders as disconnected initial forms) even when the font itself supports Arabic shaping fine.
- Never build a class name by concatenating fragments (`'sm:' + cls`) or mapping/joining an array of class names at runtime and expect the CSS to be emitted — it silently won't be, with zero build error and the wrong-looking-but-present class in DevTools.
- Never let a feature's "fix" for a display glitch be `function toggleLanguage(){ return; }` (stub it out) — a stubbed handler still looks wired (click fires) but does nothing, and the bug report becomes "the button doesn't work" when really the function was gutted. Fix the actual mis-marked element instead of disabling the feature.
- Never assume a green Next.js build means every route renders — a route with `generateStaticParams` that failed its DB query at build time can still report "Build Completed" while the runtime route is broken.

## Patterns
- **Locale-conditional class string, one ternary per bilingual label:**
  ```tsx
  className={[
    "mt-3 text-charcoal/70",
    isAr ? "font-body-ar text-[13px]" : "font-body text-[11px] uppercase tracking-[0.22em]",
  ].join(" ")}
  ```
- **Token table for dynamic Tailwind sizing** — every (size × layout) combination written out as a full literal string, never assembled:
  ```ts
  const SIZE_TOKENS = {
    sm: { iconWrapHorizontal: 'h-7 w-7 sm:h-8 sm:w-8' },
    md: { iconWrapHorizontal: 'h-9 w-9 sm:h-12 sm:w-12' },
  } as const;
  ```
- **Round-trip verify any locale toggle**: drive EN→AR→EN and assert `dir` flips, sample text changes both ways, child element COUNT is unchanged (catches the textContent-flatten regression), and the preference persists across reload.

## Traps
- A successful build + a healthy `/health` does not mean every route is reachable — reproduce with a LOCAL production build (`next build && next start`) against the same DB before trusting a Vercel deploy; if local prod succeeds and Vercel 500s, the deployed build ARTIFACT is stale/broken (built against a mismatched schema), not the code.
- `dev` mode never reproduces the force-dynamic / DYNAMIC_SERVER_USAGE class of bug — dev is always dynamic. Only a production build surfaces it.
- Arabic content integrity: grep AR locale/source files for the U+FFFD replacement char or `?`-runs — a bad edit pipeline (especially any `perl`/sed pass without `-CSD`) can silently mojibake Arabic strings.

Cross-links: `../frontend-quality.md` (full i18n/RTL/a11y/CWV/SEO rubric), `../rls.md` (server components reading RLS-policed tables need the tenant GUC), `node-express.md` (the API side of the migrate-before-deploy rule), `typescript.md` (component prop typing).
