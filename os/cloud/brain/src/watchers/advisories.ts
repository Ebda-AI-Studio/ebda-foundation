// Dependency / CVE advisory watcher (cron, at most hourly). Reads open Dependabot alerts per org through the GitHost
// interface with If-None-Match (a 304 is free against the rate limit), tags CISA-KEV CVEs, and feeds the findings to the
// brain. A complete listing also resolves findings whose alert is gone (fixed or dismissed upstream).
import type { BrainDO } from '../brain-do';
import type { Env } from '../env';
import { isPlaceholder } from '../env';
import { GitHubHost, loadKev, type GitHost } from '../githost';

export const ADVISORY_MIN_INTERVAL_MS = 55 * 60 * 1000;

export function orgsFrom(env: Pick<Env, 'OS_ORGS'>): string[] {
  if (isPlaceholder(env.OS_ORGS)) return [];
  return env.OS_ORGS.split(/[\s,]+/).filter(Boolean).slice(0, 10);
}

/** Repos whose code is deployed (owner/name), from the DEPLOYED_REPOS var rendered by deploy.sh. */
export function deployedReposFrom(env: Pick<Env, 'DEPLOYED_REPOS'>): Set<string> {
  if (isPlaceholder(env.DEPLOYED_REPOS)) return new Set();
  return new Set((env.DEPLOYED_REPOS ?? '').split(/[\s,]+/).filter(Boolean));
}

export interface AdvisoryRunSummary {
  at: number;
  skipped?: string;
  orgs: Array<{ org: string; notModified?: boolean; alerts?: number; raised?: number; resolved?: number; error?: string }>;
}

export async function watchAdvisories(env: Env, brain: DurableObjectStub<BrainDO>, now: number, fetchImpl: typeof fetch = fetch, host?: GitHost): Promise<AdvisoryRunSummary> {
  const summary: AdvisoryRunSummary = { at: now, orgs: [] };
  const last = Number((await env.EVENTS.get('adv:last-run')) ?? 0);
  if (now - last < ADVISORY_MIN_INTERVAL_MS) return { ...summary, skipped: 'ran less than an hour ago' };
  if (!env.GITHUB_TOKEN && !host) {
    summary.skipped = 'GITHUB_TOKEN secret unset';
    await brain.setMetaPublic('advisories:last', summary);
    return summary;
  }
  await env.EVENTS.put('adv:last-run', String(now));
  const kev = await loadKev(env.EVENTS, now, fetchImpl);
  const gh = host ?? new GitHubHost(env.GITHUB_TOKEN!, fetchImpl);
  const deployed = deployedReposFrom(env);
  for (const org of orgsFrom(env)) {
    const cacheKey = `adv:etag:${org}`;
    const cached = await env.EVENTS.get<{ etag: string | null; kevSize: number }>(cacheKey, 'json');
    // a changed KEV list can change urgency without the alert list changing: re-read in full then
    const etag = cached && cached.kevSize === kev.size ? cached.etag : null;
    try {
      const page = await gh.openDependencyAlerts(org, etag, kev, deployed);
      if (page.notModified) {
        summary.orgs.push({ org, notModified: true });
        continue;
      }
      const r = await brain.ingestMany(page.alerts, now);
      const resolved = page.complete ? await brain.reconcile('advisory', 'dependency-advisory', `${org}/`, page.alerts.map((a) => a.key), now) : 0;
      await env.EVENTS.put(cacheKey, JSON.stringify({ etag: page.etag, kevSize: kev.size }));
      summary.orgs.push({ org, alerts: page.alerts.length, raised: r.raised, resolved });
    } catch (e) {
      summary.orgs.push({ org, error: (e as Error).message.slice(0, 200) });
    }
  }
  await brain.setMetaPublic('advisories:last', summary);
  return summary;
}
