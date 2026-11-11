// loop-stall watcher (cron, every 15 min): the brain-side backstop of the controller's loop-watchdog (ruling LOOP-WATCH-1).
// It depends on no session, no laptop and no launchd job: if the controller's alert listener or drain dies, the brain still
// escalates ONCE to Ahmad (kind in ALERT_KINDS = one deduped P1 message, resolved when the condition clears). Per repo in
// HANDS_CONFIG_JSON (the repos the OS watches), on the default branch:
//   loop-main-red     the newest CI run is red and the red streak started more than LOOP_RED_MIN (30) minutes ago;
//   loop-merge-stall  open PRs carry `ai-review-passed` (and not `hold`) but nothing merged for LOOP_STALL_MIN (60) minutes.
// Keys carry the incident (first red run id / last merge time), so a new incident is a new alert and a long one stays one.
// 3 GitHub reads per repo. An API failure is a watcher-error finding, never "healthy".
import { httpJson, isObj, isSet, numVar, reportError, reportUnconfigured, clearError, finding, settle, type WatchCtx } from './common';
import { reposFrom } from './ci-catchup';

export const ID = 'loop-stall';
export const INTERVAL_MS = 15 * 60 * 1000;
const MIN = 60_000;

export async function watchLoopStall(ctx: WatchCtx): Promise<{ repos: number; red: number; stalled: number }> {
  const repos = reposFrom(ctx.env.HANDS_CONFIG_JSON);
  if (!repos.length) {
    await reportUnconfigured(ctx, ID, 'HANDS_CONFIG_JSON (the repos the hands can fix)');
    return { repos: 0, red: 0, stalled: 0 };
  }
  if (!isSet(ctx.env.GITHUB_TOKEN)) {
    await reportUnconfigured(ctx, ID, 'GITHUB_TOKEN secret');
    return { repos: 0, red: 0, stalled: 0 };
  }
  const redMs = numVar(ctx.env.LOOP_RED_MIN, 30) * MIN;
  const stallMs = numVar(ctx.env.LOOP_STALL_MIN, 60) * MIN;
  const headers = { authorization: `Bearer ${ctx.env.GITHUB_TOKEN}`, accept: 'application/vnd.github+json', 'x-github-api-version': '2022-11-28' };
  const reds = [];
  const stalls = [];
  let complete = true;
  for (const slug of repos) {
    try {
      const api = `https://api.github.com/repos/${slug}`;
      const runsRes = (await httpJson(ctx, `${api}/actions/runs?branch=main&status=completed&per_page=20`, { headers })) as { workflow_runs?: unknown };
      const runs = (Array.isArray(runsRes?.workflow_runs) ? runsRes.workflow_runs.filter(isObj) : [])
        .filter((r) => String(r.name ?? '') === 'CI' && Number.isFinite(Date.parse(String(r.updated_at ?? ''))))
        .sort((a, b) => Date.parse(String(b.updated_at)) - Date.parse(String(a.updated_at)));
      const isRed = (r: Record<string, unknown>) => r.conclusion === 'failure' || r.conclusion === 'timed_out';
      if (runs[0] && isRed(runs[0])) {
        // start of the unbroken red streak = the oldest consecutive red run; success ends it, a cancelled run is skipped
        let first = runs[0];
        for (const r of runs) {
          if (isRed(r)) first = r;
          else if (r.conclusion === 'success') break;
        }
        const since = Date.parse(String(first.updated_at));
        if (ctx.now - since > redMs) {
          reds.push(finding(ID, 'loop-main-red', slug, `red-${first.id}`, `main CI of ${slug} has been red for ${Math.round((ctx.now - since) / MIN)} min (since run ${first.id})`, { repo: slug, url: String(first.html_url ?? ''), severity: 'P1', detail: { sinceRun: Number(first.id), minutes: Math.round((ctx.now - since) / MIN) } }));
        }
      }
      const prs = (await httpJson(ctx, `${api}/pulls?state=open&per_page=100`, { headers })) as unknown;
      const approved = (Array.isArray(prs) ? prs.filter(isObj) : []).filter((p) => {
        const names = (Array.isArray(p.labels) ? p.labels : []).map((l) => (isObj(l) ? String(l.name) : ''));
        return p.draft !== true && names.includes('ai-review-passed') && !names.includes('hold');
      }).length;
      if (approved > 0) {
        const closed = (await httpJson(ctx, `${api}/pulls?state=closed&sort=updated&direction=desc&per_page=30`, { headers })) as unknown;
        const merged = (Array.isArray(closed) ? closed.filter(isObj) : []).map((p) => Date.parse(String(p.merged_at ?? ''))).filter(Number.isFinite);
        const last = merged.length ? Math.max(...merged) : 0;
        // no merge in the last 30 closed PRs at all: age is unknown, do not guess an incident
        if (last > 0 && ctx.now - last > stallMs) {
          stalls.push(finding(ID, 'loop-merge-stall', slug, `since-${last}`, `no merge in ${slug} for ${Math.round((ctx.now - last) / MIN)} min while ${approved} approved PR(s) wait`, { repo: slug, severity: 'P1', detail: { approved, minutes: Math.round((ctx.now - last) / MIN) } }));
        }
      }
      await clearError(ctx, ID, slug);
    } catch (e) {
      complete = false;
      await reportError(ctx, ID, slug, e);
    }
  }
  await settle(ctx, ID, 'loop-main-red', reds, complete);
  await settle(ctx, ID, 'loop-merge-stall', stalls, complete);
  return { repos: repos.length, red: reds.length, stalled: stalls.length };
}
