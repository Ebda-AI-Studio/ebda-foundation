import assert from "node:assert";
import { resolveUrls } from "../lib/sitemap-urls.mjs";

const SITEMAP = `<?xml version="1.0"?><urlset>
<url><loc>https://s.example/</loc></url>
<url><loc>https://s.example/categories/nuts</loc></url>
<url><loc>https://s.example/products/dark-choc</loc></url>
</urlset>`;

const fakeFetch = async () => ({ ok: true, status: 200, text: async () => SITEMAP });
const u = await resolveUrls("s.example", fakeFetch);
assert.equal(u.home, "https://s.example/");
assert.equal(u.plp, "https://s.example/categories/nuts");
assert.equal(u.pdp, "https://s.example/products/dark-choc");
assert.equal(u.cart, "https://s.example/cart");
assert.equal(u.checkout, "https://s.example/checkout");

// CDATA-wrapped locs are unwrapped, not skipped
const CDATA_SITEMAP = `<?xml version="1.0"?><urlset>
<url><loc><![CDATA[https://s.example/]]></loc></url>
<url><loc><![CDATA[https://s.example/categories/nuts]]></loc></url>
<url><loc><![CDATA[https://s.example/products/dark-choc]]></loc></url>
</urlset>`;
const cdataFetch = async () => ({ ok: true, status: 200, text: async () => CDATA_SITEMAP });
const c = await resolveUrls("s.example", cdataFetch);
assert.equal(c.plp, "https://s.example/categories/nuts", "CDATA plp should unwrap");
assert.equal(c.pdp, "https://s.example/products/dark-choc", "CDATA pdp should unwrap");

// fallback when sitemap fails
const deadFetch = async () => { throw new Error("no net"); };
const f = await resolveUrls("s.example", deadFetch);
assert.equal(f.plp, "https://s.example/categories");
assert.equal(f.pdp, "https://s.example/products");
console.log("PASS sitemap-urls");
