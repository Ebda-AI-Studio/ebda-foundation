// services watcher (cron, every 15 min): HTTP probes of the named Ebda services (api, storefront, admin, chat). Extends
// health.ts and reuses its checkOne (a 200 with ok:false / status:"down" still counts as down). health.ts keeps its fast 5 min
// two-URL check; this one covers the full named list, with a per-service failure streak kept in KV.
import { policyFrom } from '../env';
import { checkOne, type HealthTarget } from './health';
import { finding, isHttps, isObj, parseList, reportUnconfigured, settle, type WatchCtx } from './common';

export const ID = 'services';
export const INTERVAL_MS = 15 * 60 * 1000;

export interface ServiceTarget extends HealthTarget {
  name: string;
}

const isService = (x: unknown): x is ServiceTarget => isObj(x) && isHttps(x.url) && typeof x.name === 'string' && /^[\w.-]{1,40}$/.test(x.name) && ['api', 'page', 'money'].includes(String(x.kind));

export async function watchServices(ctx: WatchCtx): Promise<{ checked: number; down: string[] }> {
  const targets = parseList(ctx.env.SERVICE_TARGETS, isService, 12);
  if (targets === null || targets.length === 0) {
    await reportUnconfigured(ctx, ID, 'SERVICE_TARGETS (JSON list of {name,url,kind})');
    return { checked: 0, down: [] };
  }
  const budget = policyFrom(ctx.env).healthFailBudget;
  const obs = await Promise.all(targets.map((t) => checkOne(t, ctx.fetchImpl)));
  const current = [];
  const down: string[] = [];
  for (const [i, t] of targets.entries()) {
    const o = obs[i]!;
    const streakKey = `svc:fails:${t.name}`;
    if (o.ok) {
      await ctx.env.EVENTS.delete(streakKey);
      continue;
    }
    down.push(t.name);
    const prev = (await ctx.env.EVENTS.get<{ n: number; since: number }>(streakKey, 'json')) ?? { n: 0, since: ctx.now };
    const streak = prev.n + 1;
    await ctx.env.EVENTS.put(streakKey, JSON.stringify({ n: streak, since: prev.since }), { expirationTtl: 24 * 3600 });
    if (streak < budget) continue; // inside the retry window: not a finding yet
    // the same classifier rules as health.ts: an outage is urgent only once the retry budget is spent
    current.push(
      finding(ID, t.kind === 'money' ? 'money-path-broken' : 'prod-outage', t.name, 'down', `service ${t.name} down (HTTP ${o.status || 'no response'}, ${streak} checks in a row)`, {
        url: t.url,
        severity: 'P1',
        selfHealExhausted: true,
        touches: t.kind === 'money' ? ['money'] : [],
        detail: { incident: prev.since, status: o.status, ms: o.ms },
      }),
    );
  }
  // a recovered service resolves its earlier outage finding (both kinds, same key)
  for (const kind of ['prod-outage', 'money-path-broken']) {
    await settle(ctx, ID, kind, current.filter((f) => f.kind === kind));
  }
  return { checked: targets.length, down };
}
