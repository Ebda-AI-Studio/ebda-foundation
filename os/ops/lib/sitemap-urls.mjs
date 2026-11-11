#!/usr/bin/env node
// sitemap-urls.mjs — resolve representative page URLs per store from /sitemap.xml.
// CLI: node sitemap-urls.mjs <domain>  -> one JSON line {home,plp,pdp,cart,checkout}
// Fallback to canonical paths if the sitemap is missing/unparseable.

export async function resolveUrls(domain, fetchImpl = fetch) {
  const base = `https://${domain}`;
  const fallback = {
    home: `${base}/`,
    plp: `${base}/categories`,
    pdp: `${base}/products`,
    cart: `${base}/cart`,
    checkout: `${base}/checkout`,
  };
  let locs = [];
  try {
    const res = await fetchImpl(`${base}/sitemap.xml`, {
      headers: { "User-Agent": "WhiskyOS-PageLoadMonitor/1.0" },
      signal: AbortSignal.timeout(20000),
    });
    if (res && res.ok) {
      const xml = await res.text();
      // Capture loc content, then unwrap any <![CDATA[ ... ]]> (some sitemap
      // generators wrap URLs in CDATA — a plain [^<]+ match would skip them).
      locs = [...xml.matchAll(/<loc>(.*?)<\/loc>/g)]
        .map(m => m[1].replace(/^\s*<!\[CDATA\[/, "").replace(/\]\]>\s*$/, "").trim())
        .filter(Boolean);
    }
  } catch { /* fail-open to fallback */ }
  if (locs.length === 0) return fallback;
  const plp = locs.find(l => /\/categories\/[^/]+/.test(l))
           || locs.find(l => /\/categor/.test(l)) || fallback.plp;
  const pdp = locs.find(l => /\/products\/[^/]+/.test(l)) || fallback.pdp;
  return { home: `${base}/`, plp, pdp, cart: fallback.cart, checkout: fallback.checkout };
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const domain = process.argv[2];
  if (!domain) { console.error("usage: sitemap-urls.mjs <domain>"); process.exit(2); }
  resolveUrls(domain).then(u => { console.log(JSON.stringify(u)); });
}
