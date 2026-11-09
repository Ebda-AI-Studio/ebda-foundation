// dr-drill watcher (cron, every 6 h): checks that the weekly restore drill stays fresh. It does NOT run or enqueue the drill
// (ruling F-I6): the drill needs the R2 + age secrets the hands container must not hold, so it runs on the Mac
// (ops/restore-drill.sh, weekly, mac-local) and posts its PASS/FAIL to the brain (POST /drill).
//  - no PASS for DR_DRILL_STALE_DAYS (8): `dr-drill-stale`, digest lane (no job, no message).
//  - no PASS for DR_DRILL_OVERDUE_DAYS (14): `dr-drill-overdue`, ONE unhealed-P1 message: the Mac has not run the drill, a decision for Ahmad.
//  Before the first drill ever passed, the age counts from the watcher's first run.
// Config: DR_DRILL_REPO (owner/name of the repo holding the drill script; names the finding, default in wrangler.jsonc).
import { finding, isSet, numVar, reportUnconfigured, settle, type WatchCtx } from './common';

export const ID = 'dr-drill';
export const INTERVAL_MS = 6 * 60 * 60 * 1000;
export const STALE_MS = 8 * 24 * 60 * 60 * 1000;
export const OVERDUE_MS = 14 * 24 * 60 * 60 * 1000;

/** ISO-8601 year-week of a UTC instant, e.g. 2026-W45. */
export function isoWeek(ms: number): string {
  const d = new Date(Date.UTC(new Date(ms).getUTCFullYear(), new Date(ms).getUTCMonth(), new Date(ms).getUTCDate()));
  const day = d.getUTCDay() || 7;
  d.setUTCDate(d.getUTCDate() + 4 - day); // the Thursday of this week decides the ISO year
  const yearStart = Date.UTC(d.getUTCFullYear(), 0, 1);
  return `${d.getUTCFullYear()}-W${String(Math.ceil(((d.getTime() - yearStart) / 86400000 + 1) / 7)).padStart(2, '0')}`;
}

export async function watchDrDrill(ctx: WatchCtx): Promise<{ stale: boolean; overdue: boolean }> {
  if (!isSet(ctx.env.DR_DRILL_REPO) || !/^[\w.-]+\/[\w.-]+$/.test(ctx.env.DR_DRILL_REPO)) {
    await reportUnconfigured(ctx, ID, 'DR_DRILL_REPO (owner/name)');
    return { stale: false, overdue: false };
  }
  const repo = ctx.env.DR_DRILL_REPO;
  const firstKey = 'dr:first-run';
  const first = Number((await ctx.env.EVENTS.get(firstKey)) ?? 0) || ctx.now;
  if (first === ctx.now) await ctx.env.EVENTS.put(firstKey, String(ctx.now));
  const last = (await ctx.sink.lastPassAt('watcher', 'dr-drill')) ?? first;
  const staleDays = numVar(ctx.env.DR_DRILL_STALE_DAYS, 8);
  const limit = staleDays * 86400000 || STALE_MS;
  const overdueLimit = Math.max(OVERDUE_MS, limit);
  const age = ctx.now - last;
  const stale = age > limit && age <= overdueLimit;
  const overdue = age > overdueLimit;
  const days = Math.floor(age / 86400000);
  await settle(ctx, ID, 'dr-drill-stale', stale ? [finding(ID, 'dr-drill-stale', 'ebda-store', 'stale', `no restore drill has passed in ${days} days (the Mac runs it weekly)`, { repo, severity: 'P3', detail: { lastPassAt: last } })] : []);
  await settle(ctx, ID, 'dr-drill-overdue', overdue ? [finding(ID, 'dr-drill-overdue', 'ebda-store', 'overdue', `no restore drill has passed in ${days} days: run ops/restore-drill.sh on the Mac`, { repo, severity: 'P1', detail: { lastPassAt: last } })] : []);
  return { stale, overdue };
}
