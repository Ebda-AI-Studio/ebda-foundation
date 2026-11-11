// deploy-drift watcher (cron, hourly): the commit a deployed Ebda service reports on its /health vs the tip of its repo's main.
// Drift = live commit differs from main AND main's tip is older than DEPLOY_DRIFT_GRACE_MIN (default 120 = 2 h), i.e. the merge
// should have been deployed by now. Stateless: the age comes from the commit date. Needs GITHUB_TOKEN (read access to the repos).
// DEPLOY_DRIFT_TARGETS = JSON list of {name, healthUrl, repo:"owner/name", branch?:"main"}.
import { finding, httpJson, isHttps, isObj, isSet, numVar, parseList, reportError, reportUnconfigured, clearError, settle, WatcherError, type WatchCtx } from './common';

export const ID = 'deploy-drift';
export const INTERVAL_MS = 60 * 60 * 1000;

export interface DriftTarget {
  name: string;
  healthUrl: string;
  repo: string;
  branch?: string;
}
const isTarget = (x: unknown): x is DriftTarget =>
  isObj(x) && isHttps(x.healthUrl) && typeof x.name === 'string' && /^[\w.-]{1,40}$/.test(x.name) && typeof x.repo === 'string' && /^[\w.-]+\/[\w.-]+$/.test(x.repo) && (x.branch === undefined || (typeof x.branch === 'string' && /^[\w./-]{1,60}$/.test(x.branch)));

const sameCommit = (a: string, b: string): boolean => {
  const x = a.toLowerCase();
  const y = b.toLowerCase();
  return x.length >= 7 && y.length >= 7 && (x.startsWith(y) || y.startsWith(x));
};

export async function watchDeployDrift(ctx: WatchCtx): Promise<{ checked: number; drifted: string[] }> {
  const targets = parseList(ctx.env.DEPLOY_DRIFT_TARGETS, isTarget, 12);
  if (targets === null || targets.length === 0) {
    await reportUnconfigured(ctx, ID, 'DEPLOY_DRIFT_TARGETS (JSON list of {name,healthUrl,repo})');
    return { checked: 0, drifted: [] };
  }
  if (!isSet(ctx.env.GITHUB_TOKEN)) {
    await reportUnconfigured(ctx, ID, 'GITHUB_TOKEN secret');
    return { checked: 0, drifted: [] };
  }
  const graceMs = numVar(ctx.env.DEPLOY_DRIFT_GRACE_MIN, 120) * 60000;
  const current = [];
  const drifted: string[] = [];
  let complete = true;
  for (const t of targets) {
    try {
      const h = (await httpJson(ctx, t.healthUrl)) as Record<string, unknown>;
      const live = [h.commit, h.sha, h.version, h.deploymentId].find((v): v is string => typeof v === 'string' && /^[0-9a-f]{7,40}$/i.test(v));
      if (!live) throw new WatcherError('/health reports no commit sha');
      const c = (await httpJson(ctx, `https://api.github.com/repos/${t.repo}/commits/${encodeURIComponent(t.branch ?? 'main')}`, { headers: { authorization: `Bearer ${ctx.env.GITHUB_TOKEN}`, 'x-github-api-version': '2022-11-28' } })) as { sha?: unknown; commit?: { committer?: { date?: unknown } } };
      const tip = typeof c.sha === 'string' ? c.sha : '';
      const at = Date.parse(String(c.commit?.committer?.date ?? ''));
      if (!tip || !Number.isFinite(at)) throw new WatcherError('GitHub returned no usable commit');
      await clearError(ctx, ID, t.name);
      if (!sameCommit(live, tip) && ctx.now - at >= graceMs) {
        drifted.push(t.name);
        const hours = Math.round(((ctx.now - at) / 3600000) * 10) / 10;
        current.push(finding(ID, 'deploy-drift', t.name, 'drifted', `${t.name} runs ${live.slice(0, 7)} but ${t.repo}@${t.branch ?? 'main'} is ${tip.slice(0, 7)} (merged ${hours} h ago)`, { repo: t.repo, url: t.healthUrl, severity: 'P2', detail: { live: live.slice(0, 12), tip: tip.slice(0, 12) } }));
      }
    } catch (e) {
      complete = false; // an unreadable target must not resolve its earlier drift finding
      await reportError(ctx, ID, t.name, e);
    }
  }
  await settle(ctx, ID, 'deploy-drift', current, complete);
  return { checked: targets.length, drifted };
}
