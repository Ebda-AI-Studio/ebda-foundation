# aeo-integrity — an answer engine gets what you actually served, not what you intended

tags: [BOTH]
sources: live measurement, a live merchant storefront,
2026-09-19/22 — not a reel claim; `frontend-quality.md` crit 9/11 grade tag *presence*, this
doc grades locale/entity *correctness*

## What "solid" looks like

`frontend-quality.md` already grades whether a storefront emits meta tags, Open Graph, JSON-LD,
and `hreflang` at all. This lens grades what those earlier checks cannot see: whether the
content behind those tags is **correct for the locale it claims to be**, whether the brand
resolves to **one entity** everywhere it can be found, whether **every** page (not a sampled
few) carries a canonical, whether AI-crawler access is a **deliberate** policy rather than an
accidental default, and whether the rendered page has enough substance for a non-JS-executing
crawler to answer from.

A store can pass every `frontend-quality.md` SEO criterion — a `<meta name="description">` tag
exists, `hreflang` appears somewhere in the metadata object — while failing every criterion
here, because "the tag exists" and "the tag is right for this URL" are different claims.

## 1. Locale-content mismatch

A page served with `lang="ar"` carrying an English meta description is not a partial win; an
answer engine queried in Arabic gets handed a mismatched summary and either drops it or
surfaces it wrong. The same failure shows up as `lang="ar"` served at an `/en/` path — the
locale segment in the URL promised content the response didn't deliver.

## 2. Entity fragmentation

A brand indexed at two live domains — the current storefront and a stale prior site (a
default-content WordPress install, an abandoned landing page) — splits authority and search
answers between them. A visitor's "where do I buy X" question can be answered from the wrong
one, and the stale one is often the one with the weaker or outdated content precisely because
nobody maintains it anymore.

## 3. AI-crawler policy without a decision behind it

Blocking OpenAI/Anthropic/Common-Crawl **training** crawlers while allowing OpenAI/Anthropic
**answer/search** crawlers (`OAI-SearchBot` vs `GPTBot`, `Claude-SearchBot`/`Claude-User` vs
`ClaudeBot`) is a legitimate, common choice — it keeps content out of model training while
staying answerable by assistants doing live lookups. The failure isn't the policy; it's an
edge rule (Cloudflare, a CDN WAF) enforcing a *different* policy than `robots.txt` states, with
no record of which was the intended one, and no consistency across a portfolio of stores that
should share a policy.

## 4. What to check

| # | Criterion | Solid (grade 2) | Gap detection | Severity |
|---|---|---|---|---|
| 1 | Meta description matches the served `lang` | Every localized URL's `<meta name="description">` (and title) is written for the language that URL's `lang` attribute declares — not a store-wide default in one language | `curl -s "$SITE/ar/products/<slug>" \| grep -oE '<html[^>]*lang="[^"]*"' ` then compare against `grep -oE '<meta name="description"[^>]*>'` on the same response; sample across several product/category pages, not one | High |
| 2 | Locale path matches locale content | `/en/...` paths serve English content with `lang="en"`; `/ar/...` (or default) serves Arabic with `lang="ar"` — no path/lang/content three-way mismatch | `curl -s "$SITE/en/products/<slug>"` and confirm `lang="en"` AND English body copy, not a redirect-free fallback to the default locale's markup | High |
| 3 | `hreflang` alternates present and reciprocal | Every localized page declares `hreflang` alternates for every locale it has, and each alternate points back | `curl -sI "$SITE/..." \| grep -i hreflang` or check `<link rel="alternate" hreflang>` in the body; verify the AR page's EN alternate link and the EN page's AR alternate link both resolve | Medium |
| 4 | Canonical on every page, not a sample | Homepage AND every product/category/content page emits `rel=canonical` pointing at itself (or the intended canonical URL) | `curl -s "$SITE/" \| grep -o 'rel="canonical"[^>]*>'`; repeat for homepage specifically — a storefront can have canonical on product pages and miss it on the homepage, which is exactly the gap found here | High |
| 5 | Single canonical brand entity | No stale/duplicate domain for the same brand remains indexed with default or outdated content; if one exists, it 301s to the current site or is deindexed (`noindex` + removal request), not left live with placeholder content | web-search the brand name + location; check every result's freshness and content against the current site; a result with obvious default/placeholder content (a default CMS welcome post) under the same brand is the finding | High |
| 6 | AI-crawler policy is documented and consistent | `robots.txt` and any edge/WAF rule agree on the stated policy; if they deliberately differ (edge blocks training bots, allows answer bots), that split is written down somewhere in the repo/ops docs, and the same split applies across every store in the portfolio unless a store-specific reason is recorded | `curl -s "$SITE/robots.txt"`; then `for ua in GPTBot ClaudeBot CCBot Bytespider OAI-SearchBot ChatGPT-User Claude-SearchBot Claude-User PerplexityBot meta-externalagent Googlebot; do echo -n "$ua: "; curl -sA "$ua" -o /dev/null -w "%{http_code}\n" "$SITE/"; done`; a response that contradicts `robots.txt` with no doc explaining why is the finding; an inconsistent policy across sibling stores in the same portfolio is also the finding | Medium |
| 7 | Rendered text meets a substance floor | The server-rendered (no-JS) page carries enough visible text for a non-JS-executing crawler to answer from — not just navigation/category labels | fetch with JS disabled (`curl` the raw HTML, strip tags, count visible characters); compare homepage and a representative content page against the store's own historical baseline or a portfolio median; a page at a few hundred visible characters, mostly nav labels, is the finding | Medium |

## 5. What good looks like

The reference shape observed on the same store this lens was measured against (which passes
this list on every point above while still failing it on locale/entity/substance): product
JSON-LD with `Product`/`Brand`/`Offer`/`OfferShippingDetails`/`FAQPage`; homepage
`Organization`/`Store`/`ItemList`; bilingual `llms.txt`; a sitemap covering every product;
`robots.txt` allowing crawl; `security.txt`; `/privacy` and `/terms` reachable. Pass all of
that AND this doc's seven criteria, and the store is answerable correctly in either language,
from one entity, by a crawler that respects a real policy.

## 6. Where it is graded

Any public storefront/marketing site serving more than one locale, or any brand with more than
one live domain. Criteria 1–2 are N/A for a single-locale site (still check 3 is N/A rather
than a gap in that case); criterion 5 requires a web search, not just a repo grep, so it's a
manual step in a full audit rather than a CI gate.
