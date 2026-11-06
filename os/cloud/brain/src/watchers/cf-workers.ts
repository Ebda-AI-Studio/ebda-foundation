// cf-workers watcher (cron, every 6 h): the Ebda Workers on the personal Cloudflare account. Lists the account's scripts
// (REST) and reads each one's request/error counts for the last 6 h (GraphQL analytics, workersInvocationsAdaptive).
// Flags a Worker whose error rate exceeds CF_WORKER_ERROR_RATE (default 0.05, at least 20 requests) and, when
// CF_WORKERS_EXPECTED is set, an expected Worker that no longer exists on the account.
// Only Workers whose name starts with a CF_WORKERS_PREFIXES entry (default "ebda-") are looked at: the account also hosts
// other businesses' Workers and those are not this watcher's business.
// Needs CF_API_TOKEN (secret, Account Analytics:Read + Workers Scripts:Read) and CF_ACCOUNT_ID (var).
// Not covered: a failed Workers Builds deploy is not visible through these APIs; the CI watcher (cf-deploy workflow) owns that.
import { clearError, finding, graphql, httpJson, isSet, numVar, reportError, reportUnconfigured, settle, WatcherError, type WatchCtx } from './common';

export const ID = 'cf-workers';
export const INTERVAL_MS = 6 * 60 * 60 * 1000;
const API = 'https://api.cloudflare.com/client/v4';
const QUERY = `query($acc:String!,$since:Time!,$until:Time!){viewer{accounts(filter:{accountTag:$acc}){workersInvocationsAdaptive(limit:200,filter:{datetime_geq:$since,datetime_leq:$until}){sum{requests errors} dimensions{scriptName}}}}}`;

const list = (v: string | undefined, fallback: string[]): string[] => (isSet(v) ? v.split(/[\s,]+/).filter(Boolean).slice(0, 50) : fallback);

/** Cloudflare REST envelope: `success:false` with HTTP 200 is a failure. */
export async function cfRest(ctx: WatchCtx, path: string): Promise<unknown> {
  const j = (await httpJson(ctx, `${API}${path}`, { headers: { authorization: `Bearer ${ctx.env.CF_API_TOKEN}` } })) as { success?: unknown; result?: unknown; errors?: Array<{ message?: unknown }> } | null;
  if (!j || j.success !== true) throw new WatcherError(`Cloudflare API error${typeof j?.errors?.[0]?.message === 'string' ? `: ${j.errors[0].message.slice(0, 100)}` : ''}`);
  return j.result;
}

export async function watchCfWorkers(ctx: WatchCtx): Promise<{ workers: number; flagged: string[] }> {
  if (!isSet(ctx.env.CF_API_TOKEN) || !isSet(ctx.env.CF_ACCOUNT_ID)) {
    await reportUnconfigured(ctx, ID, 'CF_API_TOKEN secret and CF_ACCOUNT_ID');
    return { workers: 0, flagged: [] };
  }
  const acc = ctx.env.CF_ACCOUNT_ID;
  if (!/^[0-9a-f]{32}$/i.test(acc)) {
    await reportError(ctx, ID, 'config', new WatcherError('CF_ACCOUNT_ID is not a 32 hex account id'));
    return { workers: 0, flagged: [] };
  }
  const prefixes = list(ctx.env.CF_WORKERS_PREFIXES, ['ebda-']);
  const mine = (n: string) => prefixes.some((p) => n.startsWith(p));
  const rate = numVar(ctx.env.CF_WORKER_ERROR_RATE, 0.05);
  try {
    const scripts = ((await cfRest(ctx, `/accounts/${acc}/workers/scripts`)) as Array<{ id?: unknown }>).map((s) => String(s.id ?? '')).filter(mine);
    const d = await graphql(ctx, `${API}/graphql`, ctx.env.CF_API_TOKEN, QUERY, { acc, since: new Date(ctx.now - INTERVAL_MS).toISOString(), until: new Date(ctx.now).toISOString() });
    const rows = (d.viewer?.accounts?.[0]?.workersInvocationsAdaptive ?? []) as Array<{ sum?: { requests?: number; errors?: number }; dimensions?: { scriptName?: string } }>;
    const tally = new Map<string, { req: number; err: number }>();
    for (const r of rows) {
      const n = String(r.dimensions?.scriptName ?? '');
      if (!mine(n)) continue;
      const t = tally.get(n) ?? { req: 0, err: 0 };
      t.req += Number(r.sum?.requests ?? 0);
      t.err += Number(r.sum?.errors ?? 0);
      tally.set(n, t);
    }
    await clearError(ctx, ID, 'cloudflare');
    const current = [];
    const flagged: string[] = [];
    for (const [n, t] of tally) {
      if (t.req >= 20 && t.err / t.req > rate) {
        flagged.push(n);
        current.push(finding(ID, 'cf-worker', n, 'errors', `Worker ${n}: ${t.err}/${t.req} requests errored in the last 6 h`, { severity: 'P2', detail: { requests: t.req, errors: t.err, rate } }));
      }
    }
    for (const n of list(ctx.env.CF_WORKERS_EXPECTED, [])) {
      if (!scripts.includes(n)) {
        flagged.push(n);
        current.push(finding(ID, 'cf-worker', n, 'missing', `Worker ${n} is expected but not on the Cloudflare account`, { severity: 'P1' }));
      }
    }
    await settle(ctx, ID, 'cf-worker', current);
    return { workers: scripts.length, flagged };
  } catch (e) {
    await reportError(ctx, ID, 'cloudflare', e);
    return { workers: 0, flagged: [] };
  }
}
