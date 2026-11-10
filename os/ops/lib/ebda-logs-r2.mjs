// ebda-logs-r2.mjs - read the Workers Logpush objects from R2 through api.cloudflare.com only (the one Cloudflare host this Mac can
// reach: the tail WebSocket host sits on the 188.114.96/97.x range an Egyptian ISP blocks). No deps; Node >= 22 (global fetch).
//
// Credentials, first hit wins (the value is never printed):
//   token   : $EBDA_LOGS_CF_TOKEN, $CLOUDFLARE_API_TOKEN, else wrangler's OAuth token in its config file (run `npx wrangler whoami` first
//             to refresh it). A scoped token needs: Account > Workers R2 Storage > Read.
//   account : $CLOUDFLARE_ACCOUNT_ID, $OS_CF_ACCOUNT_ID, else OS_CF_ACCOUNT_ID in ~/.ebda-os.local.env.
import { readFileSync, existsSync } from 'node:fs';
import { homedir } from 'node:os';
import { gunzipSync } from 'node:zlib';
import { dayPrefixes, keysInWindow, parseNdjson } from './ebda-logs-core.mjs';

const API = 'https://api.cloudflare.com/client/v4';

// The Cloudflare API allows 1200 requests per 5 minutes per user (4/s), shared by every token of that user. Measured 2026-11-10: 16
// parallel downloads tripped code 971 within a minute. So every call takes a slot from a pacer (default 3 req/s, $EBDA_LOGS_RPS), the
// sleep-after-success throttle, not retry-on-429; a 429 that still happens backs off 5 s, 10 s, 20 s.
let nextSlot = 0;
async function pace() {
  const gap = 1000 / Number(process.env.EBDA_LOGS_RPS || 3);
  const now = Date.now();
  const at = Math.max(now, nextSlot);
  nextSlot = at + gap;
  if (at > now) await new Promise((r) => setTimeout(r, at - now));
}

export function resolveCreds(env = process.env) {
  let token = env.EBDA_LOGS_CF_TOKEN || env.CLOUDFLARE_API_TOKEN || '';
  let tokenSource = token ? 'env' : '';
  if (!token) {
    for (const p of [`${homedir()}/Library/Preferences/.wrangler/config/default.toml`, `${homedir()}/.config/.wrangler/config/default.toml`]) {
      if (!existsSync(p)) continue;
      const m = /^oauth_token\s*=\s*"([^"]+)"/m.exec(readFileSync(p, 'utf8'));
      if (m) { token = m[1]; tokenSource = 'wrangler-oauth'; break; }
    }
  }
  let account = env.CLOUDFLARE_ACCOUNT_ID || env.OS_CF_ACCOUNT_ID || '';
  const local = `${homedir()}/.ebda-os.local.env`;
  if (!account && existsSync(local)) {
    const m = /^OS_CF_ACCOUNT_ID=["']?([0-9a-f]{32})/m.exec(readFileSync(local, 'utf8'));
    if (m) account = m[1];
  }
  return { token, tokenSource, account };
}

async function cf(url, token, { retries = 3, raw = false } = {}) {
  for (let i = 0; ; i++) {
    let res;
    await pace();
    try {
      res = await fetch(url, { headers: { Authorization: `Bearer ${token}` }, signal: AbortSignal.timeout(30000) });
    } catch (e) {
      if (i < retries) { await new Promise((r) => setTimeout(r, 500 * 2 ** i)); continue; }
      throw new Error(`network: ${e.message}`);
    }
    if ((res.status === 429 || res.status >= 500) && i < retries) { await new Promise((r) => setTimeout(r, (res.status === 429 ? 5000 : 1000) * 2 ** i)); continue; }
    if (!res.ok) {
      const body = await res.text();
      let msg = body.slice(0, 200);
      try { msg = JSON.stringify(JSON.parse(body).errors); } catch { /* raw */ }
      throw new Error(`HTTP ${res.status} ${url.replace(/\/accounts\/[^/]+/, '/accounts/<acct>')}: ${msg}`);
    }
    if (raw) return Buffer.from(await res.arrayBuffer());
    const j = await res.json();
    if (j.success === false) throw new Error(`API success:false: ${JSON.stringify(j.errors).slice(0, 200)}`);
    return j;
  }
}

/** All object keys under the day prefixes the window touches, filtered to batches overlapping the window. */
export async function listKeys({ token, account, bucket = 'ebda-logs', fromMs, toMs, root = 'workers/' }) {
  const keys = [];
  for (const prefix of dayPrefixes(fromMs, toMs, root)) {
    let cursor = '';
    do {
      const q = new URLSearchParams({ prefix, per_page: '1000' });
      if (cursor) q.set('cursor', cursor);
      const j = await cf(`${API}/accounts/${account}/r2/buckets/${bucket}/objects?${q}`, token);
      for (const o of j.result || []) keys.push(o.key);
      cursor = j.result_info?.is_truncated ? j.result_info.cursor : '';
    } while (cursor);
  }
  return keysInWindow(keys, fromMs, toMs);
}

/** Download keys with at most `concurrency` in flight; gunzip when the bytes are gzip (the API usually serves them decoded). */
export async function fetchRecords({ token, account, bucket = 'ebda-logs', keys, concurrency = 6, onProgress }) {
  const records = [];
  let bad = 0;
  let failed = 0;
  let next = 0;
  let done = 0;
  async function worker() {
    while (next < keys.length) {
      const key = keys[next++];
      try {
        let buf = await cf(`${API}/accounts/${account}/r2/buckets/${bucket}/objects/${encodeURIComponent(key).replace(/%2F/g, '/')}`, token, { raw: true });
        if (buf[0] === 0x1f && buf[1] === 0x8b) buf = gunzipSync(buf);
        const p = parseNdjson(buf.toString('utf8'));
        for (const r of p.records) records.push(r);
        bad += p.bad;
      } catch {
        failed++;
      }
      done++;
      if (onProgress && done % 100 === 0) onProgress(done, keys.length);
    }
  }
  await Promise.all(Array.from({ length: Math.min(concurrency, keys.length) }, worker));
  return { records, bad, failed };
}
