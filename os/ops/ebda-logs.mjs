#!/usr/bin/env node
// ebda-logs - read what Ebda production did, from the Workers Logpush objects in R2 (bucket ebda-logs), through api.cloudflare.com only.
// `wrangler tail` cannot work from an Egyptian ISP (its WebSocket host is on the blocked 188.114.96/97.x range); this can.
//
//   ebda-logs.mjs [--since 2h|30m|1d|<ISO>] [--until <ISO>|now] [--script ebda-web,ebda-api] [--status 429|5xx|4xx|500]
//                 [--path /store/resolve] [--top 15] [--minutes <script>] [--callers <script>:<status>] [--json] [--concurrency 6]
//                 [--bucket ebda-logs]
//
// Prints: records + scripts seen, invocations by script x kind, outcomes, fetch requests by script x status, top paths by 5xx/429,
// exceptions grouped, error/warn console lines grouped, RPC methods, CPU/wall p50/p95 (only when the Logpush job carries them).
// Filters narrow which records are aggregated; the "scripts seen" line always covers the whole window.
// Credentials: see os/ops/lib/ebda-logs-r2.mjs (never printed). Exit 2 = no credentials, 3 = listing failed, 4 = some objects unreadable.
import { aggregate, callers, matches, perMinute } from './lib/ebda-logs-core.mjs';
import { resolveCreds, listKeys, fetchRecords } from './lib/ebda-logs-r2.mjs';

const argv = process.argv.slice(2);
const opt = (name, dflt) => {
  const i = argv.indexOf(`--${name}`);
  return i >= 0 ? argv[i + 1] : dflt;
};
const flag = (name) => argv.includes(`--${name}`);
if (flag('help') || flag('h')) {
  console.log((await import('node:fs')).readFileSync(new URL(import.meta.url), 'utf8').split('\n').slice(1, 14).map((l) => l.replace(/^\/\/ ?/, '')).join('\n'));
  process.exit(0);
}

export function parseWhen(s, nowMs = Date.now()) {
  if (!s || s === 'now') return nowMs;
  const m = /^(\d+)([mhd])$/.exec(s);
  if (m) return nowMs - Number(m[1]) * { m: 60000, h: 3600000, d: 86400000 }[m[2]];
  const t = Date.parse(s);
  if (Number.isNaN(t)) throw new Error(`cannot parse time: ${s}`);
  return t;
}

const toMs = parseWhen(opt('until', 'now'));
const fromMs = parseWhen(opt('since', '1h'), toMs);
const top = Number(opt('top', '15'));
const { token, account } = resolveCreds();
if (!token || !account) {
  console.error('ebda-logs: no Cloudflare credentials (set EBDA_LOGS_CF_TOKEN + CLOUDFLARE_ACCOUNT_ID, or run `npx wrangler whoami` and set OS_CF_ACCOUNT_ID)');
  process.exit(2);
}
const bucket = opt('bucket', 'ebda-logs');
let keys;
try {
  keys = await listKeys({ token, account, bucket, fromMs, toMs });
} catch (e) {
  console.error(`ebda-logs: listing failed: ${e.message}`);
  process.exit(3);
}
const t0 = Date.now();
const { records: all, bad, failed } = await fetchRecords({ token, account, bucket, keys, concurrency: Number(opt('concurrency', '6')), onProgress: (d, n) => process.stderr.write(`\r${d}/${n} objects`) });
process.stderr.write('\r\x1b[K');
const inWin = all.filter((r) => r.EventTimestampMs >= fromMs && r.EventTimestampMs <= toMs);
const f = { script: opt('script'), status: opt('status'), path: opt('path') };
const recs = inWin.filter((r) => matches(r, f));
const agg = aggregate(recs);
const seen = aggregate(inWin).scripts;

if (flag('json')) {
  const { rays, ...rest } = agg;
  console.log(JSON.stringify({ fromMs, toMs, objects: keys.length, failedObjects: failed, badLines: bad, scriptsSeen: seen, ...rest }, null, 1));
  process.exit(failed ? 4 : 0);
}

const iso = (t) => new Date(t).toISOString().replace('.000', '');
const sect = (title, rows, fmt = ([k, v]) => `  ${String(v).padStart(7)}  ${k.replaceAll('|', '  ')}`) => {
  console.log(`${title}${rows.length > top ? ` (top ${top} of ${rows.length})` : ''}`);
  if (!rows.length) console.log('        -  none');
  for (const r of rows.slice(0, top)) console.log(fmt(r));
};
console.log(`window ${iso(fromMs)} .. ${iso(toMs)}  objects ${keys.length} (${failed} unreadable, ${bad} bad lines)  records ${inWin.length} in window, ${recs.length} after filters  fetched in ${((Date.now() - t0) / 1000).toFixed(1)}s`);
console.log(`scripts seen: ${seen.map(([s, n]) => `${s}=${n}`).join(' ')}`);
sect('invocations by script x kind', agg.kinds);
sect('outcomes (script x outcome)', agg.outcomes.filter(([k]) => !k.endsWith('|ok')).concat(agg.outcomes.filter(([k]) => k.endsWith('|ok'))));
sect('fetch requests by script x status', agg.byScriptStatus);
sect('top paths by 5xx/429 (status script host+path)', agg.errPaths);
sect('exceptions grouped', agg.exceptions);
sect('error/warn console lines grouped', agg.errorLogs);
sect('RPC methods', agg.rpc);
const t = agg.timings;
console.log(`timings: ${t.cpu ? `cpu p50 ${t.cpu.p50}ms p95 ${t.cpu.p95}ms (n=${t.cpu.n})` : 'cpu n/a'}; ${t.wall ? `wall p50 ${t.wall.p50}ms p95 ${t.wall.p95}ms (n=${t.wall.n})` : 'wall n/a'}${!t.cpu && !t.wall ? ' (CPUTimeMs/WallTimeMs are not in the Logpush job field list)' : ''}`);
const cs = opt('callers');
if (cs) {
  const [s, st] = cs.split(':');
  sect(`callers of ${s} answering ${st} (by shared RayID)`, callers(inWin, aggregate(inWin), s, Number(st)));
}
const pm = opt('minutes');
if (pm) {
  const rows = perMinute(inWin, pm).filter(([, v]) => v.s5xx || v.s429);
  sect(`${pm}: minutes with 5xx/429 (minute total 5xx 429)`, rows.map(([k, v]) => [k, v]), ([k, v]) => `  ${k}  ${v.total} ${v.s5xx} ${v.s429}`);
}
process.exit(failed ? 4 : 0);
