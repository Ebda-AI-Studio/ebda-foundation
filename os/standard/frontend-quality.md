# frontend-quality — Frontend Quality Rubric (i18n/RTL · a11y/WCAG · Perf/CWV · SEO)

tags: [BOTH]
sources: PLAYBOOK §14 (audit-fleet lenses: a11y/WCAG, Perf/CWV, i18n/RTL, SEO), PLAYBOOK §16 (definition of production-ready: i18n/RTL parity), reference-iceberg-audit.md (term 38 Documentation; Vibe-vs-Reality grading), CLAUDE.md (Arabic UTF-8 edit rule; scaling rule 3 image optimization)

## What "solid" looks like
Full bilingual AR/EN parity with no missing keys and an RTL-correct admin AND storefront; an accessibility floor (keyboard, contrast, aria, axe-core wired into CI); Core Web Vitals within budget (LCP/CLS/INP) with optimized images and a controlled bundle; and storefront SEO complete (meta, Open Graph, sitemap, structured data, hreflang). Each of the four lenses (i18n/RTL, a11y/WCAG, Perf/CWV, SEO) has a runnable check, not a vibe.

## Criteria
| # | Criterion | Solid (grade 2) | Gap detection | Severity |
|---|---|---|---|---|
| 1 | Bilingual key parity (AR/EN) | Every locale catalog has the same key set; no missing/orphan translation keys | diff the key sets of the two locale files (e.g. `jq -S 'keys' en.json ar.json` / messages dirs) — any key present in one and absent in the other is a gap | High |
| 2 | RTL-correct admin AND storefront | `dir="rtl"`/`dir={locale==='ar'?'rtl':'ltr'}` set at the layout root for BOTH admin and storefront; no hardcoded `ml-`/`mr-`/`left:`/`right:` that break under RTL | grep layout/root files for a `dir=` attribute driven by locale; grep components for physical-side classes (`\bm[lr]-`, `\b(left|right):`) that should be logical (`ms-`/`me-`/`start`/`end`) | High |
| 3 | Arabic content integrity | AR strings are intact UTF-8 (no mojibake from a bad edit pipeline) | grep locale/AR source files for replacement char `\357\277\275` (U+FFFD) or `?`-runs where Arabic is expected; confirm no `perl -CSD` step in any edit/codegen script | Medium |
| 4 | a11y floor wired into CI | axe-core (or equivalent) runs in CI; keyboard + contrast + aria covered | file-exists check for an axe/jest-axe/`@axe-core/playwright` dependency in `package.json` AND a CI workflow step invoking it; grep workflows for `axe` | High |
| 5 | Image alt text + aria on interactive elements | Images carry meaningful `alt`; icon-only buttons carry `aria-label` | grep components for `<img`/`<Image` occurrences lacking an `alt=` attribute; grep for icon-only `<button>`/`role="button"` lacking `aria-label`/`aria-labelledby` | Medium |
| 6 | Core Web Vitals measured against a budget | LCP/CLS/INP measured in CI (Lighthouse/LHCI) with a documented p-target, not assumed | file-exists check for `lighthouserc`/`@lhci/cli` config (or a CWV step) in repo + CI; grep for `lhci`/`lighthouse` in workflows | High |
| 7 | Image optimization | Images served through the framework optimizer (`next/image`) / responsive sources, not raw oversized `<img>` | grep storefront/admin components for raw `<img src=` on content images where `next/image` should be used; confirm large originals aren't shipped un-resized | Medium |
| 8 | Bundle-size control | Bundle size watched (analyzer or a size budget), no unbounded growth | file-exists check for a bundle-analyzer config / size-limit budget; grep `next.config`/build config + CI for an analyze/size step | Medium |
| 9 | SEO meta + Open Graph | Each public/storefront page emits title, description, and OG tags | grep storefront pages/layout for a metadata source (Next `metadata`/`generateMetadata` or `<meta name="description"`/`og:` tags); flag public pages with none | Medium |
| 10 | Sitemap + robots | `sitemap.xml` and `robots.txt` (or their generators) exist for the storefront | file-exists check for `sitemap.{ts,xml,js}` / `robots.{ts,txt}` (Next app-router `app/sitemap.ts` + `app/robots.ts`) | Medium |
| 11 | Structured data + hreflang | Storefront emits JSON-LD structured data and `hreflang` alternates for AR/EN | grep storefront for `application/ld+json` / `jsonLd` and for `hreflang`/`alternates.languages` in metadata | Medium |
| 12 | Page-builder / theme controls verified end-to-end | Every merchant visual control is proven to reach the storefront: admin write-key == storefront read-key, the rendering component actually applies it (not overridden by a hardcoded class), it renders live after save, AND it shows in the unsaved preview. Catches the "saved-but-not-rendered" class with 3 root causes — (a) PAINTED OVER: a component's own opaque class/bg covers the wrapper value (thread the value INTO the component as a prop + inline style); (b) NOT CONSUMED: saved to a settings object no storefront code reads — when one field is dead, sweep EVERY interface that has it and fix all in one pass; (c) NOT IN THE PREVIEW DRAFT BUNDLE: settings on `store.settings` (vs `layout`/`theme`) aren't carried by the preview draft, so they never preview unsaved | for each page-builder card, trace its write-key → the storefront consumer; grep for the key being read; confirm no hardcoded class overrides it; confirm the preview-draft bundle carries the setting's storage location | High |

## Evidence (filled during audit, per repo)
- a previous storefront product: …
- an earlier messaging product: …
