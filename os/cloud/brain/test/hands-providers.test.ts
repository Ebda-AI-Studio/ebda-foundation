// 4b wiring: provider selection by config, a throwing provider = a failed run (never an aborted tick), pull-only
// mac-local, the PR-review question, and the container DO's required-env check.
import { env } from 'cloudflare:workers';
import { runInDurableObject } from 'cloudflare:test';
import { describe, expect, it } from 'vitest';
import type { BrainDO } from '../src/brain-do';
import type { Finding } from '../src/findings';
import { providerFor, StubHandsProvider, type HandsBatch, type HandsProvider } from '../src/hands';
import { missingContainerEnv } from '../src/hands-container';

const T0 = Date.UTC(2026, 10, 5, 8, 0, 0);
const MIN = 60_000;
const HOUR = 60 * MIN;
const finding = (x: Partial<Finding> = {}): Finding => ({ source: 'watcher', kind: 'docs', key: crypto.randomUUID(), title: 'fix docs', repo: 'o/r', ...x });
const outage = (key: string): Finding => ({ source: 'health', kind: 'prod-outage', key, title: `${key} down`, repo: 'o/r', severity: 'P1', selfHealExhausted: true });

async function harness(hands: HandsProvider) {
  const stub = env.BRAIN.get(env.BRAIN.idFromName(crypto.randomUUID()));
  const sent: string[] = [];
  await runInDurableObject(stub, (b: BrainDO) => {
    b.hands = hands;
    b.fetchImpl = (async (_u: RequestInfo | URL, init?: RequestInit) => {
      sent.push(JSON.parse(String(init?.body)).text);
      return new Response('{"ok":true}', { status: 200 });
    }) as typeof fetch;
  });
  return { sent, run: <R>(fn: (b: BrainDO) => R | Promise<R>) => runInDurableObject(stub, (b: BrainDO) => fn(b)) };
}

const throwing: HandsProvider = {
  name: 'cloudflare-sandbox',
  start: async () => {
    throw new Error('HANDS_CONTAINER binding missing');
  },
};

describe('provider selection (HANDS_PROVIDER)', () => {
  it('stub by default, for unknown names, and for github-actions unless explicitly enabled and configured', () => {
    expect(providerFor('stub')).toBeInstanceOf(StubHandsProvider);
    expect(providerFor('typo')).toBeInstanceOf(StubHandsProvider);
    expect(providerFor('github-actions', {})).toBeInstanceOf(StubHandsProvider);
    expect(providerFor('github-actions', { HANDS_GITHUB_ACTIONS_REPO: 'o/r', HANDS_GITHUB_ACTIONS_WORKFLOW: 'hands.yml', HANDS_GITHUB_ACTIONS_TOKEN: 't' })).toBeInstanceOf(StubHandsProvider);
    const gha = providerFor('github-actions', { HANDS_GITHUB_ACTIONS_ENABLED: 'true', HANDS_GITHUB_ACTIONS_REPO: 'o/r', HANDS_GITHUB_ACTIONS_WORKFLOW: 'hands.yml', HANDS_GITHUB_ACTIONS_TOKEN: 't' });
    expect(gha.name).toBe('github-actions');
  });
  it('the committed config keeps the stub (Task 7 switches it)', () => {
    expect(env.HANDS_PROVIDER).toBe('stub');
  });
  it('cloudflare-sandbox and mac-local are selectable; mac-local is pull-only', () => {
    expect(providerFor('cloudflare-sandbox', {}).name).toBe('cloudflare-sandbox');
    const mac = providerFor('mac-local');
    expect(mac).toMatchObject({ name: 'mac-local', pullOnly: true });
  });
  it('cloudflare-sandbox asks the per-lane container DO with the run cap (urgent: job cap; nightly: run cap)', async () => {
    const calls: Array<{ name: string; body: any }> = [];
    const ns = {
      idFromName: (n: string) => n,
      get: (id: string) => ({ fetch: async (_u: string, init: RequestInit) => (calls.push({ name: id, body: JSON.parse(String(init.body)) }), Response.json({ externalId: `x:${id}` }, { status: 202 })) }),
    };
    const p = providerFor('cloudflare-sandbox', { HANDS_CONTAINER: ns as unknown as DurableObjectNamespace, HANDS_NIGHTLY_RUN_CAP_MIN: '60' });
    const batch = (kind: 'urgent' | 'nightly'): HandsBatch => ({ runId: `run_${kind}`, kind, jobs: [], perJobCapMin: kind === 'urgent' ? 30 : 45, usageThresholdPct: 80, createdAt: T0 });
    expect(await p.start(batch('urgent'))).toMatchObject({ provider: 'cloudflare-sandbox', externalId: 'x:hands-urgent' });
    await p.start(batch('nightly'));
    expect(calls).toEqual([
      { name: 'hands-urgent', body: { runId: 'run_urgent', kind: 'urgent', capMin: 30, repos: [] } },
      { name: 'hands-nightly', body: { runId: 'run_nightly', kind: 'nightly', capMin: 60, repos: [] } },
    ]);
    const busy = providerFor('cloudflare-sandbox', { HANDS_CONTAINER: { idFromName: (n: string) => n, get: () => ({ fetch: async () => new Response('busy', { status: 409 }) }) } as unknown as DurableObjectNamespace });
    await expect(busy.start(batch('nightly'))).rejects.toThrow(/409/);
    await expect(providerFor('cloudflare-sandbox', {}).start(batch('nightly'))).rejects.toThrow(/binding missing/);
  });
});

describe('a throwing provider is a failed run, never an aborted tick', () => {
  it('nightly: failed run recorded, jobs stay queued, nothing marked dispatched', async () => {
    const h = await harness(throwing);
    await h.run((b) => b.ingestFinding(finding(), T0));
    const r = await h.run((b) => b.runNightly(T0 + HOUR));
    expect(r).toMatchObject({ started: false, reason: expect.stringMatching(/failed to start/) });
    const s = await h.run((b) => b.state(T0 + HOUR));
    expect(s.runs[0]).toMatchObject({ provider: 'cloudflare-sandbox', status: 'failed' });
    expect(s.jobs.queuedNightly).toBe(1);
    expect(s.jobs.running).toBe(0);
  });
  it('urgent: tick completes, each failure counts toward the 3/day cap, then the job goes to tonight with one message', async () => {
    const h = await harness(throwing);
    await h.run((b) => b.reportUsage({ weeklyUsedPct: 10 }, T0));
    await h.run((b) => b.ingestFinding(outage('a'), T0));
    for (let i = 0; i < 4; i++) await expect(h.run((b) => b.tick(T0 + i * 5 * MIN))).resolves.not.toThrow();
    const s = await h.run((b) => b.state(T0 + 20 * MIN));
    expect(s.runs.filter((r) => r.kind === 'urgent' && r.status === 'failed')).toHaveLength(3);
    expect(s.jobs.queuedNightly).toBe(1);
    expect(h.sent.filter((t) => /urgent issue not handled yet/.test(t))).toHaveLength(1);
  });
});

describe('pull-only mac-local', () => {
  it('the brain starts nothing; urgent work is queued for the Mac with one message; the Mac can claim', async () => {
    const h = await harness(providerFor('mac-local'));
    await h.run((b) => b.ingestFinding(finding(), T0));
    expect(await h.run((b) => b.runNightly(T0 + HOUR))).toMatchObject({ started: false, reason: expect.stringMatching(/pull-only/) });
    await h.run((b) => b.ingestFinding(outage('m'), T0));
    await h.run((b) => b.tick(T0 + HOUR));
    expect(h.sent.filter((t) => /pull-only/.test(t))).toHaveLength(1);
    await h.run((b) => b.reportUsage({ weeklyUsedPct: 10 }, T0 + MIN)); // a known usage lifts the one-job bootstrap limit
    const claim = await h.run((b) => b.claim('mac-local', 5, T0 + 2 * HOUR));
    expect((claim as HandsBatch).jobs).toHaveLength(2);
  });
});

describe('PR the hands may not merge = one question', () => {
  it('a nightly pr_opened with a question note sends ONE review question; a merged outcome sends nothing', async () => {
    const stubP = new StubHandsProvider();
    const h = await harness(stubP);
    await h.run((b) => b.ingestFinding(finding({ kind: 'ci-failure', title: 'CI red' }), T0));
    await h.run((b) => b.ingestFinding(finding({ kind: 'docs', title: 'docs' }), T0));
    await h.run((b) => b.runNightly(T0 + HOUR));
    const [a, d] = stubP.started[0]!.jobs;
    await h.run((b) => b.recordOutcome(a!.id, { status: 'pr_opened', prUrl: 'https://pr/2', note: 'question: merge policy pr-and-question; needs your review' }, T0 + 2 * HOUR));
    await h.run((b) => b.recordOutcome(d!.id, { status: 'merged', prUrl: 'https://pr/3' }, T0 + 2 * HOUR));
    expect(h.sent).toHaveLength(1);
    expect(h.sent[0]).toMatch(/PR needs your review[\s\S]*https:\/\/pr\/2/);
  });
});

describe('HandsContainer required env', () => {
  const full = { HANDS_BRAIN_URL: 'https://b.test', HANDS_TOKEN: 't', HANDS_GH_TOKEN: 'g', HANDS_CONFIG_JSON: '{}', HANDS_GIT_NAME: 'n', HANDS_GIT_EMAIL: 'e' };
  it('api mode (the default): names every missing container secret/var, never values; placeholders count as missing; a spend limit marker is required', () => {
    expect(missingContainerEnv({})).toEqual(['HANDS_BRAIN_URL', 'HANDS_TOKEN', 'HANDS_ANTHROPIC_API_KEY', 'HANDS_API_SPEND_LIMIT_USD', 'HANDS_GH_TOKEN', 'HANDS_CONFIG_JSON', 'HANDS_GIT_NAME', 'HANDS_GIT_EMAIL']);
    expect(missingContainerEnv({ ...full, HANDS_BRAIN_URL: '__HANDS_BRAIN_URL__', HANDS_ANTHROPIC_API_KEY: 'k', HANDS_API_SPEND_LIMIT_USD: '150' })).toEqual(['HANDS_BRAIN_URL']);
    expect(missingContainerEnv({ ...full, HANDS_ANTHROPIC_API_KEY: 'k', HANDS_API_SPEND_LIMIT_USD: '0' })).toEqual(['HANDS_API_SPEND_LIMIT_USD (a positive USD number)']);
  });
  it('max mode: the OAuth token instead of the key; no spend marker needed', () => {
    expect(missingContainerEnv({ HANDS_CLAUDE_AUTH: 'max' })).toEqual(['HANDS_BRAIN_URL', 'HANDS_TOKEN', 'CLAUDE_CODE_OAUTH_TOKEN', 'HANDS_GH_TOKEN', 'HANDS_CONFIG_JSON', 'HANDS_GIT_NAME', 'HANDS_GIT_EMAIL']);
    expect(missingContainerEnv({ ...full, HANDS_CLAUDE_AUTH: 'max', CLAUDE_CODE_OAUTH_TOKEN: 'c' })).toEqual([]);
  });
});
