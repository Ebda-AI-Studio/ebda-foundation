// world-watch watcher (cron, every 6 h): the outside world that can hurt the Ebda stack.
//  - vendor status pages (Atlassian Statuspage JSON, default Cloudflare + GitHub; WORLD_STATUS_URLS replaces the list):
//    an unresolved incident with impact major or critical is a finding;
//  - npm advisories for the dependencies the Ebda services ship (WORLD_NPM_DEPS = JSON {"pkg":["1.2.3"]}): the npm bulk
//    advisory endpoint, high and critical only. Dependabot (advisories.ts) stays the source for repo alerts; this catches a
//    package advisory for a pinned runtime version between Dependabot scans.
// Keys: world-watch:<source>:<incident id> / world-watch:npm/<pkg>@<ver>/<advisory id>:open.
import { clearError, finding, httpJson, isHttps, isObj, isSet, parseList, reportError, reportUnconfigured, settle, WatcherError, type WatchCtx } from './common';

export const ID = 'world-watch';
export const INTERVAL_MS = 6 * 60 * 60 * 1000;
const DEFAULT_STATUS = [
  { name: 'cloudflare', url: 'https://www.cloudflarestatus.com/api/v2/summary.json' },
  { name: 'github', url: 'https://www.githubstatus.com/api/v2/summary.json' },
  { name: 'anthropic', url: 'https://status.anthropic.com/api/v2/summary.json' },
];
interface StatusSrc {
  name: string;
  url: string;
}
const isStatus = (x: unknown): x is StatusSrc => isObj(x) && isHttps(x.url) && typeof x.name === 'string' && /^[\w.-]{1,30}$/.test(x.name);

export async function watchWorld(ctx: WatchCtx): Promise<{ sources: number; flagged: number }> {
  const sources = parseList(ctx.env.WORLD_STATUS_URLS, isStatus, 8) ?? DEFAULT_STATUS;
  const status = [];
  let statusComplete = true;
  for (const s of sources) {
    try {
      const j = (await httpJson(ctx, s.url)) as { incidents?: unknown };
      if (!Array.isArray(j.incidents)) throw new WatcherError('status JSON has no incidents list');
      await clearError(ctx, ID, s.name);
      for (const i of j.incidents as Array<{ id?: unknown; name?: unknown; impact?: unknown; status?: unknown; shortlink?: unknown }>) {
        if (typeof i.id !== 'string' || !['major', 'critical'].includes(String(i.impact)) || ['resolved', 'postmortem'].includes(String(i.status))) continue;
        status.push(finding(ID, 'vendor-incident', s.name, i.id, `${s.name} incident (${i.impact}): ${String(i.name ?? '').slice(0, 120)}`, { severity: 'P3', ...(isHttps(i.shortlink) ? { url: i.shortlink } : {}) }));
      }
    } catch (e) {
      statusComplete = false;
      await reportError(ctx, ID, s.name, e);
    }
  }
  await settle(ctx, ID, 'vendor-incident', status, statusComplete);

  const npm = [];
  let npmComplete = true;
  const deps = isSet(ctx.env.WORLD_NPM_DEPS) ? safeDeps(ctx.env.WORLD_NPM_DEPS) : null;
  if (deps === null) {
    await reportUnconfigured(ctx, ID, 'WORLD_NPM_DEPS (JSON {"package":["version"]}); only the vendor status half is running');
  } else if (Object.keys(deps).length) {
    try {
      const j = await httpJson(ctx, 'https://registry.npmjs.org/-/npm/v1/security/advisories/bulk', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(deps) });
      if (!isObj(j)) throw new WatcherError('npm advisory response is not an object');
      await clearError(ctx, ID, 'npm');
      for (const [pkg, advs] of Object.entries(j)) {
        if (!Array.isArray(advs)) continue;
        for (const a of advs as Array<{ id?: unknown; title?: unknown; severity?: unknown; url?: unknown; vulnerable_versions?: unknown }>) {
          if (!['high', 'critical'].includes(String(a.severity))) continue;
          npm.push(finding(ID, 'world-advisory', `npm/${pkg}/${String(a.id)}`, 'open', `npm ${pkg}: ${String(a.title ?? '').slice(0, 120)} (${a.severity})`, { severity: 'P3', ...(isHttps(a.url) ? { url: a.url } : {}), detail: { vulnerable: a.vulnerable_versions } }));
        }
      }
    } catch (e) {
      npmComplete = false;
      await reportError(ctx, ID, 'npm', e);
    }
  }
  await settle(ctx, ID, 'world-advisory', npm, npmComplete && deps !== null);
  return { sources: sources.length, flagged: status.length + npm.length };
}

function safeDeps(raw: string): Record<string, string[]> | null {
  try {
    const v = JSON.parse(raw) as unknown;
    if (!isObj(v)) return {};
    const out: Record<string, string[]> = {};
    for (const [k, vs] of Object.entries(v).slice(0, 200)) if (/^(@[\w.-]+\/)?[\w.-]+$/.test(k) && Array.isArray(vs)) out[k] = vs.filter((x): x is string => typeof x === 'string' && /^\d+\.\d+\.\d+/.test(x)).slice(0, 5);
    return out;
  } catch {
    return {};
  }
}
