// page-load watcher (cron, HOURLY since 2026-11-14 frugal monitoring; was every 15 min): fetch timing of the key Ebda pages. Three sequential GETs per page; TTFB = time to
// response headers, total = time until the body is fully read. A page whose p50 (median of 3) TTFB or total exceeds
// PAGE_LOAD_P50_MS (default 1500) is a finding; a page that does not answer 2xx on a run counts that run as a failure and
// 2+ failures out of 3 is a finding of its own. Read-only GETs, no cookies.
import { finding, isHttps, isObj, numVar, parseList, reportUnconfigured, settle, type WatchCtx } from './common';

export const ID = 'page-load';
export const INTERVAL_MS = 60 * 60 * 1000;
export const RUNS = 3;

export interface PageTarget {
  name: string;
  url: string;
}
const isPage = (x: unknown): x is PageTarget => isObj(x) && isHttps(x.url) && typeof x.name === 'string' && /^[\w.-]{1,40}$/.test(x.name);

export const median = (xs: number[]): number => [...xs].sort((a, b) => a - b)[Math.floor(xs.length / 2)]!;

async function timeOnce(ctx: WatchCtx, url: string): Promise<{ ok: boolean; ttfb: number; total: number }> {
  const t0 = Date.now();
  try {
    const r = await ctx.fetchImpl(url, { redirect: 'follow', signal: AbortSignal.timeout(10000), headers: { 'user-agent': 'ebda-os-brain/page-load', 'cache-control': 'no-cache' } });
    const ttfb = Date.now() - t0;
    await r.arrayBuffer();
    return { ok: r.status >= 200 && r.status < 300, ttfb, total: Date.now() - t0 };
  } catch {
    return { ok: false, ttfb: 10000, total: 10000 };
  }
}

export async function watchPageLoad(ctx: WatchCtx): Promise<{ checked: number; slow: string[] }> {
  const pages = parseList(ctx.env.PAGE_LOAD_TARGETS, isPage, 10);
  if (pages === null || pages.length === 0) {
    await reportUnconfigured(ctx, ID, 'PAGE_LOAD_TARGETS (JSON list of {name,url})');
    return { checked: 0, slow: [] };
  }
  const limit = numVar(ctx.env.PAGE_LOAD_P50_MS, 1500);
  const current = [];
  const slow: string[] = [];
  for (const p of pages) {
    const runs = [];
    for (let i = 0; i < RUNS; i++) runs.push(await timeOnce(ctx, p.url));
    const failures = runs.filter((r) => !r.ok).length;
    const ttfb = median(runs.map((r) => r.ttfb));
    const total = median(runs.map((r) => r.total));
    if (failures >= 2) {
      slow.push(p.name);
      current.push(finding(ID, 'page-load', p.name, 'unreachable', `page ${p.name} failed ${failures}/${RUNS} timing runs`, { url: p.url, severity: 'P2', detail: { failures } }));
    } else if (ttfb > limit || total > limit) {
      slow.push(p.name);
      current.push(finding(ID, 'page-load', p.name, 'slow', `page ${p.name} p50 TTFB ${ttfb} ms / total ${total} ms over ${limit} ms`, { url: p.url, severity: 'P3', detail: { ttfbMs: ttfb, totalMs: total, limitMs: limit } }));
    }
  }
  await settle(ctx, ID, 'page-load', current);
  return { checked: pages.length, slow };
}
