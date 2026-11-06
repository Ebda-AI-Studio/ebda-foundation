// dr-drill watcher (cron, every 6 h; the enqueue itself is gated to once a week): makes sure the restore drill happens and
// that its result stays fresh.
//  - weekly: ONE nightly-lane finding "run restore drill (node scripts/ops/restore-drill.mjs --target api) on ebda-store";
//    the hands pick it up in the nightly batch. Key dr-drill:ebda-store:week-<n> so a week is never enqueued twice.
//  - freshness: a finding when no drill job has COMPLETED (hands outcome merged / pr_opened / fix_deployed) for 8 days. Before
//    the first drill ever finished, the age counts from the watcher's first run.
// Config: DR_DRILL_REPO (owner/name of the repo that holds scripts/ops/restore-drill.mjs, default in wrangler.jsonc).
import { finding, isSet, numVar, reportUnconfigured, settle, type WatchCtx } from './common';

export const ID = 'dr-drill';
export const INTERVAL_MS = 7 * 24 * 60 * 60 * 1000;
export const STALE_MS = 8 * 24 * 60 * 60 * 1000;
export const DRILL_TASK = 'run restore drill (node scripts/ops/restore-drill.mjs --target api) on ebda-store';

export async function watchDrDrill(ctx: WatchCtx, weeklyDue: boolean): Promise<{ enqueued: boolean; stale: boolean }> {
  if (!isSet(ctx.env.DR_DRILL_REPO) || !/^[\w.-]+\/[\w.-]+$/.test(ctx.env.DR_DRILL_REPO)) {
    await reportUnconfigured(ctx, ID, 'DR_DRILL_REPO (owner/name)');
    return { enqueued: false, stale: false };
  }
  const repo = ctx.env.DR_DRILL_REPO;
  let enqueued = false;
  if (weeklyDue) {
    const week = Math.floor(ctx.now / INTERVAL_MS);
    await ctx.sink.ingestMany([finding(ID, 'dr-drill', 'ebda-store', `week-${week}`, `Weekly: ${DRILL_TASK}`, { repo, severity: 'P3', detail: { task: DRILL_TASK, repo, week } })], ctx.now);
    enqueued = true;
  }
  const firstKey = 'dr:first-run';
  const first = Number((await ctx.env.EVENTS.get(firstKey)) ?? 0) || ctx.now;
  if (first === ctx.now) await ctx.env.EVENTS.put(firstKey, String(ctx.now));
  const last = (await ctx.sink.lastDoneAt('watcher', 'dr-drill')) ?? first;
  const limit = numVar(ctx.env.DR_DRILL_STALE_DAYS, 8) * 86400000 || STALE_MS;
  const stale = ctx.now - last > limit;
  await settle(ctx, ID, 'dr-drill-stale', stale ? [finding(ID, 'dr-drill-stale', 'ebda-store', 'stale', `no restore drill has completed in the last ${Math.round(limit / 86400000)} days`, { repo, severity: 'P2', detail: { lastDoneAt: last } })] : []);
  return { enqueued, stale };
}
