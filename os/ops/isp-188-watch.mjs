#!/usr/bin/env node
// isp-188-watch - alert when a merchant-facing host resolves into the Cloudflare range the Egyptian ISP blocks (188.114.96.0/23).
//
//   isp-188-watch.mjs [--config FILE] [--state FILE] [--out FILE] [--fixture FILE] [--hosts a,b] [--force]
//
// Resolves every host in lib/isp-188-hosts.json over DNS-over-HTTPS (the Mac's own resolver is the ISP's, so it cannot be trusted
// to show what the world sees). Writes the brain findings array to --out (default stdout); the wrapper isp-188-watch.sh posts it through
// lib/brain-post.sh. Skips (writes [] and leaves the state) when the resolved IP sets equal the last run's, unless --force.
// --fixture FILE: a JSON map { host: [ips] } used instead of DoH (tests).
import { readFileSync, writeFileSync, existsSync, mkdirSync } from 'node:fs';
import { dirname } from 'node:path';
import { checkHosts, toFindings, signature } from './lib/isp188-core.mjs';

const argv = process.argv.slice(2);
const opt = (n, d) => { const i = argv.indexOf(`--${n}`); return i >= 0 ? argv[i + 1] : d; };
if (argv.includes('--help') || argv.includes('-h')) {
  console.log(readFileSync(new URL(import.meta.url), 'utf8').split('\n').slice(1, 10).map((l) => l.replace(/^\/\/ ?/, '')).join('\n'));
  process.exit(0);
}
const cfg = JSON.parse(readFileSync(opt('config', new URL('./lib/isp-188-hosts.json', import.meta.url).pathname), 'utf8'));
const hosts = opt('hosts') ? opt('hosts').split(',') : [...cfg.hosts, ...cfg.storeSample, ...cfg.custom];
const statePath = opt('state');
const fixture = opt('fixture') ? JSON.parse(readFileSync(opt('fixture'), 'utf8')) : null;

async function doh(host) {
  const r = await fetch(`https://cloudflare-dns.com/dns-query?name=${encodeURIComponent(host)}&type=A`, { headers: { accept: 'application/dns-json' }, signal: AbortSignal.timeout(8000) });
  if (!r.ok) throw new Error(`DoH HTTP ${r.status}`);
  return ((await r.json()).Answer || []).filter((a) => a.type === 1).map((a) => a.data);
}
const resolve = fixture ? async (h) => { if (!(h in fixture)) throw new Error('not in fixture'); return fixture[h]; } : doh;

const results = await checkHosts(hosts, resolve, cfg.blockedCidrs);
const sig = signature(results);
const prev = statePath && existsSync(statePath) ? JSON.parse(readFileSync(statePath, 'utf8')).signature : null;
let findings = [];
if (prev === sig && !argv.includes('--force')) {
  console.error(`isp-188-watch: unchanged since the last run (${hosts.length} hosts), nothing posted`);
} else {
  findings = toFindings(results, cfg.blockedCidrs);
  console.error(`isp-188-watch: ${hosts.length} hosts, ${results.filter((r) => r.blocked.length).length} in ${cfg.blockedCidrs.join(',')}, ${findings.length} finding(s)`);
  if (statePath) { mkdirSync(dirname(statePath), { recursive: true }); writeFileSync(statePath, JSON.stringify({ signature: sig, at: new Date().toISOString() })); }
}
const json = JSON.stringify(findings);
if (opt('out')) writeFileSync(opt('out'), json); else console.log(json);
