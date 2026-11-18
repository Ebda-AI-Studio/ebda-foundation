// Cron entry points of the ten cloud watchers. One function per cron group; each watcher is isolated (an exception in one
// never stops the others and becomes a watcher-error finding) and gated by its own cadence in KV, so a retried or early cron
// cannot run a 6 h watcher twice.
import type { BrainDO } from '../brain-do';
import type { Env } from '../env';
import { due, reportError, unconfiguredIdent, type Sink, type WatchCtx } from './common';
import * as ciCatchup from './ci-catchup';
import * as ciPool from './ci-pool';
import * as cfWorkers from './cf-workers';
import * as cfUsage from './cf-usage';
import * as costGuard from './cost-guard';
import * as deployDrift from './deploy-drift';
import * as drDrill from './dr-drill';
import * as journey from './journey-monitor';
import * as loopStall from './loop-stall';
import * as pageLoad from './page-load';
import * as prShepherd from './pr-shepherd';
import * as sentryStale from './sentry-stale';
import * as services from './services';
import * as world from './world-watch';
import { boundFetch } from '../bound-fetch';

export type WatcherGroup = 'quarter' | 'hourly' | 'sixhourly';

interface Entry {
  id: string;
  intervalMs: number;
  run: (ctx: WatchCtx) => Promise<unknown>;
}

export const GROUPS: Record<WatcherGroup, Entry[]> = {
  quarter: [
    { id: services.ID, intervalMs: services.INTERVAL_MS, run: services.watchServices },
    { id: pageLoad.ID, intervalMs: pageLoad.INTERVAL_MS, run: pageLoad.watchPageLoad },
    { id: journey.ID, intervalMs: journey.INTERVAL_MS, run: journey.watchJourneys },
    { id: loopStall.ID, intervalMs: loopStall.INTERVAL_MS, run: loopStall.watchLoopStall },
    { id: ciPool.ID, intervalMs: ciPool.INTERVAL_MS, run: ciPool.watchCiPool },
  ],
  hourly: [
    { id: deployDrift.ID, intervalMs: deployDrift.INTERVAL_MS, run: deployDrift.watchDeployDrift },
    { id: prShepherd.ID, intervalMs: prShepherd.INTERVAL_MS, run: prShepherd.watchPrShepherd },
    { id: ciCatchup.ID, intervalMs: ciCatchup.INTERVAL_MS, run: ciCatchup.watchCiCatchup },
  ],
  sixhourly: [
    { id: cfWorkers.ID, intervalMs: cfWorkers.INTERVAL_MS, run: cfWorkers.watchCfWorkers },
    { id: sentryStale.ID, intervalMs: sentryStale.INTERVAL_MS, run: sentryStale.watchSentryStale },
    { id: cfUsage.ID, intervalMs: cfUsage.INTERVAL_MS, run: cfUsage.watchCfUsage },
    { id: costGuard.ID, intervalMs: costGuard.INTERVAL_MS, run: costGuard.watchCostGuard },
    { id: world.ID, intervalMs: world.INTERVAL_MS, run: world.watchWorld },
    // the freshness check runs every time, the weekly enqueue only when its own weekly KV gate (written after the ingest) opens
    { id: drDrill.ID, intervalMs: 0, run: drDrill.watchDrDrill },
  ],
};

export async function runWatchers(group: WatcherGroup, env: Env, brain: DurableObjectStub<BrainDO> | Sink, now: number, fetchImpl: typeof fetch = boundFetch): Promise<Record<string, 'ran' | 'skipped' | 'error'>> {
  const ctx: WatchCtx = { env, sink: brain as Sink, now, fetchImpl };
  const out: Record<string, 'ran' | 'skipped' | 'error'> = {};
  for (const w of GROUPS[group]) {
    try {
      if (w.intervalMs > 0 && !(await due(ctx, w.id, w.intervalMs))) {
        out[w.id] = 'skipped';
        continue;
      }
      const wctx: WatchCtx = { ...ctx, configGaps: new Set() };
      await w.run(wctx);
      // N-1: a watcher that ran WITHOUT a config gap has its config now; close the earlier "not running" note, or the post-deploy
      // cutover gate (--deployed) could never clear. (A thrown failure skips this: that says nothing about config.)
      if (!wctx.configGaps!.has(w.id)) await ctx.sink.resolveFinding(unconfiguredIdent(w.id), 'configured', now).catch(() => undefined);
      out[w.id] = 'ran';
    } catch (e) {
      out[w.id] = 'error';
      console.error('watcher failed', w.id, (e as Error).message);
      await reportError(ctx, w.id, 'run', e).catch(() => undefined);
    }
  }
  return out;
}
