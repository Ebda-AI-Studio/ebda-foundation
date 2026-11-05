import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { execSync } from "node:child_process";
import { join } from "node:path";
// Playwright lives in the GLOBAL npm root; an ESM import from an ops script cannot see it, and
// the failure surfaced as "session expired" — a message about the wrong thing entirely.
let chromium;
try {
  const root = execSync("npm root -g", { encoding: "utf8" }).trim();
  chromium = createRequire(join(root, "x.js"))("playwright").chromium;
} catch (e) {
  console.log("listing failed: playwright not resolvable (npm i -g playwright) —", e.code || e.message);
  process.exit(3);
}
// Discovery through the same door a human uses: the logged-in profile page.
// Cookies come from the Netscape jar yt-dlp exports from Chrome.
// Keep #HttpOnly_ lines: that prefix is where `sessionid` lives, and dropping every line
// beginning with # throws the session away while looking like a comment filter.
const jar = readFileSync(process.argv[3], "utf8").split("\n")
  .map((l) => l.replace(/^#HttpOnly_/, ""))
  .filter((l) => l && !l.startsWith("#"));
const cookies = jar.map((l) => l.replace(/\r$/, "").split("\t")).filter((p) => p.length >= 7)
  .map(([domain, , path, secure, expires, name, value]) => {
    // Chrome writes expiry in ITS epoch: microseconds since 1601. Playwright wants unix seconds,
    // and silently rejects the raw number as "not a valid expires".
    let exp = Math.floor(Number(expires));
    if (exp > 1e12) exp = Math.floor(exp / 1e6 - 11644473600);
    return { name, value, domain, path: path || "/", expires: Number.isFinite(exp) && exp > 0 ? exp : -1,
             httpOnly: false, secure: secure === "TRUE", sameSite: "Lax" };
  });
console.log("cookies parsed:", cookies.length, "(instagram only)");
const b = await chromium.launch({ channel: "chrome", headless: true });
const ctx = await b.newContext({ viewport: { width: 1280, height: 1400 }, userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0 Safari/537.36" });
await ctx.addCookies(cookies);
const p = await ctx.newPage();
await p.goto(process.argv[2], { waitUntil: "domcontentloaded", timeout: 120000 });
await p.waitForTimeout(6000);
const links = await p.evaluate(() => [...new Set([...document.querySelectorAll('a[href*="/reel/"], a[href*="/p/"]')].map((a) => a.getAttribute("href")))]);
console.log("logged in:", await p.evaluate(() => document.documentElement.className.includes("logged-in") || !!document.querySelector('a[href*="/direct/"]')));
console.log("posts found:", links.length);
for (const l of links.slice(0, 8)) console.log("  ", l);
await b.close();
