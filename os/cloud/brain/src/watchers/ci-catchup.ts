// ci-catchup watcher (cron, hourly): the GitHub webhook is the fast path for CI results, but GitHub does not redeliver after a
// failed delivery and the relay drops events older than an hour (replay guard), so a brain outage longer than that loses a red CI for
// good. This reads the newest COMPLETED run per workflow on each hands-mapped repo's default branch and replays it through the same
// two doors as the webhook: red -> ingestCiEvent (deduped by run id + attempt, then the 5-minute tick raises the finding), green ->
// resolveCi (deduped by the same key, M-3). Idempotent: a run the webhook already delivered changes nothing.
import type { CiEventInput } from '../brain-do';
import { httpJson, isObj, isSet, reportError, reportUnconfigured, clearError, type Sink, type WatchCtx } from './common';

export const ID = 'ci-catchup';
export const INTERVAL_MS = 60 * 60 * 1000;
const MAX_REPOS = 20;
/** Only runs this recent matter: an older red that is still red will be re-run or re-pushed by a human anyway. */
const MAX_AGE_MS = 48 * 60 * 60 * 1000;

/** The slice of the brain this watcher writes to (a DurableObjectStub satisfies it). */
export interface CiSink extends Sink {
  ingestCiEvent(ev: CiEventInput): Promise<boolean> | boolean;
  resolveCi(slug: string, workflow: string, runKey: string, now?: number): Promise<boolean>;
}

function reposFrom(json: string | undefined): string[] {
  try {
    const repos = (JSON.parse(String(json)) as { repos?: Record<string, unknown> }).repos;
    return repos && typeof repos === 'object' ? Object.keys(repos).filter((r) => /^[\w.-]+\/[\w.-]+$/.test(r)).slice(0, MAX_REPOS) : [];
  } catch {
    return [];
  }
}

export async function watchCiCatchup(ctx: WatchCtx): Promise<{ repos: number; red: number; green: number }> {
  const repos = reposFrom(ctx.env.HANDS_CONFIG_JSON);
  if (!repos.length) {
    await reportUnconfigured(ctx, ID, 'HANDS_CONFIG_JSON (the repos the hands can fix)');
    return { repos: 0, red: 0, green: 0 };
  }
  if (!isSet(ctx.env.GITHUB_TOKEN)) {
    await reportUnconfigured(ctx, ID, 'GITHUB_TOKEN secret');
    return { repos: 0, red: 0, green: 0 };
  }
  const sink = ctx.sink as CiSink;
  const headers = { authorization: `Bearer ${ctx.env.GITHUB_TOKEN}`, accept: 'application/vnd.github+json', 'x-github-api-version': '2022-11-28' };
  let red = 0;
  let green = 0;
  for (const slug of repos) {
    try {
      const repo = (await httpJson(ctx, `https://api.github.com/repos/${slug}`, { headers })) as { default_branch?: unknown };
      const branch = typeof repo?.default_branch === 'string' ? repo.default_branch : '';
      if (!/^[\w./-]{1,100}$/.test(branch)) continue;
      const list = (await httpJson(ctx, `https://api.github.com/repos/${slug}/actions/runs?branch=${encodeURIComponent(branch)}&status=completed&per_page=30`, { headers })) as { workflow_runs?: unknown };
      const runs = Array.isArray(list?.workflow_runs) ? list.workflow_runs.filter(isObj) : [];
      // newest completed run per workflow
      const newest = new Map<string, Record<string, unknown>>();
      for (const r of runs) {
        const name = String(r.name ?? '');
        const t = Date.parse(String(r.updated_at ?? ''));
        if (!name || !Number.isFinite(t) || ctx.now - t > MAX_AGE_MS) continue;
        const cur = newest.get(name);
        if (!cur || t > Date.parse(String(cur.updated_at))) newest.set(name, r);
      }
      for (const [name, r] of newest) {
        const runKey = `${r.id}-${r.run_attempt ?? 1}`;
        if (r.conclusion === 'success') {
          green++;
          await sink.resolveCi(slug, name, runKey, ctx.now);
        } else if (r.conclusion === 'failure' || r.conclusion === 'timed_out') {
          red++;
          await sink.ingestCiEvent({ id: runKey, slug, sha: String(r.head_sha ?? ''), workflow: name, branch, defaultBranch: branch, url: String(r.html_url ?? ''), ts: Date.parse(String(r.updated_at)) });
        }
      }
      await clearError(ctx, ID, slug);
    } catch (e) {
      await reportError(ctx, ID, slug, e);
    }
  }
  return { repos: repos.length, red, green };
}
