// dr-drill watcher (cron, every 6 h; the enqueue itself is gated to once a week): makes sure the restore drill happens and
// that its result stays fresh.
//  - weekly: ONE nightly-lane finding "run restore drill (node scripts/ops/restore-drill.mjs --target api) on ebda-store";
//    the hands pick it up in the nightly batch. Key dr-drill:ebda-store:<ISO year>-W<week> so a week is never enqueued twice; the
//    weekly KV gate is written only AFTER the ingest succeeded (an ingest error means the next run retries).
//  - freshness: a finding when no drill has PASSED for 8 days. Only a hands outcome carrying drill:'pass' (the hands set it from the
//    restore-drill output PASS) counts; a job that merely ended 'done', or a failed drill, leaves the drill stale. Before
//    the first drill ever finished, the age counts from the watcher's first run.
// Config: DR_DRILL_REPO (owner/name of the repo that holds scripts/ops/restore-drill.mjs, default in wrangler.jsonc).
import { finding, isSet, numVar, reportUnconfigured, settle, type WatchCtx } from './common';

export const ID = 'dr-drill';
export const INTERVAL_MS = 7 * 24 * 60 * 60 * 1000;
export const STALE_MS = 8 * 24 * 60 * 60 * 1000;
export const DRILL_TASK = 'run restore drill (node scripts/ops/restore-drill.mjs --target api) on ebda-store';

/** ISO-8601 year-week of a UTC instant, e.g. 2026-W45. */
export function isoWeek(ms: number): string {
  const d = new Date(Date.UTC(new Date(ms).getUTCFullYear(), new Date(ms).getUTCMonth(), new Date(ms).getUTCDate()));
  const day = d.getUTCDay() || 7;
  d.setUTCDate(d.getUTCDate() + 4 - day); // the Thursday of this week decides the ISO year
  const yearStart = Date.UTC(d.getUTCFullYear(), 0, 1);
  return `${d.getUTCFullYear()}-W${String(Math.ceil(((d.getTime() - yearStart) / 86400000 + 1) / 7)).padStart(2, '0')}`;
}

export const WEEKLY_GATE = 'wd:last:dr-drill:weekly';

export async function watchDrDrill(ctx: WatchCtx): Promise<{ enqueued: boolean; stale: boolean }> {
  if (!isSet(ctx.env.DR_DRILL_REPO) || !/^[\w.-]+\/[\w.-]+$/.test(ctx.env.DR_DRILL_REPO)) {
    await reportUnconfigured(ctx, ID, 'DR_DRILL_REPO (owner/name)');
    return { enqueued: false, stale: false };
  }
  const repo = ctx.env.DR_DRILL_REPO;
  let enqueued = false;
  const lastEnqueue = Number((await ctx.env.EVENTS.get(WEEKLY_GATE)) ?? 0);
  if (ctx.now - lastEnqueue >= INTERVAL_MS * 0.9) {
    const week = isoWeek(ctx.now);
    // the gate is written only after the ingest returned: a throw leaves it open and the next 6 h run retries
    await ctx.sink.ingestMany([finding(ID, 'dr-drill', 'ebda-store', week, `Weekly: ${DRILL_TASK}`, { repo, severity: 'P3', detail: { task: DRILL_TASK, repo, week } })], ctx.now);
    await ctx.env.EVENTS.put(WEEKLY_GATE, String(ctx.now));
    enqueued = true;
  }
  const firstKey = 'dr:first-run';
  const first = Number((await ctx.env.EVENTS.get(firstKey)) ?? 0) || ctx.now;
  if (first === ctx.now) await ctx.env.EVENTS.put(firstKey, String(ctx.now));
  const last = (await ctx.sink.lastPassAt('watcher', 'dr-drill')) ?? first;
  const limit = numVar(ctx.env.DR_DRILL_STALE_DAYS, 8) * 86400000 || STALE_MS;
  const stale = ctx.now - last > limit;
  await settle(ctx, ID, 'dr-drill-stale', stale ? [finding(ID, 'dr-drill-stale', 'ebda-store', 'stale', `no restore drill has passed in the last ${Math.round(limit / 86400000)} days`, { repo, severity: 'P2', detail: { lastPassAt: last } })] : []);
  return { enqueued, stale };
}
