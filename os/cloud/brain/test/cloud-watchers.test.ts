// The ten cloud watchers: for each, a failing signal, a healthy case, the unconfigured case and the API-error case.
// fetch and the finding sink are injected; nothing touches the network.
import { env } from 'cloudflare:workers';
import { describe, expect, it } from 'vitest';
import { brainStub } from '../src/index';
import type { Env } from '../src/env';
import type { Finding } from '../src/findings';
import { due, graphql, type Sink, type WatchCtx } from '../src/watchers/common';
import { watchCfWorkers } from '../src/watchers/cf-workers';
import { watchCostGuard } from '../src/watchers/cost-guard';
import { watchDeployDrift } from '../src/watchers/deploy-drift';
import { isoWeek, watchDrDrill, WEEKLY_GATE } from '../src/watchers/dr-drill';
import { forbiddenPath, isStep, watchJourneys } from '../src/watchers/journey-monitor';
import { median, watchPageLoad } from '../src/watchers/page-load';
import { watchPrShepherd } from '../src/watchers/pr-shepherd';
import { GROUPS, runWatchers } from '../src/watchers/run';
import { watchSentryStale } from '../src/watchers/sentry-stale';
import { watchServices } from '../src/watchers/services';
import { watchWorld } from '../src/watchers/world-watch';
import { classifyFinding } from '../src/classify';

const NOW = Date.UTC(2026, 10, 6, 12);
const ACC = 'a'.repeat(32);

type Route = [string, (url: string, init: RequestInit) => Response | Promise<Response>];

function harness(vars: Partial<Env>, routes: Route[], lastDone: number | null = null) {
  const ingested: Finding[] = [];
  const resolved: string[] = [];
  const reconciled: Array<{ kind: string; prefix: string; open: string[] }> = [];
  const calls: string[] = [];
  const sink: Sink = {
    async ingestMany(fs) {
      ingested.push(...fs);
      return { raised: fs.length, deduped: 0 };
    },
    async resolveFinding(f) {
      resolved.push(f.key);
      return true;
    },
    async reconcile(_s, kind, prefix, open) {
      reconciled.push({ kind, prefix, open });
      return 0;
    },
    async lastPassAt() {
      return lastDone;
    },
  };
  const fetchImpl = (async (input: string | URL | Request, init: RequestInit = {}) => {
    const url = String(input);
    calls.push(url);
    for (const [frag, h] of routes) if (url.includes(frag)) return h(url, init);
    return new Response('not found', { status: 404 });
  }) as unknown as typeof fetch;
  const ctx: WatchCtx = { env: { ...env, ...vars } as Env, sink, now: NOW, fetchImpl };
  const kinds = () => ingested.map((f) => `${f.kind}|${f.key}`);
  return { ctx, ingested, resolved, reconciled, calls, kinds };
}
const fresh = async (...keys: string[]) => {
  for (const k of keys) await env.EVENTS.delete(k);
};
const json = (b: unknown, status = 200) => Response.json(b, { status });
const unconfigured = (h: ReturnType<typeof harness>, id: string) => expect(h.ingested).toMatchObject([{ kind: 'monitor-unconfigured', key: `${id}:config:unconfigured` }]);

describe('classify: watcher self-reports never become hands jobs', () => {
  for (const kind of ['monitor-unconfigured', 'watcher-error']) {
    it(`${kind} is a digest-lane finding, never nightly, urgent or question, whatever else it carries`, () => {
      for (const extra of [{}, { severity: 'P1' as const, selfHealExhausted: true }, { touches: [] as string[] }]) {
        const c = classifyFinding({ source: 'watcher', kind, key: 'x:y:z', title: 't', ...extra });
        expect(c.lane).toBe('digest');
        expect(c.lane).not.toBe('question');
        expect(c.lane).not.toBe('nightly');
        expect(c.lane).not.toBe('urgent');
      }
    });
  }
  it('in the brain they are recorded and deduped with NO job and NO question', async () => {
    const brain = brainStub(env);
    const r = await brain.ingestFinding({ source: 'watcher', kind: 'monitor-unconfigured', key: 'services:config:unconfigured', title: 'watcher services is not running' }, NOW);
    expect(r.lane).toBe('digest');
    expect(r.jobId).toBeNull();
    const again = await brain.ingestFinding({ source: 'watcher', kind: 'monitor-unconfigured', key: 'services:config:unconfigured', title: 'watcher services is not running' }, NOW + 1000);
    expect(again.deduped).toBe(true);
    const st = await brain.state(NOW + 2000);
    expect(st.jobs.queuedNightly).toBe(0);
    expect(st.jobs.queuedUrgent).toBe(0);
  });
});

describe('common', () => {
  it('due() opens once per interval', async () => {
    await fresh('wd:last:t1');
    const h = harness({}, []);
    expect(await due(h.ctx, 't1', 60000)).toBe(true);
    expect(await due(h.ctx, 't1', 60000)).toBe(false);
    expect(await due({ ...h.ctx, now: NOW + 61000 }, 't1', 60000)).toBe(true);
  });
  it('graphql: HTTP 200 with errors is a failure', async () => {
    const h = harness({}, [['graphql', () => json({ data: null, errors: [{ message: 'Bad credentials' }] })]]);
    await expect(graphql(h.ctx, 'https://x/graphql', 't', 'q', {})).rejects.toThrow(/GraphQL error: Bad credentials/);
  });
});

describe('services', () => {
  const targets = JSON.stringify([
    { name: 'api', url: 'https://api.svc.test/health', kind: 'api' },
    { name: 'chat', url: 'https://chat.svc.test/', kind: 'page' },
  ]);
  it('unconfigured: one monitor-unconfigured finding', async () => {
    const h = harness({ SERVICE_TARGETS: undefined }, []);
    await watchServices(h.ctx);
    unconfigured(h, 'services');
  });
  it('healthy: no finding, streak cleared', async () => {
    await fresh('svc:fails:api', 'svc:fails:chat');
    const h = harness({ SERVICE_TARGETS: targets }, [['svc.test', () => json({ ok: true })]]);
    expect(await watchServices(h.ctx)).toEqual({ checked: 2, down: [] });
    expect(h.ingested).toEqual([]);
  });
  it('a 200 with ok:false counts as down; a finding only after the fail budget (3 checks)', async () => {
    await fresh('svc:fails:api', 'svc:fails:chat');
    const h = harness({ SERVICE_TARGETS: targets }, [['api.svc.test', () => json({ ok: false })], ['chat.svc.test', () => new Response('ok')]]);
    await watchServices(h.ctx);
    await watchServices(h.ctx);
    expect(h.ingested).toEqual([]);
    const r = await watchServices(h.ctx);
    expect(r.down).toEqual(['api']);
    expect(h.ingested).toMatchObject([{ kind: 'prod-outage', key: 'services:api:down', selfHealExhausted: true, severity: 'P1' }]);
    expect(classifyFinding(h.ingested[0]!).lane).toBe('urgent');
  });
  it('a timeout / network error is a failure too', async () => {
    await fresh('svc:fails:api', 'svc:fails:chat');
    const h = harness({ SERVICE_TARGETS: targets, HEALTH_FAIL_BUDGET: '1' }, [['svc.test', () => { throw new Error('boom'); }]]);
    expect((await watchServices(h.ctx)).down).toEqual(['api', 'chat']);
  });
});

describe('page-load', () => {
  const cfg = JSON.stringify([{ name: 'home', url: 'https://shop.pl.test/' }]);
  it('median of 3', () => expect(median([900, 100, 5000])).toBe(900));
  it('unconfigured', async () => {
    const h = harness({ PAGE_LOAD_TARGETS: undefined }, []);
    await watchPageLoad(h.ctx);
    unconfigured(h, 'page-load');
  });
  it('fast page: healthy', async () => {
    const h = harness({ PAGE_LOAD_TARGETS: cfg }, [['pl.test', () => new Response('<html>')]]);
    expect(await watchPageLoad(h.ctx)).toEqual({ checked: 1, slow: [] });
    expect(h.ingested).toEqual([]);
  });
  it('p50 over the limit is a finding (limit lowered to 1 ms so a real delay trips it)', async () => {
    const h = harness({ PAGE_LOAD_TARGETS: cfg, PAGE_LOAD_P50_MS: '1' }, [['pl.test', async () => { await new Promise((r) => setTimeout(r, 15)); return new Response('x'); }]]);
    await watchPageLoad(h.ctx);
    expect(h.kinds()).toEqual(['page-load|page-load:home:slow']);
  });
  it('non-2xx on 2+ of 3 runs is a finding (an error page is not "fast")', async () => {
    const h = harness({ PAGE_LOAD_TARGETS: cfg }, [['pl.test', () => new Response('no', { status: 503 })]]);
    await watchPageLoad(h.ctx);
    expect(h.kinds()).toEqual(['page-load|page-load:home:unreachable']);
  });
});

describe('journey-monitor', () => {
  const j = (steps: unknown[]) => JSON.stringify([{ name: 'guest', steps }]);
  const ok = [
    { name: 'home', url: 'https://j.test/' },
    { name: 'product', url: 'https://j.test/p/tee', contains: 'Add to cart' },
    { name: 'cart', url: 'https://j.test/cart' },
  ];
  it('unconfigured', async () => {
    const h = harness({ JOURNEY_CONFIG: undefined }, []);
    await watchJourneys(h.ctx);
    unconfigured(h, 'journey-monitor');
  });
  it('healthy journey: every step is a GET, nothing raised', async () => {
    const methods: string[] = [];
    const h = harness({ JOURNEY_CONFIG: j(ok) }, [['j.test', (_u, i) => { methods.push(i.method ?? 'GET'); return new Response('... Add to cart ...'); }]]);
    expect(await watchJourneys(h.ctx)).toEqual({ journeys: 1, failed: [] });
    expect(methods).toEqual(['GET', 'GET', 'GET']);
    expect(h.ingested).toEqual([]);
  });
  it('a broken step stops the journey and names the step', async () => {
    const h = harness({ JOURNEY_CONFIG: j(ok) }, [['/p/tee', () => new Response('gone', { status: 500 })], ['j.test', () => new Response('x')]]);
    await watchJourneys(h.ctx);
    expect(h.ingested).toMatchObject([{ kind: 'journey-failed', key: 'journey-monitor:guest:failed', detail: { step: 'product', reason: 'HTTP 500' } }]);
    expect(h.calls.some((u) => u.endsWith('/cart'))).toBe(false);
  });
  it('missing expected text fails the step even on HTTP 200', async () => {
    const h = harness({ JOURNEY_CONFIG: j(ok) }, [['j.test', () => new Response('empty page')]]);
    await watchJourneys(h.ctx);
    expect(h.ingested[0]).toMatchObject({ kind: 'journey-failed', detail: { step: 'product', reason: 'expected text missing' } });
  });
  it('forbidden paths match whole segments: /cart/checkout and /payment are refused, /products/order-box and /pay-it-forward are fine', () => {
    for (const p of ['/checkout', '/cart/checkout', '/payment', '/payment/intent', '/orders', '/order', '/login', '/account/login/', '/CHECKOUT']) expect(forbiddenPath(p)).toBe(true);
    for (const p of ['/products/order-box', '/p/payment-terminal-case', '/blog/how-to-pay', '/cart', '/p/tee', '/', '/collections/reorder']) expect(forbiddenPath(p)).toBe(false);
    expect(forbiddenPath('/%zz')).toBe(true);
    expect(isStep({ name: 's', url: 'https://j.test/products/order-box' })).toBe(true);
    expect(isStep({ name: 's', url: 'https://j.test/cart/checkout' })).toBe(false);
  });
  it('a redirect that lands on /checkout fails the step', async () => {
    const h = harness({ JOURNEY_CONFIG: j([{ name: 'cart', url: 'https://j.test/cart' }]) }, [['j.test', () => Object.defineProperty(new Response('x'), 'url', { value: 'https://j.test/checkout' })]]);
    await watchJourneys(h.ctx);
    expect(h.ingested[0]).toMatchObject({ kind: 'journey-failed', detail: { reason: 'redirected to a checkout or login path' } });
  });
  it('checkout / payment / order / login paths are refused: the journey is dropped and a config error raised', async () => {
    for (const p of ['/checkout', '/api/payment/intent', '/orders', '/place-order', '/login']) expect(isStep({ name: 's', url: `https://j.test${p}` })).toBe(false);
    const h = harness({ JOURNEY_CONFIG: j([...ok, { name: 'buy', url: 'https://j.test/checkout' }]) }, [['j.test', () => new Response('x')]]);
    await watchJourneys(h.ctx);
    expect(h.calls).toEqual([]);
    expect(h.ingested).toMatchObject([{ kind: 'watcher-error', key: 'journey-monitor:config:error' }]);
  });
});

describe('deploy-drift', () => {
  const cfg = JSON.stringify([{ name: 'api', healthUrl: 'https://api.dd.test/health', repo: 'Ebda-AI-Studio/ebda-store' }]);
  const gh = (sha: string, ageH: number): Route => ['api.github.com', () => json({ sha, commit: { committer: { date: new Date(NOW - ageH * 3600000).toISOString() } } })];
  const base = { DEPLOY_DRIFT_TARGETS: cfg, GITHUB_TOKEN: 'tok' };
  it('unconfigured: no targets, then no token', async () => {
    const h = harness({ DEPLOY_DRIFT_TARGETS: undefined }, []);
    await watchDeployDrift(h.ctx);
    unconfigured(h, 'deploy-drift');
    const h2 = harness({ DEPLOY_DRIFT_TARGETS: cfg, GITHUB_TOKEN: undefined }, []);
    await watchDeployDrift(h2.ctx);
    unconfigured(h2, 'deploy-drift');
  });
  it('live == tip: healthy (prefix compare)', async () => {
    const h = harness(base, [['api.dd.test', () => json({ ok: true, commit: 'abcdef1' })], gh('abcdef1234567890', 5)]);
    expect((await watchDeployDrift(h.ctx)).drifted).toEqual([]);
    expect(h.ingested).toEqual([]);
  });
  it('live behind a tip older than 2 h is drift; behind a tip younger than 2 h is not', async () => {
    const old = harness(base, [['api.dd.test', () => json({ commit: '1111111' })], gh('2222222aaaa', 3)]);
    await watchDeployDrift(old.ctx);
    expect(old.ingested).toMatchObject([{ kind: 'deploy-drift', key: 'deploy-drift:api:drifted', repo: 'Ebda-AI-Studio/ebda-store' }]);
    const young = harness(base, [['api.dd.test', () => json({ commit: '1111111' })], gh('2222222aaaa', 1)]);
    await watchDeployDrift(young.ctx);
    expect(young.ingested).toEqual([]);
  });
  it('API errors: /health without a commit, GitHub 401 -> watcher-error, and the drift finding is NOT resolved', async () => {
    const a = harness(base, [['api.dd.test', () => json({ ok: true })], gh('x', 9)]);
    await watchDeployDrift(a.ctx);
    expect(a.ingested).toMatchObject([{ kind: 'watcher-error', key: 'deploy-drift:api:error' }]);
    const b = harness(base, [['api.dd.test', () => json({ commit: 'abcdef1' })], ['api.github.com', () => json({ message: 'Bad credentials' }, 401)]]);
    await watchDeployDrift(b.ctx);
    expect(b.ingested[0]).toMatchObject({ kind: 'watcher-error' });
    expect(b.reconciled).toEqual([]);
  });
});

describe('pr-shepherd', () => {
  const pr = (o: Record<string, unknown>) => ({ number: 7, title: 'feat x', url: 'https://github.com/o/r/pull/7', isDraft: false, updatedAt: new Date(NOW - 3600000).toISOString(), mergeable: 'MERGEABLE', repository: { nameWithOwner: 'Ebda-AI-Studio/ebda-store' }, commits: { nodes: [{ commit: { statusCheckRollup: { state: 'SUCCESS' } } }] }, ...o });
  const gql = (nodes: unknown[], hasNextPage = false): Route => ['api.github.com/graphql', () => json({ data: { search: { pageInfo: { hasNextPage }, nodes } } })];
  const base = { OS_ORGS: 'Ebda-AI-Studio', GITHUB_TOKEN: 'tok' };
  it('unconfigured', async () => {
    const h = harness({ ...base, GITHUB_TOKEN: undefined }, []);
    await watchPrShepherd(h.ctx);
    unconfigured(h, 'pr-shepherd');
  });
  it('a fresh passing PR is healthy', async () => {
    const h = harness(base, [gql([pr({})])]);
    expect(await watchPrShepherd(h.ctx)).toEqual({ prs: 1, flagged: 0 });
  });
  it('conflicting, failed checks and >24 h waiting each raise a deduped pr:<repo>#<n>:<state> finding', async () => {
    const h = harness(base, [gql([pr({ mergeable: 'CONFLICTING', updatedAt: new Date(NOW - 30 * 3600000).toISOString(), commits: { nodes: [{ commit: { statusCheckRollup: { state: 'FAILURE' } } }] } })])]);
    await watchPrShepherd(h.ctx);
    expect(h.ingested.map((f) => f.key).sort()).toEqual(['pr:Ebda-AI-Studio/ebda-store#7:conflicting', 'pr:Ebda-AI-Studio/ebda-store#7:failed-checks', 'pr:Ebda-AI-Studio/ebda-store#7:waiting']);
  });
  it('a draft is not flagged for waiting', async () => {
    const h = harness(base, [gql([pr({ isDraft: true, updatedAt: new Date(NOW - 99 * 3600000).toISOString() })])]);
    await watchPrShepherd(h.ctx);
    expect(h.ingested).toEqual([]);
  });
  it('GraphQL 200 + errors is a watcher-error and resolves nothing', async () => {
    const h = harness(base, [['api.github.com/graphql', () => json({ data: null, errors: [{ message: 'Resource not accessible' }] })]]);
    await watchPrShepherd(h.ctx);
    expect(h.ingested).toMatchObject([{ kind: 'watcher-error', key: 'pr-shepherd:Ebda-AI-Studio:error' }]);
    expect(h.reconciled).toEqual([]);
  });
});

describe('cf-workers', () => {
  const base = { CF_API_TOKEN: 'tok', CF_ACCOUNT_ID: ACC };
  const scripts = (ids: string[]): Route => ['/workers/scripts', () => json({ success: true, result: ids.map((id) => ({ id })) })];
  const analytics = (rows: unknown[]): Route => ['/graphql', () => json({ data: { viewer: { accounts: [{ workersInvocationsAdaptive: rows }] } } })];
  const row = (n: string, requests: number, errors: number) => ({ sum: { requests, errors }, dimensions: { scriptName: n } });
  it('unconfigured', async () => {
    const h = harness({ CF_API_TOKEN: undefined }, []);
    await watchCfWorkers(h.ctx);
    unconfigured(h, 'cf-workers');
  });
  it('healthy Ebda Worker; a non-Ebda Worker with 100% errors is ignored', async () => {
    const h = harness(base, [scripts(['ebda-store', 'whisky11-site']), analytics([row('ebda-store', 1000, 3), row('whisky11-site', 500, 500)])]);
    expect(await watchCfWorkers(h.ctx)).toEqual({ workers: 1, flagged: [] });
    expect(h.ingested).toEqual([]);
  });
  it('error rate over 5% is a finding; an expected Worker that vanished is a P1 finding', async () => {
    const h = harness({ ...base, CF_WORKERS_EXPECTED: 'ebda-store ebda-chat' }, [scripts(['ebda-store']), analytics([row('ebda-store', 1000, 200)])]);
    await watchCfWorkers(h.ctx);
    expect(h.kinds().sort()).toEqual(['cf-worker|cf-workers:ebda-chat:missing', 'cf-worker|cf-workers:ebda-store:errors']);
  });
  it('REST success:false and GraphQL 200 + errors are watcher-errors, never all clear', async () => {
    const a = harness(base, [['/workers/scripts', () => json({ success: false, errors: [{ message: 'Authentication error' }] })]]);
    await watchCfWorkers(a.ctx);
    expect(a.ingested).toMatchObject([{ kind: 'watcher-error', key: 'cf-workers:cloudflare:error' }]);
    const b = harness(base, [scripts(['ebda-store']), ['/graphql', () => json({ data: null, errors: [{ message: 'denied' }] })]]);
    await watchCfWorkers(b.ctx);
    expect(b.ingested[0]).toMatchObject({ kind: 'watcher-error' });
    expect(b.reconciled).toEqual([]);
  });
});

describe('cost-guard', () => {
  const base = { COST_GH_ORG: 'Ebda-AI-Studio', GITHUB_TOKEN: 'tok', CF_API_TOKEN: 'tok', CF_ACCOUNT_ID: ACC };
  const usage = (min: number): Route => ['settings/billing/usage', () => json({ usageItems: [{ product: 'Actions', unitType: 'Minutes', quantity: min }, { product: 'Actions', unitType: 'GB', quantity: 99999 }, { product: 'Copilot', unitType: 'Minutes', quantity: 99999 }] })];
  const cf = (n: number): Route => ['/graphql', () => json({ data: { viewer: { accounts: [{ workersInvocationsAdaptive: [{ sum: { requests: n } }] }] } } })];
  it('unconfigured: nothing set', async () => {
    const h = harness({}, []);
    await watchCostGuard(h.ctx);
    unconfigured(h, 'cost-guard');
  });
  it('under both thresholds: healthy (only Actions Minutes counted)', async () => {
    const h = harness(base, [usage(1200), cf(10)]);
    expect(await watchCostGuard(h.ctx)).toEqual({ actionsMin: 1200, cfRequests: 10 });
    expect(h.ingested).toEqual([]);
  });
  it('48000 warns, 49500 stops; Cloudflare requests warn at 8M', async () => {
    const w = harness(base, [usage(48000), cf(8_000_000)]);
    await watchCostGuard(w.ctx);
    expect(w.kinds().sort()).toEqual(['cost-warn|cost-guard:actions-Ebda-AI-Studio:warn', 'cost-warn|cost-guard:cloudflare-requests:warn']);
    const s = harness(base, [usage(49500), cf(1)]);
    await watchCostGuard(s.ctx);
    expect(s.ingested).toMatchObject([{ kind: 'cost-stop', severity: 'P1' }]);
  });
  it('401 on billing and GraphQL errors are watcher-errors', async () => {
    const h = harness(base, [['settings/billing/usage', () => json({ message: 'Bad credentials' }, 401)], ['/graphql', () => json({ errors: [{ message: 'x' }] })]]);
    await watchCostGuard(h.ctx);
    expect(h.kinds().sort()).toEqual(['watcher-error|cost-guard:cloudflare:error', 'watcher-error|cost-guard:github:error']);
    expect(h.reconciled).toEqual([]);
  });
  it('configured half runs even when the other is unset', async () => {
    const h = harness({ COST_GH_ORG: 'Ebda-AI-Studio', GITHUB_TOKEN: 'tok', CF_API_TOKEN: undefined, CF_ACCOUNT_ID: undefined }, [usage(50000)]);
    await watchCostGuard(h.ctx);
    expect(h.kinds().sort()).toEqual(['cost-stop|cost-guard:actions-Ebda-AI-Studio:stop', 'monitor-unconfigured|cost-guard:config:unconfigured']);
  });
});

describe('sentry-stale', () => {
  const base = { SENTRY_AUTH_TOKEN: 'tok', SENTRY_ORG: 'ebda', SENTRY_PROJECTS: 'store,chat' };
  it('unconfigured', async () => {
    const h = harness({ SENTRY_AUTH_TOKEN: undefined }, []);
    await watchSentryStale(h.ctx);
    unconfigured(h, 'sentry-stale');
  });
  it('queries unresolved age:+72h lastSeen:-24h per project; no issues is healthy', async () => {
    const h = harness(base, [['sentry.io', () => json([])]]);
    expect(await watchSentryStale(h.ctx)).toEqual({ projects: 2, stale: 0 });
    expect(decodeURIComponent(h.calls[0]!)).toContain('is:unresolved age:+72h lastSeen:-24h');
    expect(h.calls[0]).toContain('/projects/ebda/store/issues/');
  });
  it('stale issue is a finding keyed by project and issue id', async () => {
    const h = harness({ ...base, SENTRY_PROJECTS: 'store' }, [['sentry.io', () => json([{ id: '991', title: 'TypeError in cart', permalink: 'https://sentry.io/i/991', count: '40' }])]]);
    await watchSentryStale(h.ctx);
    expect(h.ingested).toMatchObject([{ kind: 'sentry-stale', key: 'sentry-stale:store/991:stale' }]);
  });
  it('401 / non-list response is a watcher-error', async () => {
    const a = harness({ ...base, SENTRY_PROJECTS: 'store' }, [['sentry.io', () => json({ detail: 'Invalid token' }, 401)]]);
    await watchSentryStale(a.ctx);
    expect(a.ingested).toMatchObject([{ kind: 'watcher-error', key: 'sentry-stale:store:error' }]);
    const b = harness({ ...base, SENTRY_PROJECTS: 'store' }, [['sentry.io', () => json({ detail: 'x' })]]);
    await watchSentryStale(b.ctx);
    expect(b.ingested[0]).toMatchObject({ kind: 'watcher-error' });
  });
});

describe('world-watch', () => {
  const routes = (cfInc: unknown[] = [], npm: unknown = {}): Route[] => [
    ['cloudflarestatus.com', () => json({ incidents: cfInc })],
    ['githubstatus.com', () => json({ incidents: [] })],
    ['registry.npmjs.org', () => json(npm)],
  ];
  it('npm half unconfigured is visible; the status half still runs', async () => {
    const h = harness({ WORLD_NPM_DEPS: undefined }, routes([{ id: 'inc1', name: 'API down', impact: 'major', status: 'investigating', shortlink: 'https://stspg.io/x' }]));
    await watchWorld(h.ctx);
    expect(h.kinds().sort()).toEqual(['monitor-unconfigured|world-watch:config:unconfigured', 'vendor-incident|world-watch:cloudflare:inc1']);
  });
  it('quiet world: healthy', async () => {
    const h = harness({ WORLD_NPM_DEPS: '{"hono":["4.6.0"]}' }, routes());
    expect((await watchWorld(h.ctx)).flagged).toBe(0);
    expect(h.ingested).toEqual([]);
  });
  it('minor / resolved incidents are ignored; high npm advisory is flagged, low is not', async () => {
    const h = harness({ WORLD_NPM_DEPS: '{"hono":["4.6.0"]}' }, routes(
      [{ id: 'a', impact: 'minor', status: 'investigating' }, { id: 'b', impact: 'critical', status: 'resolved' }],
      { hono: [{ id: 111, title: 'Auth bypass', severity: 'high', url: 'https://github.com/advisories/GHSA-x', vulnerable_versions: '<4.6.1' }, { id: 112, title: 'meh', severity: 'low' }] },
    ));
    await watchWorld(h.ctx);
    expect(h.kinds()).toEqual(['world-advisory|world-watch:npm/hono/111:open']);
  });
  it('a failing status source and an npm 500 are watcher-errors', async () => {
    const h = harness({ WORLD_NPM_DEPS: '{"hono":["4.6.0"]}' }, [['cloudflarestatus.com', () => new Response('x', { status: 503 })], ['githubstatus.com', () => new Response('not json')], ['registry.npmjs.org', () => new Response('x', { status: 500 })]]);
    await watchWorld(h.ctx);
    expect(h.kinds().sort()).toEqual(['watcher-error|world-watch:cloudflare:error', 'watcher-error|world-watch:github:error', 'watcher-error|world-watch:npm:error']);
    expect(h.reconciled).toEqual([]);
  });
});

describe('dr-drill', () => {
  const base = { DR_DRILL_REPO: 'Ebda-AI-Studio/ebda-store' };
  it('ISO week key: year-Www, correct across year boundaries', () => {
    expect(isoWeek(Date.UTC(2026, 10, 6))).toBe('2026-W45');
    expect(isoWeek(Date.UTC(2026, 0, 1))).toBe('2026-W01');
    expect(isoWeek(Date.UTC(2027, 0, 1))).toBe('2026-W53');
    expect(isoWeek(Date.UTC(2024, 11, 30))).toBe('2025-W01');
  });
  it('unconfigured', async () => {
    const h = harness({ DR_DRILL_REPO: undefined }, []);
    await watchDrDrill(h.ctx);
    unconfigured(h, 'dr-drill');
  });
  it('weekly enqueue: one nightly-lane drill job per ISO week; the gate closes after the ingest', async () => {
    await fresh('dr:first-run', WEEKLY_GATE);
    const h = harness(base, [], NOW - 86400000);
    expect(await watchDrDrill(h.ctx)).toEqual({ enqueued: true, stale: false });
    expect(h.ingested).toHaveLength(1);
    expect(h.ingested[0]).toMatchObject({ kind: 'dr-drill', repo: 'Ebda-AI-Studio/ebda-store', key: 'dr-drill:ebda-store:2026-W45' });
    expect(h.ingested[0]!.title).toContain('node scripts/ops/restore-drill.mjs --target api');
    expect(classifyFinding(h.ingested[0]!).lane).toBe('nightly');
    expect(await env.EVENTS.get(WEEKLY_GATE)).toBe(String(NOW));
    const again = harness(base, [], NOW - 86400000);
    expect((await watchDrDrill({ ...again.ctx, now: NOW + 6 * 3600000 })).enqueued).toBe(false);
    expect(again.ingested).toEqual([]);
  });
  it('an ingest that throws leaves the weekly gate open so the next run retries', async () => {
    await fresh('dr:first-run', WEEKLY_GATE);
    const h = harness(base, [], NOW - 86400000);
    const boom: Sink = { ...h.ctx.sink, async ingestMany() { throw new Error('do unavailable'); } };
    await expect(watchDrDrill({ ...h.ctx, sink: boom })).rejects.toThrow('do unavailable');
    expect(await env.EVENTS.get(WEEKLY_GATE)).toBeNull();
    const retry = harness(base, [], NOW - 86400000);
    expect((await watchDrDrill({ ...retry.ctx, now: NOW + 6 * 3600000 })).enqueued).toBe(true);
  });
  it('last PASSED drill older than 8 days is a stale finding; a recent pass resolves it', async () => {
    await fresh('dr:first-run');
    await env.EVENTS.put(WEEKLY_GATE, String(NOW));
    const stale = harness(base, [], NOW - 9 * 86400000);
    expect((await watchDrDrill(stale.ctx)).stale).toBe(true);
    expect(stale.ingested).toMatchObject([{ kind: 'dr-drill-stale', key: 'dr-drill:ebda-store:stale' }]);
    const ok = harness(base, [], NOW - 2 * 86400000);
    expect((await watchDrDrill(ok.ctx)).stale).toBe(false);
    expect(ok.reconciled).toMatchObject([{ kind: 'dr-drill-stale', open: [] }]);
  });
  it('no drill ever passed: age counts from the watcher first run (no instant alarm)', async () => {
    await fresh('dr:first-run');
    await env.EVENTS.put(WEEKLY_GATE, String(NOW));
    expect((await watchDrDrill(harness(base, [], null).ctx)).stale).toBe(false);
    await env.EVENTS.put('dr:first-run', String(NOW - 10 * 86400000));
    expect((await watchDrDrill(harness(base, [], null).ctx)).stale).toBe(true);
  });
});

describe('runner + real Durable Object', () => {
  it('every group member exists and ids are unique', () => {
    const ids = Object.values(GROUPS).flat().map((w) => w.id);
    expect(new Set(ids).size).toBe(ids.length);
    expect(ids.sort()).toEqual(['cf-workers', 'cost-guard', 'deploy-drift', 'dr-drill', 'journey-monitor', 'page-load', 'pr-shepherd', 'sentry-stale', 'services', 'world-watch']);
  });
  it('a quarter run with nothing configured raises the three monitor-unconfigured findings in the brain, and does not rerun within its cadence', async () => {
    await fresh('wd:last:services', 'wd:last:page-load', 'wd:last:journey-monitor');
    const brain = brainStub(env);
    const e = { ...env, SERVICE_TARGETS: undefined, PAGE_LOAD_TARGETS: undefined, JOURNEY_CONFIG: undefined } as Env;
    const r = await runWatchers('quarter', e, brain, NOW);
    expect(r).toEqual({ services: 'ran', 'page-load': 'ran', 'journey-monitor': 'ran' });
    const titles = (await brain.state()).findings.recent.filter((f) => f.kind === 'monitor-unconfigured').map((f) => f.title);
    expect(titles).toHaveLength(3);
    expect(await runWatchers('quarter', e, brain, NOW + 60000)).toEqual({ services: 'skipped', 'page-load': 'skipped', 'journey-monitor': 'skipped' });
  });
  it('a watcher that hits an API failure is reported and the rest of the group still runs', async () => {
    await fresh('wd:last:cf-workers', 'wd:last:sentry-stale', 'wd:last:cost-guard', 'wd:last:world-watch');
    const h = harness({ CF_API_TOKEN: 'tok', CF_ACCOUNT_ID: ACC }, [['workers/scripts', () => { throw new Error('dns'); }]]);
    const r = await runWatchers('sixhourly', h.ctx.env, h.ctx.sink, NOW, h.ctx.fetchImpl);
    expect(r['cf-workers']).toBe('ran');
    expect(h.ingested.some((f) => f.kind === 'watcher-error' && f.key === 'cf-workers:cloudflare:error')).toBe(true);
    expect(r['world-watch']).toBe('ran');
  });
  it('brain DO: a done drill job without drill:pass (or with drill:fail) is NOT a pass; drill:pass is', async () => {
    const brain = brainStub(env);
    const t0 = Date.UTC(2026, 10, 1);
    const run = async (key: string, o: { status: 'merged' | 'pr_opened'; drill?: 'pass' | 'fail' }, at: number) => {
      const r = await brain.ingestFinding({ source: 'watcher', kind: 'dr-drill', key, title: 'drill' }, at);
      await brain.claim('mac-local', 5, at);
      expect((await brain.recordOutcome(r.jobId!, o, at + 1000)).ok).toBe(true);
    };
    await run('dr-drill:ebda-store:2026-W40', { status: 'merged' }, t0);
    expect(await brain.lastPassAt('watcher', 'dr-drill')).toBeNull();
    await run('dr-drill:ebda-store:2026-W41', { status: 'merged', drill: 'fail' }, t0 + 1000000);
    expect(await brain.lastPassAt('watcher', 'dr-drill')).toBeNull();
    await run('dr-drill:ebda-store:2026-W42', { status: 'pr_opened', drill: 'pass' }, t0 + 2000000);
    expect(await brain.lastPassAt('watcher', 'dr-drill')).toBe(t0 + 2001000);
  });
});
