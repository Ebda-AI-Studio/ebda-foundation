# storefront-locale-routes — every route keeps the locale prefix; the sitemap is every public page x locales

tags: [BOTH]
sources: Ebda Store QA 2026-11-11 (ameliaaurum.com, store 1bb14d0e, prod 81f766a), `hreflang-locale-url`

## Rule 1 — every storefront route keeps the locale prefix

A storefront that serves language in the URL (`/ar/...`, `/en/...`) serves EVERY page under both prefixes: indexable pages
(home, products, categories, blog, static pages) AND transactional ones (cart, checkout, account, auth, search, wishlist,
compare, bundles, collections). A prefixed URL is rewritten to the route and rendered in the URL's language; it is never
redirected to the unprefixed path. Only a URL that is no route at all (`/en/no-such`) may redirect.

- Internal links on a prefixed page keep the active locale, for every route above (one shared link helper, no direct `next/link`).
- Indexable routes redirect their UNPREFIXED form to the prefixed one; transactional routes do not (noindex, no canonical to protect).
- Robots disallows the private routes under each prefix as well as unprefixed.
- Why: an English shopper at `/en/products` pressed Cart and landed on `/cart` in Arabic; a cookie-only language cannot survive a cookieless fetch, a shared link or a redirect.

**Enforced by:** a guard test that walks the storefront route list and fails if any locale-prefixed route decides `redirect`.

## Rule 2 — sitemap = all public pages x locales with hreflang; robots names it

`/sitemap.xml` of a store host lists home, product, category/collection and public static pages for BOTH locales, each entry
with `lastmod` and `xhtml:link` alternates `ar`, `en`, `x-default`. `robots.txt` carries `Sitemap: https://<host>/sitemap.xml` on
custom domains and platform subdomains alike.

- The only legitimate zero-URL answer is a merchant-hidden store ("hide from search engines") or the demo showroom; both
  also omit the `Sitemap:` line and serve `noindex`. A listed store with published products and zero URLs is a defect.
- An API outage answers 5xx, never an empty 200 (Search Console would record "0 discovered URLs").
- Products have one slug unless the data model has per-locale slugs; canonical and hreflang then use the same slug under each prefix.

**Enforced by:** a sitemap test that fails on zero URLs for a store with published products and asserts the `Sitemap:` line.

Score 0: a prefixed route redirects to an unprefixed one, or a listed store's sitemap is empty / robots omits it. Score 2: both guards exist and pass.
