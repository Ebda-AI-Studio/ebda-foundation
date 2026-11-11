// Pure logic for isp-188-watch: is an IPv4 address inside a blocked CIDR, which hosts resolve into one, and the brain findings for them.
// The resolver is injected (DNS-over-HTTPS in production, a fixture in tests), so nothing here touches the network.
import { createHash } from 'node:crypto';

const ip4 = (s) => {
  const m = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(String(s).trim());
  if (!m || m.slice(1).some((o) => Number(o) > 255)) return null;
  return ((Number(m[1]) << 24) | (Number(m[2]) << 16) | (Number(m[3]) << 8) | Number(m[4])) >>> 0;
};

export function inCidr(ip, cidr) {
  const [base, bits] = String(cidr).split('/');
  const a = ip4(ip); const b = ip4(base); const n = Number(bits);
  if (a === null || b === null || !Number.isInteger(n) || n < 0 || n > 32) return false;
  const mask = n === 0 ? 0 : (~0 << (32 - n)) >>> 0;
  return ((a & mask) >>> 0) === ((b & mask) >>> 0);
}

export const inAnyCidr = (ip, cidrs) => cidrs.some((c) => inCidr(ip, c));

/** hosts: string[]; resolve(host) -> Promise<string[]> (A records; throws or returns [] when it cannot resolve). */
export async function checkHosts(hosts, resolve, cidrs) {
  const results = [];
  for (const host of hosts) {
    let ips = []; let error;
    try { ips = [...new Set((await resolve(host)).filter((x) => ip4(x) !== null))].sort(); } catch (e) { error = String(e?.message || e); }
    if (!ips.length && !error) error = 'no A records';
    results.push({ host, ips, blocked: ips.filter((x) => inAnyCidr(x, cidrs)), error });
  }
  return results;
}

/** One P1 finding per host that has an IP in the blocked range; one P3 per host that did not resolve (a resolver blip is not an outage). */
export function toFindings(results, cidrs) {
  const out = [];
  for (const r of results) {
    if (r.blocked.length) {
      out.push({ source: 'isp-188', kind: 'isp-block-range', key: r.host, severity: 'P1',
        title: `${r.host} resolves into ${cidrs.join(', ')} (blocked by the Egyptian ISP): ${r.blocked.join(', ')}. Egyptian shoppers cannot reach it; move the zone or hostname off that range.`,
        detail: { host: r.host, ips: r.ips, blocked: r.blocked } });
    } else if (r.error) {
      out.push({ source: 'isp-188', kind: 'dns-unresolved', key: r.host, severity: 'P3', title: `${r.host} did not resolve (${r.error}); ISP-range check skipped for it`, detail: { host: r.host } });
    }
  }
  return out;
}

/** Stable signature of what was resolved: the run is skipped (nothing posted) when it equals the last one (resource-frugal). */
export function signature(results) {
  return createHash('sha256').update(JSON.stringify(results.map((r) => [r.host, r.ips, r.error ? 1 : 0]))).digest('hex').slice(0, 32);
}
