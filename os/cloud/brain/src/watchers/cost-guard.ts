// cost-guard watcher (cron, every 6 h): spend counters against thresholds.
//  - GitHub Actions minutes this month for the Ebda org (COST_GH_ORG), from the org billing usage API. Enterprise includes
//    50,000 min/month: warn at COST_ACTIONS_WARN_MIN (48000), stop at COST_ACTIONS_STOP_MIN (49500). Needs GITHUB_TOKEN with
//    org billing read.
//  - Cloudflare Workers requests this month (GraphQL analytics) against the Workers Paid allowance: warn at
//    CF_REQUESTS_WARN (default 8,000,000), stop at CF_REQUESTS_STOP (default 10,000,000 = the included amount).
// States: warn / stop. Crossing back under resolves the finding. A billing API error is a watcher-error, never "under budget".
import { clearError, finding, graphql, httpJson, isSet, numVar, reportError, reportUnconfigured, settle, WatcherError, type WatchCtx } from './common';

export const ID = 'cost-guard';
export const INTERVAL_MS = 6 * 60 * 60 * 1000;
const QUERY = `query($acc:String!,$since:Time!,$until:Time!){viewer{accounts(filter:{accountTag:$acc}){workersInvocationsAdaptive(limit:1000,filter:{datetime_geq:$since,datetime_leq:$until}){sum{requests}}}}}`;

function level(value: number, warn: number, stop: number): 'warn' | 'stop' | null {
  return value >= stop ? 'stop' : value >= warn ? 'warn' : null;
}

export async function actionsMinutes(ctx: WatchCtx, org: string, d: Date): Promise<number> {
  const j = (await httpJson(ctx, `https://api.github.com/organizations/${encodeURIComponent(org)}/settings/billing/usage?year=${d.getUTCFullYear()}&month=${d.getUTCMonth() + 1}`, { headers: { authorization: `Bearer ${ctx.env.GITHUB_TOKEN}`, 'x-github-api-version': '2022-11-28' } })) as { usageItems?: unknown };
  if (!Array.isArray(j.usageItems)) throw new WatcherError('GitHub billing usage has no usageItems');
  let min = 0;
  for (const i of j.usageItems as Array<{ product?: string; unitType?: string; quantity?: number }>) {
    if (String(i.product).toLowerCase() === 'actions' && /minute/i.test(String(i.unitType))) min += Number(i.quantity ?? 0);
  }
  return min;
}

export async function watchCostGuard(ctx: WatchCtx): Promise<{ actionsMin: number | null; cfRequests: number | null }> {
  const out: { actionsMin: number | null; cfRequests: number | null } = { actionsMin: null, cfRequests: null };
  const current = [];
  const monthStart = new Date(Date.UTC(new Date(ctx.now).getUTCFullYear(), new Date(ctx.now).getUTCMonth(), 1));
  let complete = true;
  const missing: string[] = [];

  if (isSet(ctx.env.COST_GH_ORG) && isSet(ctx.env.GITHUB_TOKEN)) {
    try {
      const min = await actionsMinutes(ctx, ctx.env.COST_GH_ORG, new Date(ctx.now));
      out.actionsMin = min;
      await clearError(ctx, ID, 'github');
      const lv = level(min, numVar(ctx.env.COST_ACTIONS_WARN_MIN, 48000), numVar(ctx.env.COST_ACTIONS_STOP_MIN, 49500));
      if (lv) current.push(finding(ID, `cost-${lv}`, `actions-${ctx.env.COST_GH_ORG}`, lv, `GitHub Actions ${Math.round(min)} min used this month in ${ctx.env.COST_GH_ORG} (${lv} threshold)`, { severity: lv === 'stop' ? 'P1' : 'P2', detail: { minutes: Math.round(min) } }));
    } catch (e) {
      complete = false;
      await reportError(ctx, ID, 'github', e);
    }
  } else missing.push('COST_GH_ORG + GITHUB_TOKEN');

  if (isSet(ctx.env.CF_API_TOKEN) && isSet(ctx.env.CF_ACCOUNT_ID)) {
    try {
      const d = await graphql(ctx, 'https://api.cloudflare.com/client/v4/graphql', ctx.env.CF_API_TOKEN, QUERY, { acc: ctx.env.CF_ACCOUNT_ID, since: monthStart.toISOString(), until: new Date(ctx.now).toISOString() });
      const rows = (d.viewer?.accounts?.[0]?.workersInvocationsAdaptive ?? []) as Array<{ sum?: { requests?: number } }>;
      const total = rows.reduce((a, r) => a + Number(r.sum?.requests ?? 0), 0);
      out.cfRequests = total;
      await clearError(ctx, ID, 'cloudflare');
      const lv = level(total, numVar(ctx.env.CF_REQUESTS_WARN, 8_000_000), numVar(ctx.env.CF_REQUESTS_STOP, 10_000_000));
      if (lv) current.push(finding(ID, `cost-${lv}`, 'cloudflare-requests', lv, `Cloudflare Workers ${total} requests this month (${lv} threshold)`, { severity: lv === 'stop' ? 'P1' : 'P2', detail: { requests: total } }));
    } catch (e) {
      complete = false;
      await reportError(ctx, ID, 'cloudflare', e);
    }
  } else missing.push('CF_API_TOKEN + CF_ACCOUNT_ID');

  if (missing.length) await reportUnconfigured(ctx, ID, missing.join(' and '));
  for (const kind of ['cost-warn', 'cost-stop']) await settle(ctx, ID, kind, current.filter((f) => f.kind === kind), complete);
  return out;
}
