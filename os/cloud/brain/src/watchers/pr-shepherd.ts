// pr-shepherd watcher (cron, hourly): open PRs in the Ebda orgs (OS_ORGS) that need a human-free nudge: CONFLICTING with the
// base, a failing required-checks rollup, or waiting without any update for more than PR_SHEPHERD_STALE_HOURS (24). Each is a
// finding the hands can act on (rebase, fix the check, ping), deduped per PR and state: `pr:<repo>#<n>:<state>`.
// One GraphQL search per org (read-only token). GraphQL 200 + errors is a watcher-error, never "no PRs".
import { orgsFrom } from './advisories';
import { finding, graphql, isSet, numVar, reportError, reportUnconfigured, clearError, settle, type WatchCtx } from './common';

export const ID = 'pr-shepherd';
/** finding keys use the short prefix the brief fixed: pr:<repo>#<n>:<state> */
const KEY = 'pr';
export const INTERVAL_MS = 60 * 60 * 1000;

const QUERY = `query($q:String!){search(query:$q,type:ISSUE,first:100){pageInfo{hasNextPage} nodes{... on PullRequest{number title url isDraft updatedAt mergeable repository{nameWithOwner} commits(last:1){nodes{commit{statusCheckRollup{state}}}}}}}}`;

interface PrNode {
  number: number;
  title: string;
  url: string;
  isDraft: boolean;
  updatedAt: string;
  mergeable: string;
  repository: { nameWithOwner: string };
  commits?: { nodes?: Array<{ commit?: { statusCheckRollup?: { state?: string } | null } }> };
}

export async function watchPrShepherd(ctx: WatchCtx): Promise<{ prs: number; flagged: number }> {
  const orgs = orgsFrom(ctx.env);
  if (!orgs.length) {
    await reportUnconfigured(ctx, ID, 'OS_ORGS');
    return { prs: 0, flagged: 0 };
  }
  if (!isSet(ctx.env.GITHUB_TOKEN)) {
    await reportUnconfigured(ctx, ID, 'GITHUB_TOKEN secret');
    return { prs: 0, flagged: 0 };
  }
  const staleMs = numVar(ctx.env.PR_SHEPHERD_STALE_HOURS, 24) * 3600000;
  const current = [];
  let prs = 0;
  let complete = true;
  for (const org of orgs) {
    try {
      const d = await graphql(ctx, 'https://api.github.com/graphql', ctx.env.GITHUB_TOKEN, QUERY, { q: `org:${org} is:pr is:open archived:false` });
      const nodes = ((d.search?.nodes ?? []) as PrNode[]).filter((n) => n && typeof n.number === 'number' && n.repository?.nameWithOwner);
      if (d.search?.pageInfo?.hasNextPage) complete = false;
      await clearError(ctx, ID, org);
      for (const n of nodes) {
        prs++;
        const repo = n.repository.nameWithOwner;
        const id = `${repo}#${n.number}`;
        const base = { repo, url: n.url, severity: 'P3' as const };
        if (n.mergeable === 'CONFLICTING') current.push(finding(KEY, 'pr-stuck', id, 'conflicting', `PR ${id} conflicts with its base: ${n.title}`, base));
        const rollup = n.commits?.nodes?.[0]?.commit?.statusCheckRollup?.state;
        if (rollup === 'FAILURE' || rollup === 'ERROR') current.push(finding(KEY, 'pr-stuck', id, 'failed-checks', `PR ${id} has failing checks: ${n.title}`, base));
        if (!n.isDraft && ctx.now - Date.parse(n.updatedAt) > staleMs) current.push(finding(KEY, 'pr-stuck', id, 'waiting', `PR ${id} has waited over ${Math.round(staleMs / 3600000)} h: ${n.title}`, base));
      }
    } catch (e) {
      complete = false;
      await reportError(ctx, ID, org, e);
    }
  }
  await settle(ctx, KEY, 'pr-stuck', current, complete);
  return { prs, flagged: current.length };
}
