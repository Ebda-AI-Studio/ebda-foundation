// ci-pool watcher (cron, every 15 min): the Cloudflare-side signal for "the Mac runner pool is down or stuck" (ruling NO-HOSTED-RUNNERS-1).
// With no GitHub-hosted fallback, a Mac outage silences every in-workflow alert (notify-failure runs on the same pool), so the brain, which runs
// off the Macs, watches for it. Per repo in HANDS_CONFIG_JSON: a run has been QUEUED for more than CI_QUEUE_MIN (60) minutes AND no run of the
// repo is in progress at all => `ci-pool-stall` (one deduped P1, keyed by the oldest queued run, resolved when something starts). Queued runs
// OLDER than CI_QUEUE_MAX_MIN (360) are ghosts (HELD-RERUN-1 measured runs queued for hours that no runner ever takes) and are ignored when
// picking the oldest, so one ghost at a quiet hour cannot page every night. A busy pool
// with a long queue (runs in progress) is saturation, not an outage, and does not alert. 2 GitHub reads per repo. An API failure is a
// watcher-error finding, never "healthy". The runners API itself needs an org admin scope the brain's read token does not carry, so this
// reads run state only.
import { httpJson, isObj, isSet, numVar, reportError, reportUnconfigured, clearError, finding, settle, type WatchCtx } from './common';
import { reposFrom } from './ci-catchup';

export const ID = 'ci-pool';
export const INTERVAL_MS = 15 * 60 * 1000;
const MIN = 60_000;

export async function watchCiPool(ctx: WatchCtx): Promise<{ repos: number; stalled: number }> {
  const repos = reposFrom(ctx.env.HANDS_CONFIG_JSON);
  if (!repos.length) {
    await reportUnconfigured(ctx, ID, 'HANDS_CONFIG_JSON (the repos the hands can fix)');
    return { repos: 0, stalled: 0 };
  }
  if (!isSet(ctx.env.GITHUB_TOKEN)) {
    await reportUnconfigured(ctx, ID, 'GITHUB_TOKEN secret');
    return { repos: 0, stalled: 0 };
  }
  const queueMs = numVar(ctx.env.CI_QUEUE_MIN, 60) * MIN;
  const ghostMs = numVar(ctx.env.CI_QUEUE_MAX_MIN, 360) * MIN;
  const headers = { authorization: `Bearer ${ctx.env.GITHUB_TOKEN}`, accept: 'application/vnd.github+json', 'x-github-api-version': '2022-11-28' };
  const stalls = [];
  let complete = true;
  for (const slug of repos) {
    try {
      const api = `https://api.github.com/repos/${slug}/actions/runs`;
      const queued = (await httpJson(ctx, `${api}?status=queued&per_page=100`, { headers })) as { workflow_runs?: unknown };
      const waiting = (Array.isArray(queued?.workflow_runs) ? queued.workflow_runs.filter(isObj) : [])
        .map((r) => ({ id: r.id, at: Date.parse(String(r.created_at ?? '')) }))
        .filter((r) => Number.isFinite(r.at) && ctx.now - r.at <= ghostMs)
        .sort((a, b) => a.at - b.at);
      if (waiting[0] && ctx.now - waiting[0].at > queueMs) {
        const running = (await httpJson(ctx, `${api}?status=in_progress&per_page=1`, { headers })) as { total_count?: unknown };
        if (typeof running?.total_count !== 'number') throw new Error('in_progress count missing from the runs response');
        if (running.total_count === 0) {
          stalls.push(finding(ID, 'ci-pool-stall', slug, `queued-${waiting[0].id}`, `${slug}: a CI run has been queued for ${Math.round((ctx.now - waiting[0].at) / MIN)} min and nothing is running (the Mac runner pool may be down)`, { repo: slug, severity: 'P1', detail: { queued: waiting.length, oldestRun: waiting[0].id } }));
        }
      }
      await clearError(ctx, ID, slug);
    } catch (e) {
      complete = false;
      await reportError(ctx, ID, slug, e);
    }
  }
  await settle(ctx, ID, 'ci-pool-stall', stalls, complete);
  return { repos: repos.length, stalled: stalls.length };
}
