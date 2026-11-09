// sentry-stale watcher (cron, every 6 h): unresolved Sentry issues of the Ebda projects that were first seen more than 72 h
// ago AND still produced events in the last 24 h, i.e. a known bug nobody closed that is still hurting. Sentry search:
// `is:unresolved age:+72h lastSeen:-24h`. Needs SENTRY_AUTH_TOKEN (secret, project:read), SENTRY_ORG and SENTRY_PROJECTS
// (comma list of project slugs); SENTRY_BASE_URL (default https://sentry.io) for a regional host.
// Key `sentry-stale:<project>/<issue id>:stale`; an issue that is resolved or goes quiet resolves its finding.
import { clearError, finding, httpJson, isHttps, isSet, reportError, reportUnconfigured, settle, WatcherError, type WatchCtx } from './common';

export const ID = 'sentry-stale';
export const INTERVAL_MS = 6 * 60 * 60 * 1000;
const QUERY = encodeURIComponent('is:unresolved age:+72h lastSeen:-24h');

export async function watchSentryStale(ctx: WatchCtx): Promise<{ projects: number; stale: number }> {
  if (!isSet(ctx.env.SENTRY_AUTH_TOKEN) || !isSet(ctx.env.SENTRY_ORG) || !isSet(ctx.env.SENTRY_PROJECTS)) {
    await reportUnconfigured(ctx, ID, 'SENTRY_AUTH_TOKEN secret, SENTRY_ORG and SENTRY_PROJECTS');
    return { projects: 0, stale: 0 };
  }
  const base = isSet(ctx.env.SENTRY_BASE_URL) && isHttps(ctx.env.SENTRY_BASE_URL) ? ctx.env.SENTRY_BASE_URL.replace(/\/+$/, '') : 'https://sentry.io';
  const projects = ctx.env.SENTRY_PROJECTS.split(/[\s,]+/).filter((p) => /^[\w.-]{1,60}$/.test(p)).slice(0, 10);
  const current = [];
  let complete = true;
  for (const p of projects) {
    try {
      const j = await httpJson(ctx, `${base}/api/0/projects/${encodeURIComponent(ctx.env.SENTRY_ORG)}/${encodeURIComponent(p)}/issues/?query=${QUERY}&limit=25`, { headers: { authorization: `Bearer ${ctx.env.SENTRY_AUTH_TOKEN}` } });
      if (!Array.isArray(j)) throw new WatcherError('Sentry issues response is not a list');
      await clearError(ctx, ID, p);
      for (const i of j as Array<{ id?: unknown; title?: unknown; permalink?: unknown; count?: unknown; firstSeen?: unknown }>) {
        if (typeof i.id !== 'string' && typeof i.id !== 'number') continue;
        current.push(finding(ID, 'sentry-stale', `${p}/${i.id}`, 'stale', `Sentry ${p}: ${String(i.title ?? 'issue').slice(0, 120)} unresolved >72 h and still firing`, { severity: 'P3', ...(isHttps(i.permalink) ? { url: i.permalink } : {}), detail: { events: i.count, firstSeen: i.firstSeen } }));
      }
      if (j.length >= 25) complete = false; // page full: more may exist, do not resolve findings that were merely cut off
    } catch (e) {
      complete = false;
      await reportError(ctx, ID, p, e);
    }
  }
  await settle(ctx, ID, 'sentry-stale', current, complete);
  return { projects: projects.length, stale: current.length };
}
