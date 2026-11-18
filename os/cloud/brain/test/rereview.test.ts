// Re-review of 8b0d581..5cff838 (N-1, N-2, M-3, M-10 / R-4a-3, the CI catch-up, the egress-refusal P1). Each test is the reviewer's scenario.
import { env } from 'cloudflare:workers';
import { runInDurableObject, SELF } from 'cloudflare:test';
import { describe, expect, it } from 'vitest';
import type { BrainDO } from '../src/brain-do';
import type { Env } from '../src/env';
import type { Finding } from '../src/findings';
import type { HandsBatch, HandsProvider } from '../src/hands';
import { brainStub } from '../src/index';
import { runToken } from '../src/runtoken';
import { watchCiCatchup } from '../src/watchers/ci-catchup';
import type { WatchCtx } from '../src/watchers/common';
import { runWatchers } from '../src/watchers/run';

const T0 = Date.UTC(2026, 10, 5, 8, 0, 0);
const MIN = 60_000;
const HOUR = 60 * MIN;
const DAY = 24 * HOUR;

function realish(): HandsProvider & { started: HandsBatch[] } {
  const started: HandsBatch[] = [];
  return { name: 'cloudflare-sandbox', started, start: async (b) => (started.push(b), { runId: b.runId, provider: 'cloudflare-sandbox', startedAt: b.createdAt }) };
}
async function harness(hands: HandsProvider = realish(), repos: string[] | null = ['o/r']) {
  const stub = env.BRAIN.get(env.BRAIN.idFromName(crypto.randomUUID()));
  const sent: string[] = [];
  await runInDurableObject(stub, (b: BrainDO) => {
    b.hands = hands;
    b.mappedRepos = repos ? new Set(repos) : null;
    b.fetchImpl = (async (_u: RequestInfo | URL, init?: RequestInit) => {
      sent.push(JSON.parse(String(init?.body)).text);
      return new Response('{"ok":true}', { status: 200 });
    }) as typeof fetch;
  });
  return { stub, sent, run: <R>(fn: (b: BrainDO) => R | Promise<R>) => runInDurableObject(stub, (b: BrainDO) => fn(b)) };
}
const docs = (x: Partial<Finding> = {}): Finding => ({ source: 'watcher', kind: 'docs', key: crypto.randomUUID(), title: 'fix docs', repo: 'o/r', ...x });
const ok200 = (body: unknown = { ok: true }) => Response.json(body);

describe('N-1: a watcher that runs configured resolves its monitor-unconfigured finding', () => {
  it('unconfigured run -> configured run: the finding resolves (only that watcher\'s) and /api/state no longer lists it', async () => {
    for (const k of ['wd:last:services', 'wd:last:page-load', 'wd:last:journey-monitor']) await env.EVENTS.delete(k);
    const brain = brainStub(env);
    const bare = { ...env, SERVICE_TARGETS: undefined, PAGE_LOAD_TARGETS: undefined, JOURNEY_CONFIG: undefined } as Env;
    await runWatchers('quarter', bare, brain, T0);
    expect((await brain.state()).unconfigured).toEqual(['ci-pool', 'journey-monitor', 'loop-stall', 'page-load', 'services']);
    const configured = { ...bare, SERVICE_TARGETS: JSON.stringify([{ name: 'api', url: 'https://api.svc.test/h', kind: 'api' }]) } as Env;
    await runWatchers('quarter', configured, brain, T0 + 20 * MIN, (async () => ok200()) as unknown as typeof fetch);
    // the cutover gate (--deployed) reads exactly this list: services is gone, the three still-unconfigured ones stay
    expect((await brain.state()).unconfigured).toEqual(['ci-pool', 'journey-monitor', 'loop-stall', 'page-load']);
    const f = (await brain.state()).findings.recent.find((x) => x.kind === 'monitor-unconfigured' && x.title.includes('services'));
    expect(f?.status).toBe('resolved');
  });
  it('a config that is still unusable keeps the finding open (and a recurrence after resolution reopens it with no cool-down)', async () => {
    await env.EVENTS.delete('wd:last:services');
    const brain = brainStub(env);
    await runWatchers('quarter', { ...env, SERVICE_TARGETS: undefined, PAGE_LOAD_TARGETS: undefined, JOURNEY_CONFIG: undefined } as Env, brain, T0 + 30 * MIN);
    expect((await brain.state()).unconfigured).toContain('services'); // gone again right after being resolved: reopened, no cool-down
    // a thrown failure inside the watcher is a watcher-error; it says nothing about config, so the gap stays open
    const boom = { ...env, SERVICE_TARGETS: 'not json at all' } as Env;
    await env.EVENTS.delete('wd:last:services');
    await runWatchers('quarter', boom, brain, T0 + 60 * MIN);
    expect((await brain.state()).unconfigured).toContain('services');
  });
});

describe('N-2: a Mac claim of N jobs is not swept mid-run as its jobs report', () => {
  it('5 claimed, 4 reported by ~160 min: the 5th job is NOT swept', async () => {
    const h = await harness();
    await h.run((b) => b.reportUsage({ weeklyUsedPct: 10 }, T0));
    for (let i = 0; i < 5; i++) await h.run((b) => b.ingestFinding(docs({ key: `d${i}` }), T0 + i));
    const batch = (await h.run((b) => b.claim('mac-local', 5, T0 + MIN))) as HandsBatch;
    expect(batch.jobs).toHaveLength(5);
    for (const j of batch.jobs.slice(0, 4)) expect((await h.run((b) => b.recordOutcome(j.id, { status: 'pr_opened', prUrl: 'https://github.com/o/r/pull/1' }, T0 + 160 * MIN))).ok).toBe(true);
    expect(await h.run((b) => b.sweepStuckRuns(T0 + 161 * MIN))).toBe(0);
    const s = await h.run((b) => b.state(T0 + 161 * MIN));
    expect(s.jobs.running).toBe(1);
    expect(s.runs[0]).toMatchObject({ status: 'running' });
    expect((await h.run((b) => b.recordOutcome(batch.jobs[4]!.id, { status: 'pr_opened', prUrl: 'https://github.com/o/r/pull/2' }, T0 + 165 * MIN))).ok).toBe(true);
  });
  it('a run that really is stuck is still swept once the claim-time cap (45 x jobs + 10) passes', async () => {
    const h = await harness();
    await h.run((b) => b.reportUsage({ weeklyUsedPct: 10 }, T0));
    for (let i = 0; i < 5; i++) await h.run((b) => b.ingestFinding(docs({ key: `s${i}` }), T0 + i));
    await h.run((b) => b.claim('mac-local', 5, T0 + MIN));
    expect(await h.run((b) => b.sweepStuckRuns(T0 + MIN + 235 * MIN))).toBe(0);
    expect(await h.run((b) => b.sweepStuckRuns(T0 + MIN + 236 * MIN))).toBe(1);
  });
});

describe('M-3: a replayed GREEN cannot close a newer red', () => {
  it('the same signed run id + attempt twice: the second is ignored; a new red after the first green stays open', async () => {
    const h = await harness();
    const red = (): Finding => ({ source: 'ci', kind: 'ci-failure', key: 'o/r:CI', title: 'CI "CI" failing on main', repo: 'o/r' });
    await h.run((b) => b.ingestFinding(red(), T0));
    expect(await h.run((b) => b.resolveCi('o/r', 'CI', '900-1', T0 + MIN))).toBe(true);
    await h.run((b) => b.ingestFinding({ ...red(), detail: { sha: 'newer' } }, T0 + 2 * DAY)); // a newer red, after the cool-down (new evidence)
    // an attacker (or GitHub) replays the captured green under a new delivery id: same run id + attempt
    expect(await h.run((b) => b.resolveCi('o/r', 'CI', '900-1', T0 + 2 * DAY + MIN))).toBe(false);
    const s = await h.run((b) => b.state(T0 + 2 * DAY + HOUR));
    expect(s.findings.recent.find((f) => f.kind === 'ci-failure')?.status).not.toBe('resolved');
    // a genuinely new green run still closes it
    expect(await h.run((b) => b.resolveCi('o/r', 'CI', '901-1', T0 + 2 * DAY + 2 * HOUR))).toBe(true);
  });
});

describe('minor: webhooks lost during a brain outage are caught up from GitHub', () => {
  const run = (id: number, name: string, conclusion: string, updated: string, attempt = 1) => ({ id, name, conclusion, run_attempt: attempt, head_sha: `sha${id}`, head_branch: 'main', html_url: `https://github.com/o/r/actions/runs/${id}`, updated_at: updated, created_at: updated });
  function ctxWith(runs: unknown[], token: string | undefined = 'ghp_test', cfg = JSON.stringify({ repos: { 'o/r': {} } })) {
    const calls: string[] = [];
    const fetchImpl = (async (u: RequestInfo | URL) => {
      calls.push(String(u));
      if (String(u).endsWith('/repos/o/r')) return ok200({ default_branch: 'main' });
      if (String(u).includes('/actions/runs')) return ok200({ workflow_runs: runs });
      return new Response('nope', { status: 404 });
    }) as unknown as typeof fetch;
    return { calls, fetchImpl, token, cfg };
  }
  it('a red default-branch run the webhook never delivered becomes a CI finding; the newest GREEN per workflow resolves one', async () => {
    const h = await harness();
    const x = ctxWith([run(50, 'CI', 'failure', '2026-11-05T09:00:00Z'), run(40, 'CI', 'success', '2026-11-05T07:00:00Z'), run(51, 'Deploy', 'success', '2026-11-05T09:30:00Z')]);
    await h.run((b) => b.ingestFinding({ source: 'ci', kind: 'ci-failure', key: 'o/r:Deploy', title: 'CI "Deploy" failing on main', repo: 'o/r' }, T0 - HOUR));
    const ctx: WatchCtx = { env: { ...env, GITHUB_TOKEN: x.token, HANDS_CONFIG_JSON: x.cfg } as Env, sink: h.stub as unknown as WatchCtx['sink'], now: Date.parse('2026-11-05T10:00:00Z'), fetchImpl: x.fetchImpl };
    expect(await watchCiCatchup(ctx)).toMatchObject({ repos: 1, red: 1, green: 1 });
    await h.run((b) => b.processCiEvents(Date.parse('2026-11-05T10:01:00Z')));
    const s = await h.run((b) => b.state(Date.parse('2026-11-05T10:02:00Z')));
    const ci = s.findings.recent.filter((f) => f.kind === 'ci-failure');
    expect(ci.find((f) => f.title.includes('"CI"'))?.status).not.toBe('resolved');
    expect(ci.find((f) => f.title.includes('"Deploy"'))?.status).toBe('resolved');
    // idempotent: the same listing again raises nothing new
    expect(await watchCiCatchup(ctx)).toMatchObject({ red: 1 });
    expect((await h.run((b) => b.processCiEvents(Date.parse('2026-11-05T10:03:00Z')))).findings).toBe(0);
  });
  it('without GITHUB_TOKEN it reports one unconfigured note instead of silently doing nothing', async () => {
    const h = await harness();
    const x = ctxWith([], undefined);
    const ctx: WatchCtx = { env: { ...env, GITHUB_TOKEN: undefined, HANDS_CONFIG_JSON: x.cfg } as Env, sink: h.stub as unknown as WatchCtx['sink'], now: T0, fetchImpl: x.fetchImpl };
    await watchCiCatchup(ctx);
    expect((await h.run((b) => b.state(T0))).unconfigured).toEqual(['ci-catchup']);
    expect(x.calls).toHaveLength(0);
  });
});

describe('minor: a container that refuses to run (exit 3, egress lock) raises a P1, not a digest line', () => {
  it('POST /hands/refused with the hands token: P1 message, run failed, jobs back in the queue; deduped per day', async () => {
    const h = await harness();
    await h.run((b) => b.reportUsage({ weeklyUsedPct: 10 }, T0));
    await h.run((b) => b.ingestFinding(docs(), T0));
    const r = (await h.run((b) => b.runNightly(T0 + HOUR))) as { runId: string };
    expect(await h.run((b) => b.handsRefused(r.runId, 'cannot apply the egress rules', T0 + 2 * HOUR))).toEqual({ ok: true });
    expect(h.sent.filter((t) => /refused to run/.test(t))).toHaveLength(1);
    const s = await h.run((b) => b.state(T0 + 3 * HOUR));
    expect(s.runs[0]).toMatchObject({ status: 'failed' });
    expect(s.jobs).toMatchObject({ queuedNightly: 1, running: 0 });
    await h.run((b) => b.handsRefused(r.runId, 'cannot apply the egress rules', T0 + 4 * HOUR));
    expect(h.sent.filter((t) => /refused to run/.test(t))).toHaveLength(1);
  });
  it('the route needs the hands bearer token and a run id', async () => {
    const no = await SELF.fetch('https://brain.test/hands/refused', { method: 'POST', body: '{}' });
    expect(no.status).toBe(401);
    const tok = await runToken('test-hands-token', 'run_unknown');
    const bad = await SELF.fetch('https://brain.test/hands/refused', { method: 'POST', headers: { authorization: `Bearer ${tok}` }, body: JSON.stringify({ reason: 'x' }) });
    expect(bad.status).toBe(400);
    // F-06b: the bearer is the per-run token for exactly that run id; the shared secret and another run's token are refused
    const shared = await SELF.fetch('https://brain.test/hands/refused', { method: 'POST', headers: { authorization: 'Bearer test-hands-token' }, body: JSON.stringify({ runId: 'run_unknown', reason: 'egress' }) });
    expect(shared.status).toBe(401);
    const good = await SELF.fetch('https://brain.test/hands/refused', { method: 'POST', headers: { authorization: `Bearer ${tok}` }, body: JSON.stringify({ runId: 'run_unknown', reason: 'egress' }) });
    expect(good.status).toBe(200);
  });
});

describe('final review 3: a container run is swept at the container lifetime, not 45 min x the jobs', () => {
  it('25 nightly jobs in a container that dies at its 90-min cap: swept at +101 min and requeued the same night (not at 1135 min)', async () => {
    const h = await harness();
    await h.run((b) => b.reportUsage({ weeklyUsedPct: 10 }, T0));
    for (let i = 0; i < 25; i++) await h.run((b) => b.ingestFinding(docs({ key: `c${i}` }), T0 + i));
    const r = (await h.run((b) => b.runNightly(T0 + HOUR))) as { started: boolean; jobs: number };
    expect(r).toMatchObject({ started: true, jobs: 25 });
    expect(await h.run((b) => b.sweepStuckRuns(T0 + HOUR + 99 * MIN))).toBe(0);
    expect(await h.run((b) => b.sweepStuckRuns(T0 + HOUR + 101 * MIN))).toBe(1);
    expect((await h.run((b) => b.state(T0 + 4 * HOUR))).jobs).toMatchObject({ queuedNightly: 25, running: 0 });
  });
});

describe('final review 4: claim() and runNightly treat an unknown usage like dispatchUrgent', () => {
  it('no usage report yet + a real provider: a Mac claim gets ONE job (the bootstrap), not the batch; a report lifts the limit', async () => {
    const h = await harness();
    for (let i = 0; i < 3; i++) await h.run((b) => b.ingestFinding(docs({ key: `u${i}` }), T0 + i));
    const one = (await h.run((b) => b.claim('mac-local', 5, T0 + MIN))) as HandsBatch;
    expect(one.jobs).toHaveLength(1);
    await h.run((b) => b.reportUsage({ weeklyUsedPct: 10 }, T0 + 2 * MIN));
    const rest = (await h.run((b) => b.claim('mac-local', 5, T0 + 3 * MIN))) as HandsBatch;
    expect(rest.jobs).toHaveLength(2);
  });
  it('the nightly container with unknown usage starts with ONE job', async () => {
    const h = await harness();
    for (let i = 0; i < 3; i++) await h.run((b) => b.ingestFinding(docs({ key: `n${i}` }), T0 + i));
    expect(await h.run((b) => b.runNightly(T0 + HOUR))).toMatchObject({ started: true, jobs: 1 });
  });
});

describe('final review 4: usage-starved is a digest item, outside the urgent 3/day budget', () => {
  it('3 starved nightly batches: no Telegram message of its own; the next digest lists it; progress resolves it', async () => {
    const h = await harness();
    await h.run((b) => b.ingestFinding(docs(), T0));
    await h.run((b) => b.reportUsage({ weeklyUsedPct: 90 }, T0));
    for (let i = 1; i <= 3; i++) await h.run((b) => b.runNightly(T0 + i * DAY));
    expect(h.sent).toHaveLength(0);
    await h.run((b) => b.digest(T0 + 3 * DAY + HOUR));
    expect(h.sent).toHaveLength(1);
    expect(h.sent[0]).toMatch(/last 3 nightly batches did no work/);
    const s = await h.run((b) => b.state(T0 + 4 * DAY));
    expect(s.messages.sentToday).toBe(0); // the digest is not part of the 6/day budget
  });
});

describe('final review 10: timed_out is a failed CI run on both paths', () => {
  it('relay: a timed_out default-branch run maps to a ci-failure event; success and cancelled do not', async () => {
    const { mapEvent } = await import('../src/relay');
    const p = (conclusion: string) => ({ repository: { full_name: 'o/r' }, workflow_run: { conclusion, head_sha: 's1' } });
    expect(mapEvent('workflow_run', p('timed_out'))).toMatchObject({ kind: 'ci-failure' });
    expect(mapEvent('workflow_run', p('failure'))).toMatchObject({ kind: 'ci-failure' });
    expect(mapEvent('workflow_run', p('success'))).toBeNull();
    expect(mapEvent('workflow_run', p('cancelled'))).toBeNull();
  });
  it('ci-catchup: a timed_out latest run is red, same as failure; cancelled is ignored', async () => {
    const h = await harness();
    const runs = [
      { id: 70, name: 'A', conclusion: 'timed_out', run_attempt: 1, head_sha: 'a', html_url: 'https://github.com/o/r/actions/runs/70', updated_at: '2026-11-05T09:00:00Z' },
      { id: 71, name: 'B', conclusion: 'cancelled', run_attempt: 1, head_sha: 'b', html_url: 'https://github.com/o/r/actions/runs/71', updated_at: '2026-11-05T09:00:00Z' },
    ];
    const fetchImpl = (async (u: RequestInfo | URL) => (String(u).endsWith('/repos/o/r') ? Response.json({ default_branch: 'main' }) : Response.json({ workflow_runs: runs }))) as unknown as typeof fetch;
    const ctx: WatchCtx = { env: { ...env, GITHUB_TOKEN: 'x', HANDS_CONFIG_JSON: JSON.stringify({ repos: { 'o/r': {} } }) } as Env, sink: h.stub as unknown as WatchCtx['sink'], now: Date.parse('2026-11-05T10:00:00Z'), fetchImpl };
    expect(await watchCiCatchup(ctx)).toMatchObject({ red: 1, green: 0 });
  });
});
