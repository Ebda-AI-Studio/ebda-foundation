// Cron Triggers (UTC). wrangler.jsonc "triggers.crons" must list exactly these (test/config.test.ts).
// No weekday field anywhere: on Cloudflare 1 = Sunday and 0 is rejected, which silently drops a schedule.
export const CRONS = {
  /** every 5 min: CI inbox -> findings, prod health, questions, urgent dispatch, self-check */
  tick: '*/5 * * * *',
  /** every 15 min (offset 2): services, page-load, journey-monitor, loop-stall, ci-pool */
  quarter: '2-59/15 * * * *',
  /** hourly at :07: dependency / CVE advisories (ETag), KEV refresh at most daily; deploy-drift, pr-shepherd */
  hourly: '7 * * * *',
  /** every 6 h at :17: cf-workers, sentry-stale, cost-guard, world-watch, dr-drill (weekly enqueue gated in KV) */
  sixhourly: '17 */6 * * *',
  /** 21:30 UTC = 23:30 Cairo (EET, UTC+2; 00:30 during Egyptian summer time): the one nightly hands batch */
  nightly: '30 21 * * *',
  /** 05:00 UTC = 07:00 Cairo: the one daily digest */
  digest: '0 5 * * *',
} as const;

export type CronName = keyof typeof CRONS;

export function cronName(expr: string): CronName | null {
  for (const [k, v] of Object.entries(CRONS)) if (v === expr) return k as CronName;
  return null;
}
