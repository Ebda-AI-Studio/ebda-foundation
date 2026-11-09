// cf-usage watcher (daily, F-05): the products that bill and that nothing else measures: Durable Objects (requests, rows written), KV
// (writes), Containers (vCPU-seconds) and Workers requests, read from the Cloudflare GraphQL Analytics API for the last 24 h.
//  - Thresholds are per DAY (CF_CONTAINER_VCPU_MIN_DAY, CF_DO_REQUESTS_DAY, CF_KV_WRITES_DAY): warn at 50 %, STOP at 100 %. A stop is a
//    `cf-usage-stop` finding, which halts the hands (F-01) and sends ONE p1 message; a warn is a digest item.
//  - The last reading is stored as the digest's "Footprint (24 h)" line. A dataset that is missing, a GraphQL 200 + `errors`, or a
//    network failure is a watcher-error and the footprint is `unknown`; it is NEVER recorded as 0.
// Dataset and field names follow the Cloudflare docs; they are NOT VERIFIED against a live account (ruling RR-cf-usage): the first
// deploy must show a real footprint line, and `unknown` there means a field name needs fixing, not that usage is zero.
import { clearError, finding, graphql, isSet, numVar, reportError, reportUnconfigured, settle, type WatchCtx } from './common';

export const ID = 'cf-usage';
export const INTERVAL_MS = 24 * 60 * 60 * 1000;
const GQL = 'https://api.cloudflare.com/client/v4/graphql';

/** Included Workers Paid amounts, pro-rated per day (estimate; tune with the CF_* vars). */
export const DEFAULTS = { containerVcpuMin: 12.5, doRequests: 33_000, kvWrites: 33_000 };

const q = (dataset: string, sum: string, extraFilter = '') => `query($acc:String!,$since:Time!,$until:Time!){viewer{accounts(filter:{accountTag:$acc}){${dataset}(limit:1000,filter:{datetime_geq:$since,datetime_leq:$until${extraFilter}}){sum{${sum}}}}}}`;

async function total(ctx: WatchCtx, dataset: string, sum: string, extraFilter = ''): Promise<number> {
  const d = await graphql(ctx, GQL, ctx.env.CF_API_TOKEN!, q(dataset, sum, extraFilter), { acc: ctx.env.CF_ACCOUNT_ID, since: new Date(ctx.now - 24 * 3600_000).toISOString(), until: new Date(ctx.now).toISOString() });
  const rows = d.viewer?.accounts?.[0]?.[dataset];
  if (!Array.isArray(rows)) throw new Error(`dataset ${dataset} missing from the answer`);
  return rows.reduce((a: number, r: { sum?: Record<string, number> }) => a + Number(r.sum?.[sum] ?? 0), 0);
}

export async function watchCfUsage(ctx: WatchCtx): Promise<{ footprint: Record<string, number | null> }> {
  if (!isSet(ctx.env.CF_API_TOKEN) || !isSet(ctx.env.CF_ACCOUNT_ID)) {
    await reportUnconfigured(ctx, ID, 'CF_API_TOKEN + CF_ACCOUNT_ID');
    return { footprint: {} };
  }
  const reads: Array<[string, () => Promise<number>]> = [
    ['doRequests', () => total(ctx, 'durableObjectsInvocationsAdaptiveGroups', 'requests')],
    ['doRowsWritten', () => total(ctx, 'durableObjectsPeriodicGroups', 'rowsWritten')],
    ['kvWrites', () => total(ctx, 'kvOperationsAdaptiveGroups', 'requests', ',actionType:"write"')],
    ['containerVcpuSec', () => total(ctx, 'containersUsageAdaptiveGroups', 'cpuTimeSec')],
    ['workersRequests', () => total(ctx, 'workersInvocationsAdaptive', 'requests')],
  ];
  const got: Record<string, number | null> = {};
  const failed: string[] = [];
  for (const [name, read] of reads) {
    try {
      got[name] = await read();
      await clearError(ctx, ID, name);
    } catch (e) {
      got[name] = null;
      failed.push(name);
      await reportError(ctx, ID, name, e);
    }
  }
  const sink = ctx.sink as unknown as { recordFootprint?: (f: Record<string, unknown>) => Promise<void> | void };
  if (failed.length) {
    await sink.recordFootprint?.({ at: ctx.now, unknown: true, note: `could not read ${failed.join(', ')}` });
  } else {
    await sink.recordFootprint?.({ at: ctx.now, unknown: false, containerMin: (got.containerVcpuSec ?? 0) / 30 /* vCPU-s -> container-min at 1/2 vCPU */, doRequests: got.doRequests, doRowsWritten: got.doRowsWritten, kvWrites: got.kvWrites, workersRequests: got.workersRequests });
  }
  const limits: Array<[string, number | null, number, string]> = [
    ['do-requests', got.doRequests ?? null, numVar(ctx.env.CF_DO_REQUESTS_DAY, DEFAULTS.doRequests), 'Durable Object requests'],
    ['kv-writes', got.kvWrites ?? null, numVar(ctx.env.CF_KV_WRITES_DAY, DEFAULTS.kvWrites), 'KV writes'],
    ['container-vcpu', got.containerVcpuSec == null ? null : got.containerVcpuSec / 60, numVar(ctx.env.CF_CONTAINER_VCPU_MIN_DAY, DEFAULTS.containerVcpuMin), 'container vCPU-minutes'],
  ];
  const current = [];
  for (const [key, value, limit, label] of limits) {
    if (value === null) continue; // unknown is a watcher-error, never "under the limit"
    const lv = value >= limit ? 'stop' : value >= 0.5 * limit ? 'warn' : null;
    if (lv) current.push(finding(ID, `cf-usage-${lv}`, key, lv, `Cloudflare ${label}: ${Math.round(value)} in 24 h (${lv} at ${lv === 'stop' ? limit : Math.round(limit / 2)})`, { severity: lv === 'stop' ? 'P1' : 'P3' }));
  }
  const complete = failed.length === 0;
  for (const kind of ['cf-usage-warn', 'cf-usage-stop']) await settle(ctx, ID, kind, current.filter((f) => f.kind === kind), complete);
  return { footprint: got };
}
