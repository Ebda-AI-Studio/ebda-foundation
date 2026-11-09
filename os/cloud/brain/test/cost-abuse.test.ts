// Cost / abuse audit (2026-11-09): F-01 halt, F-04 container lifetime, budgets + model routing (RR-hands-api-auth), F-06 / F-06b, F-07, F-09,
// F-11, F-12, F-13, F-14. Each test is the audit's proving test.
import { env } from 'cloudflare:workers';
import { runInDurableObject, SELF } from 'cloudflare:test';
import { describe, expect, it } from 'vitest';
import type { BrainDO } from '../src/brain-do';
import { HAIKU_KINDS, modelFor } from '../src/brain-do';
import type { Env } from '../src/env';
import type { Finding } from '../src/findings';
import type { HandsBatch, HandsProvider } from '../src/hands';
import { buildContainerEnv, CEILING_MIN, HandsLifecycle } from '../src/hands-container';
import { runToken } from '../src/runtoken';

const T0 = Date.UTC(2026, 10, 5, 8, 0, 0);
const MIN = 60_000;
const HOUR = 60 * MIN;
const DAY = 24 * HOUR;

interface Rec extends HandsProvider { started: HandsBatch[]; stops: Array<{ kind: string; halt: boolean }>; resumes: string[] }
function rec(name = 'cloudflare-sandbox'): Rec {
  const r: Rec = {
    name, started: [], stops: [], resumes: [],
    start: async (b) => (r.started.push(b), { runId: b.runId, provider: name, startedAt: b.createdAt }),
    stop: async (kind, o) => (r.stops.push({ kind, halt: o?.halt === true }), { ok: true }),
    resume: async (kind) => (r.resumes.push(kind), { ok: true }),
  };
  return r;
}
async function harness(hands: HandsProvider = rec(), over: Partial<Env> = {}) {
  const stub = env.BRAIN.get(env.BRAIN.idFromName(crypto.randomUUID()));
  const sent: string[] = [];
  await runInDurableObject(stub, (b: BrainDO) => {
    b.hands = hands;
    b.mappedRepos = new Set(['o/r']);
    const x = b as unknown as { env: Env };
    x.env = { ...x.env, ...over } as Env;
    b.fetchImpl = (async (_u: RequestInfo | URL, init?: RequestInit) => {
      sent.push(JSON.parse(String(init?.body)).text);
      return new Response('{"ok":true}', { status: 200 });
    }) as typeof fetch;
  });
  return { stub, sent, run: <R>(fn: (b: BrainDO) => R | Promise<R>) => runInDurableObject(stub, (b: BrainDO) => fn(b)) };
}
const docs = (x: Partial<Finding> = {}): Finding => ({ source: 'watcher', kind: 'docs', key: crypto.randomUUID(), title: 'fix docs', repo: 'o/r', ...x });
const outage = (key: string): Finding => ({ source: 'health', kind: 'prod-outage', key, title: `${key} down`, repo: 'o/r', severity: 'P1', selfHealExhausted: true });

describe('F-01: one halt flag, checked before every container start', () => {
  it('halt on: runNightly, dispatchUrgent and claim start nothing; the provider records zero starts', async () => {
    const p = rec();
    const h = await harness(p);
    await h.run((b) => b.reportUsage({ weeklyUsedPct: 5 }, T0));
    await h.run((b) => b.ingestFinding(docs(), T0));
    await h.run((b) => b.ingestFinding(outage('x'), T0));
    await h.run((b) => b.setHalt('test halt', T0 + MIN));
    expect(await h.run((b) => b.runNightly(T0 + HOUR))).toMatchObject({ started: false, reason: expect.stringMatching(/halted/) });
    await h.run((b) => b.tick(T0 + HOUR));
    expect(await h.run((b) => b.claim('mac-local', 5, T0 + HOUR))).toMatchObject({ refused: expect.stringMatching(/halted/) });
    expect(p.started).toHaveLength(0);
    // both lanes' containers were told to stop and to refuse later starts
    expect(p.stops.map((s) => `${s.kind}:${s.halt}`).sort()).toEqual(['nightly:true', 'urgent:true']);
    expect((await h.run((b) => b.state(T0 + HOUR))).halt).toMatch(/test halt/);
    await h.run((b) => b.digest(T0 + HOUR));
    expect(h.sent.at(-1)).toMatch(/^Ebda OS daily digest[^\n]*\nHANDS HALTED: halted: test halt/);
    await h.run((b) => b.clearHalt(T0 + 2 * HOUR));
    expect(p.resumes.sort()).toEqual(['nightly', 'urgent']);
    expect(await h.run((b) => b.runNightly(T0 + 3 * HOUR))).toMatchObject({ started: true });
  });
  it('HANDS_HALT=1 on the Worker alone does the same', async () => {
    const p = rec();
    const h = await harness(p, { HANDS_HALT: '1' });
    await h.run((b) => b.ingestFinding(docs(), T0));
    expect(await h.run((b) => b.runNightly(T0 + HOUR))).toMatchObject({ started: false });
    expect(p.started).toHaveLength(0);
  });
  it('a cost-stop finding sets the halt and sends exactly ONE p1 message', async () => {
    const h = await harness(rec());
    const stop: Finding = { source: 'watcher', kind: 'cost-stop', key: 'cost-guard:cloudflare-requests:stop', title: 'Cloudflare Workers 10000001 requests this month (stop threshold)', severity: 'P1' };
    await h.run((b) => b.ingestFinding(stop, T0));
    await h.run((b) => b.ingestFinding(stop, T0 + MIN));
    expect((await h.run((b) => b.state(T0))).halt).toMatch(/Cloudflare Workers/);
    expect(h.sent.filter((t) => /HANDS HALTED|requests this month/.test(t))).toHaveLength(1);
  });
  it('POST /api/halt needs Access (fails closed here) and a same-origin boolean', async () => {
    const r = await SELF.fetch('https://brain.test/api/halt', { method: 'POST', body: JSON.stringify({ on: true }) });
    expect(r.status).toBe(503);
  });
});

describe('F-04: a container cannot outlive its cap, whatever state is lost', () => {
  function fake(opts: { running: boolean; destroyThrows?: boolean; run?: unknown }) {
    const store = new Map<string, unknown>();
    if (opts.run) store.set('run', opts.run);
    let alarm: number | null = null;
    const log: string[] = [];
    const container = {
      running: opts.running,
      start: () => (container.running = true, log.push('start')),
      destroy: async () => {
        log.push('destroy');
        if (opts.destroyThrows) throw new Error('boom');
        container.running = false;
      },
    };
    const ctx = {
      storage: { get: async (k: string) => store.get(k), put: async (k: string, v: unknown) => void store.set(k, v), delete: async (k: string) => store.delete(k), setAlarm: async (t: number) => void (alarm = t), deleteAlarm: async () => void (alarm = null), getAlarm: async () => alarm },
      container,
    };
    return { ctx, store, log, alarm: () => alarm };
  }
  it('alarm with the run state deleted and the container running: destroyed, alarm cleared (never re-armed on lost state)', async () => {
    const f = fake({ running: true });
    await new HandsLifecycle(f.ctx.storage as never, () => f.ctx.container, env).alarm();
    expect(f.log).toEqual(['destroy']);
    expect(f.alarm()).toBeNull();
  });
  it('destroy() throws: the alarm is already re-armed a minute out, so it is retried', async () => {
    const f = fake({ running: true, destroyThrows: true });
    const before = Date.now();
    await new HandsLifecycle(f.ctx.storage as never, () => f.ctx.container, env).alarm();
    expect(f.log).toEqual(['destroy']);
    expect(f.alarm()).toBeGreaterThanOrEqual(before + 59_000);
  });
  it('an absolute ceiling holds even when the stored deadline is forged far in the future', async () => {
    const startedAt = Date.now() - (CEILING_MIN + 1) * MIN;
    const f = fake({ running: true, run: { runId: 'r', kind: 'nightly', deadline: Date.now() + 99 * DAY, startedAt } });
    await new HandsLifecycle(f.ctx.storage as never, () => f.ctx.container, env).alarm();
    expect(f.log).toEqual(['destroy']);
  });
  it('a healthy run inside its cap is left alone and the alarm re-armed', async () => {
    const f = fake({ running: true, run: { runId: 'r', kind: 'nightly', deadline: Date.now() + HOUR, startedAt: Date.now() - MIN } });
    await new HandsLifecycle(f.ctx.storage as never, () => f.ctx.container, env).alarm();
    expect(f.log).toEqual([]);
    expect(f.alarm()).not.toBeNull();
  });
  it('/stop destroys now and /start answers 423 while halted (F-01 second line); /resume lifts it', async () => {
    const f = fake({ running: true });
    const hc = new HandsLifecycle(f.ctx.storage as never, () => f.ctx.container, { ...env, HANDS_CLAUDE_AUTH: 'max' } as Env);
    const stop = await hc.fetch(new Request('https://x/stop', { method: 'POST', body: JSON.stringify({ halt: true }) }));
    expect(stop.status).toBe(200);
    expect(f.log).toEqual(['destroy']);
    const start = () => hc.fetch(new Request('https://x/start', { method: 'POST', body: JSON.stringify({ runId: 'r1', kind: 'nightly', capMin: 30 }) }));
    expect((await start()).status).toBe(423);
    await hc.fetch(new Request('https://x/resume', { method: 'POST' }));
    expect((await start()).status).toBe(503); // no longer halted: now it only lacks secrets
  });
  it('/start with HANDS_HALT=1 on the var answers 423', async () => {
    const f = fake({ running: false });
    const r = await new HandsLifecycle(f.ctx.storage as never, () => f.ctx.container, { ...env, HANDS_HALT: '1' } as Env).fetch(new Request('https://x/start', { method: 'POST', body: JSON.stringify({ runId: 'r1', kind: 'nightly', capMin: 30 }) }));
    expect(r.status).toBe(423);
  });
  it('sweeping a timed-out cloudflare-sandbox run stops its container, not just the row', async () => {
    const p = rec();
    const h = await harness(p);
    await h.run((b) => b.ingestFinding(docs(), T0));
    await h.run((b) => b.runNightly(T0 + HOUR));
    expect(await h.run((b) => b.sweepStuckRuns(T0 + HOUR + 200 * MIN))).toBe(1);
    expect(p.stops).toContainEqual({ kind: 'nightly', halt: false });
  });
});

describe('F-06 / F-06b: the container env and the per-run credentials', () => {
  const base = { HANDS_BRAIN_URL: 'https://b.test', HANDS_TOKEN: 'k', HANDS_CONFIG_JSON: '{}', HANDS_GIT_NAME: 'n', HANDS_GIT_EMAIL: 'e', HANDS_GH_TOKEN: 'g', USAGE_WEEKLY_THRESHOLD_PCT: '80' } as Partial<Env>;
  const BILLABLE = ['ANTHROPIC_AUTH_TOKEN', 'ANTHROPIC_BASE_URL', 'CLAUDE_CODE_USE_BEDROCK', 'CLAUDE_CODE_USE_VERTEX', 'AWS_BEARER_TOKEN_BEDROCK', 'OPENAI_API_KEY', 'GEMINI_API_KEY'];
  it('api mode: exactly ONE billable key (ANTHROPIC_API_KEY), no OAuth token, none of the others; the bearer is the per-run HMAC, not HANDS_TOKEN', async () => {
    const e = await buildContainerEnv({ ...base, HANDS_ANTHROPIC_API_KEY: 'sk-test', HANDS_API_SPEND_LIMIT_USD: '150' }, 'run_1', null);
    expect(Object.keys(e)).toContain('ANTHROPIC_API_KEY');
    for (const k of [...BILLABLE, 'CLAUDE_CODE_OAUTH_TOKEN']) expect(Object.keys(e)).not.toContain(k);
    expect(e.HANDS_TOKEN).toBe(await runToken('k', 'run_1'));
    expect(e.HANDS_TOKEN).not.toBe('k');
    expect(e.HANDS_CLAUDE_AUTH).toBe('api');
    expect(e.ANTHROPIC_API_KEY).toBe('sk-test');
    expect(Object.keys(e)).not.toContain('HANDS_EGRESS_ALLOW'); // F-03: the brain host is not on Claude's allowlist
    expect(Object.keys(e)).not.toContain('HANDS_ANTHROPIC_API_KEY');
  });
  it('max mode: the OAuth token and no API key', async () => {
    const e = await buildContainerEnv({ ...base, HANDS_CLAUDE_AUTH: 'max', CLAUDE_CODE_OAUTH_TOKEN: 'o' }, 'run_1', null);
    expect(Object.keys(e)).toContain('CLAUDE_CODE_OAUTH_TOKEN');
    for (const k of [...BILLABLE, 'ANTHROPIC_API_KEY']) expect(Object.keys(e)).not.toContain(k);
  });
  it('the brain Worker never carries the hands key into the Mac path: the Mac token cannot read a container run and a run token cannot claim', async () => {
    const h = await harness(rec());
    await h.run((b) => b.ingestFinding(docs(), T0));
    await h.run((b) => b.reportUsage({ weeklyUsedPct: 5 }, T0));
    const r = (await h.run((b) => b.runNightly(T0 + HOUR))) as { runId: string };
    const macGet = await SELF.fetch(`https://brain.test/hands/runs/${r.runId}`, { headers: { Authorization: 'Bearer test-mac-token' } });
    expect(macGet.status).toBe(401);
    const runTok = await runToken('test-hands-token', r.runId);
    const claim = await SELF.fetch('https://brain.test/hands/claim', { method: 'POST', headers: { Authorization: `Bearer ${runTok}` }, body: '{}' });
    expect(claim.status).toBe(401);
  });
  it('usage: a forged 0 % after 70 % inside the same weekly window is ignored; a moved resetsAt starts a new window', async () => {
    const h = await harness(rec());
    const reset = T0 + 3 * DAY;
    await h.run((b) => b.reportUsage({ weeklyUsedPct: 70, resetsAt: reset }, T0));
    await h.run((b) => b.reportUsage({ weeklyUsedPct: 0, resetsAt: reset }, T0 + HOUR));
    expect((await h.run((b) => b.state(T0 + HOUR))).usage.report?.weeklyUsedPct).toBe(70);
    await h.run((b) => b.reportUsage({ weeklyUsedPct: 2, resetsAt: reset + 7 * DAY }, T0 + 4 * DAY));
    expect((await h.run((b) => b.state(T0 + 4 * DAY))).usage.report?.weeklyUsedPct).toBe(2);
  });
});

describe('RR-hands-api-auth: model routing and dollar budgets', () => {
  it('no job kind routes to opus by default; opus needs an explicit security/money-design flag; triage-like kinds are haiku', () => {
    const kinds = ['docs', 'test', 'tests', 'dep-bump', 'dependency-advisory', 'cve-bump', 'lockfile-drift', 'ci-failure', 'prod-outage', 'money-path-broken', 'lint', 'format', 'flaky-test', 'pr-stuck', 'data-exposure', 'secret-leak', 'unknown-kind'];
    for (const k of kinds) expect(modelFor({ source: 's', kind: k, key: 'k', title: 't' }, undefined)).not.toBe('opus');
    for (const k of HAIKU_KINDS) expect(modelFor({ source: 's', kind: k, key: 'k', title: 't' }, undefined)).toBe('haiku');
    expect(modelFor({ source: 's', kind: 'docs', key: 'k', title: 't', touches: ['money-design'] }, undefined)).toBe('opus');
    expect(modelFor({ source: 's', kind: 'docs', key: 'k', title: 't' }, 'opus')).not.toBe('opus'); // the default can be lowered, never raised
  });
  it('opus is capped per day: the 3rd flagged job of the day runs on sonnet; the model is recorded per job and per run', async () => {
    const p = rec();
    const h = await harness(p, { HANDS_OPUS_JOBS_PER_DAY: '2' });
    await h.run((b) => b.reportUsage({ weeklyUsedPct: 5 }, T0));
    for (let i = 0; i < 3; i++) await h.run((b) => b.ingestFinding(docs({ key: `o${i}`, touches: ['security-design'] }), T0 + i));
    await h.run((b) => b.ingestFinding(docs({ key: 'plain' }), T0 + 5));
    await h.run((b) => b.runNightly(T0 + HOUR));
    const models = p.started[0]!.jobs.map((j) => j.model).sort();
    expect(models).toEqual(['opus', 'opus', 'sonnet', 'sonnet']);
    expect(await h.run((b) => b.getMetaPublic(`run:models:${p.started[0]!.runId}`))).toEqual({ opus: 2, sonnet: 2 });
  });
  it('spend: 80 % of the month is a digest warning; 100 % halts and sends ONE p1; the daily budget blocks new runs until tomorrow', async () => {
    const p = rec();
    const h = await harness(p, { HANDS_MONTHLY_BUDGET_USD: '100', HANDS_DAILY_BUDGET_USD: '30' });
    const usage = (costUsd: number) => ({ model: 'sonnet', inputTokens: 1, outputTokens: 1, cacheReadTokens: 0, cacheWriteTokens: 0, costUsd });
    await h.run((b) => b.ingestFinding(docs({ key: 'a' }), T0));
    await h.run((b) => b.runNightly(T0 + HOUR));
    const job = p.started[0]!.jobs[0]!;
    await h.run((b) => b.recordOutcome(job.id, { status: 'merged', usage: usage(81) }, T0 + 2 * HOUR));
    expect(h.sent.filter((t) => /HALTED/.test(t))).toHaveLength(0);
    await h.run((b) => b.digest(T0 + 3 * HOUR));
    expect(h.sent.at(-1)).toMatch(/80%|81%/);
    expect(h.sent.at(-1)).toMatch(/Hands spend: \$81\.00 of \$100/);
    // a run today is blocked by the daily budget even though the month has room
    await h.run((b) => b.ingestFinding(docs({ key: 'b' }), T0 + 4 * HOUR));
    expect(await h.run((b) => b.runNightly(T0 + 5 * HOUR))).toMatchObject({ started: false, reason: expect.stringMatching(/daily budget/) });
    // tomorrow the daily budget is fresh again
    expect(await h.run((b) => b.runNightly(T0 + DAY + HOUR))).toMatchObject({ started: true });
    const job2 = p.started[1]!.jobs[0]!;
    await h.run((b) => b.recordOutcome(job2.id, { status: 'merged', usage: usage(20) }, T0 + DAY + 2 * HOUR));
    expect((await h.run((b) => b.state(T0 + DAY + 3 * HOUR))).halt).toMatch(/monthly hands budget reached/);
    expect(h.sent.filter((t) => /HANDS HALTED|monthly hands budget reached/.test(t))).toHaveLength(1);
    await h.run((b) => b.ingestFinding(docs({ key: 'c' }), T0 + 2 * DAY));
    expect(await h.run((b) => b.runNightly(T0 + 2 * DAY + HOUR))).toMatchObject({ started: false });
    expect(p.started).toHaveLength(2);
  });
  it('the batch tells the hands how many dollars they may still spend', async () => {
    const p = rec();
    const h = await harness(p, { HANDS_MONTHLY_BUDGET_USD: '100', HANDS_DAILY_BUDGET_USD: '30' });
    await h.run((b) => b.ingestFinding(docs(), T0));
    await h.run((b) => b.runNightly(T0 + HOUR));
    expect(p.started[0]!.budgetUsd).toBe(30);
  });
  it('an outcome usage block is validated (finite, non-negative)', async () => {
    const brain = (await import('../src/index')).brainStub(env);
    await brain.reportUsage({ weeklyUsedPct: 5 });
    await brain.ingestFinding(docs({ key: crypto.randomUUID() }));
    const batch = (await brain.claim("mac-local", 1)) as unknown as HandsBatch;
    const job = batch.jobs[0]!;
    const post = (usage: unknown) => SELF.fetch(`https://brain.test/hands/jobs/${job.id}/outcome`, { method: 'POST', headers: { Authorization: 'Bearer test-mac-token' }, body: JSON.stringify({ status: 'merged', usage }) });
    expect((await post({ model: 'sonnet', inputTokens: -1, outputTokens: 1, cacheReadTokens: 0, cacheWriteTokens: 0, costUsd: 1 })).status).toBe(400);
    expect((await post({ model: 'sonnet', inputTokens: 1, outputTokens: 1, cacheReadTokens: 0, cacheWriteTokens: 0, costUsd: 'x' })).status).toBe(400);
    expect((await post({ model: 'sonnet', inputTokens: 1, outputTokens: 1, cacheReadTokens: 0, cacheWriteTokens: 0, costUsd: 0.5 })).status).toBe(200);
  });
});

describe('F-07: the Mac has a daily cap too', () => {
  it('the 6th single-job claim of the day is refused; tomorrow it works again', async () => {
    const h = await harness(rec());
    await h.run((b) => b.reportUsage({ weeklyUsedPct: 5 }, T0));
    for (let i = 0; i < 7; i++) await h.run((b) => b.ingestFinding(docs({ key: `m${i}` }), T0 + i));
    for (let i = 0; i < 5; i++) expect(await h.run((b) => b.claim('mac-local', 1, T0 + (i + 1) * MIN))).toHaveProperty('runId');
    expect(await h.run((b) => b.claim('mac-local', 1, T0 + 10 * MIN))).toMatchObject({ refused: expect.stringMatching(/cap 5\/day/) });
    expect(await h.run((b) => b.claim('mac-local', 1, T0 + DAY + MIN))).toHaveProperty('runId');
  });
});

describe('F-09: question sends are bounded and honour retry_after', () => {
  async function qHarness(fetchImpl: (u: RequestInfo | URL) => Response) {
    const h = await harness(rec());
    const calls: number[] = [];
    await h.run((b) => { b.fetchImpl = (async (u: RequestInfo | URL) => (calls.push(Date.now()), fetchImpl(u))) as typeof fetch; });
    await h.run((b) => b.ingestFinding({ source: 'w', kind: 'auth-cookie', key: 'q1', title: 'cookie flags', repo: 'o/r' }, T0));
    return { h, calls };
  }
  it('a failing sender: exactly 3 attempts for one question, then undelivered (no per-tick resend)', async () => {
    const { h, calls } = await qHarness(() => new Response('x', { status: 500 }));
    for (let i = 0; i < 12; i++) await h.run((b) => b.tick(T0 + i * 5 * MIN)); // an hour of 5-minute ticks
    for (let i = 0; i < 6; i++) await h.run((b) => b.retryFailed(T0 + (i + 1) * 20 * MIN));
    expect(calls.length).toBe(3);
  });
  it('429 with retry_after 120: no retry before +120 s', async () => {
    const { h, calls } = await qHarness(() => Response.json({ ok: false, parameters: { retry_after: 120 } }, { status: 429 }));
    await h.run((b) => b.tick(T0));
    expect(calls.length).toBe(1);
    await h.run((b) => b.retryFailed(T0 + 119_000));
    expect(calls.length).toBe(1);
    await h.run((b) => b.retryFailed(T0 + 121_000));
    expect(calls.length).toBe(2);
  });
  it('401 (token revoked): zero further calls that day, even for other messages', async () => {
    const { h, calls } = await qHarness(() => new Response('{"ok":false}', { status: 401 }));
    await h.run((b) => b.tick(T0));
    const n = calls.length;
    await h.run((b) => b.ingestFinding(outage('z'), T0 + MIN));
    await h.run((b) => b.tick(T0 + 10 * MIN));
    await h.run((b) => b.retryFailed(T0 + 20 * MIN));
    expect(calls.length).toBe(n);
  });
});

describe('F-11: the BrainDO alarm never fires in the past or in a loop', () => {
  it('a throwing retry pass re-arms at +5 min; a row due in the past is clamped to >= now + 60 s', async () => {
    const h = await harness(rec());
    const now = Date.now();
    const armed = await h.run(async (b) => {
      b.retryFailed = async () => { throw new Error('boom'); };
      await b.alarm();
      return (b as unknown as { ctx: DurableObjectState }).ctx.storage.getAlarm();
    });
    expect(armed).toBeGreaterThanOrEqual(now + 4 * MIN);
    const h2 = await harness(rec());
    const a2 = await h2.run(async (b) => {
      (b as unknown as { sql: SqlStorage }).sql.exec(`INSERT INTO messages (dedupe_key, kind, day, status, text, at, attempts, next_at) VALUES ('k', 'p1-unhealed', '2026-11-05', 'failed', 't', 1, 1, ?)`, 1);
      b.fetchImpl = (async () => new Response('x', { status: 500 })) as typeof fetch;
      await b.alarm();
      return (b as unknown as { ctx: DurableObjectState }).ctx.storage.getAlarm();
    });
    expect(a2 === null || a2 >= now + 59_000).toBe(true);
  });
});

describe('F-13: no nightly batch during a GitHub or Anthropic outage', () => {
  it('an open major GitHub incident defers the batch; the jobs stay queued; when it resolves the batch runs', async () => {
    const p = rec();
    const h = await harness(p);
    await h.run((b) => b.ingestFinding(docs(), T0));
    const inc: Finding = { source: 'watcher', kind: 'vendor-incident', key: 'world-watch:GitHub:abc', title: 'GitHub incident (major): Actions degraded' };
    await h.run((b) => b.ingestFinding(inc, T0));
    expect(await h.run((b) => b.runNightly(T0 + HOUR))).toMatchObject({ started: false, reason: expect.stringMatching(/vendor outage/) });
    expect(p.started).toHaveLength(0);
    await h.run((b) => b.resolveFinding(inc, 'resolved', T0 + 2 * HOUR));
    expect(await h.run((b) => b.runNightly(T0 + 3 * HOUR))).toMatchObject({ started: true });
  });
  it('a Cloudflare incident does not block it', async () => {
    const h = await harness(rec());
    await h.run((b) => b.ingestFinding(docs(), T0));
    await h.run((b) => b.ingestFinding({ source: 'watcher', kind: 'vendor-incident', key: 'world-watch:Cloudflare:x', title: 'Cloudflare incident (major): dns' }, T0));
    expect(await h.run((b) => b.runNightly(T0 + HOUR))).toMatchObject({ started: true });
  });
});

describe('F-14: ingest size caps', () => {
  const post = (body: unknown) => SELF.fetch('https://brain.test/findings', { method: 'POST', headers: { Authorization: 'Bearer test-ingest-token' }, body: JSON.stringify(body) });
  it('a finding whose detail is over 8 KiB is refused', async () => {
    expect((await post({ source: 's', kind: 'docs', key: 'big', title: 't', detail: { blob: 'x'.repeat(9000) } })).status).toBe(400);
    expect((await post({ source: 's', kind: 'docs', key: 'ok-detail', title: 't', detail: { blob: 'x'.repeat(100) } })).status).toBe(200);
  });
  it('the per-day ingest ceiling answers 429 once spent', async () => {
    const h = await harness(rec(), { INGEST_PER_DAY: '5' });
    expect(await h.run((b) => b.admitIngest(3, T0))).toBe(true);
    expect(await h.run((b) => b.admitIngest(2, T0))).toBe(true);
    expect(await h.run((b) => b.admitIngest(1, T0))).toBe(false);
    expect(await h.run((b) => b.admitIngest(1, T0 + DAY))).toBe(true);
  });
});

describe('F-05: the footprint watcher', () => {
  const NOW = Date.UTC(2026, 10, 6, 12);
  function gql(values: Record<string, number | 'error'>) {
    return (async (_u: RequestInfo | URL, init?: RequestInit) => {
      const query = JSON.parse(String(init?.body)).query as string;
      const dataset = Object.keys(values).find((d) => query.includes(d))!;
      const v = values[dataset];
      if (v === 'error') return Response.json({ data: null, errors: [{ message: `unknown field ${dataset}` }] });
      const field = /sum\{(\w+)\}/.exec(query)![1]!;
      return Response.json({ data: { viewer: { accounts: [{ [dataset]: [{ sum: { [field]: v } }] }] } } });
    }) as typeof fetch;
  }
  async function run(values: Record<string, number | 'error'>, over: Partial<Env> = {}) {
    const h = await harness(rec());
    const { watchCfUsage } = await import('../src/watchers/cf-usage');
    const ctx = { env: { ...env, CF_API_TOKEN: 't', CF_ACCOUNT_ID: 'a'.repeat(32), ...over } as Env, sink: h.stub as never, now: NOW, fetchImpl: gql(values) };
    await watchCfUsage(ctx);
    return h;
  }
  const ok = { durableObjectsInvocationsAdaptiveGroups: 1000, durableObjectsPeriodicGroups: 500, kvOperationsAdaptiveGroups: 400, containersUsageAdaptiveGroups: 600, workersInvocationsAdaptive: 9000 };
  it('numbers over the stop threshold: the hands halt and exactly ONE p1 goes out', async () => {
    const h = await run({ ...ok, durableObjectsInvocationsAdaptiveGroups: 40_000 }, { CF_DO_REQUESTS_DAY: '33000' });
    expect((await h.run((b) => b.state(NOW))).halt).toMatch(/Durable Object requests/);
    expect(h.sent.filter((t) => /Durable Object requests/.test(t))).toHaveLength(1);
  });
  it('under 50 % of every limit: no finding, and the digest shows the footprint line', async () => {
    const h = await run(ok);
    expect((await h.run((b) => b.state(NOW))).halt).toBeNull();
    await h.run((b) => b.digest(NOW));
    expect(h.sent.at(-1)).toMatch(/Footprint \(24 h\): containers 20 min, DO requests 1000, DO rows written 500, KV writes 400/);
  });
  it('between 50 % and 100 %: a digest warning, no halt', async () => {
    const h = await run({ ...ok, kvOperationsAdaptiveGroups: 20_000 }, { CF_KV_WRITES_DAY: '33000' });
    const s = await h.run((b) => b.state(NOW));
    expect(s.halt).toBeNull();
    expect(s.findings.recent.some((f) => f.kind === 'cf-usage-warn')).toBe(true);
  });
  it('the dollar view: an estimated month at or above $20 halts (Ahmad\'s alert level) even when no single metric is over its own limit; $10 warns; under it is quiet', async () => {
    const huge = { CF_KV_WRITES_DAY: '100000000', CF_DO_REQUESTS_DAY: '100000000' }; // per-metric limits out of the way
    const stopRun = await run({ ...ok, kvOperationsAdaptiveGroups: 200_000 }, huge); // 6M writes/month = $25
    expect((await stopRun.run((b) => b.state(NOW))).halt).toMatch(/estimated spend \$25\.\d\d\/month/);
    expect(stopRun.sent.filter((t) => /estimated spend/.test(t))).toHaveLength(1);
    const warnRun = await run({ ...ok, kvOperationsAdaptiveGroups: 100_000 }, huge); // 3M writes/month = $10
    const s = await warnRun.run((b) => b.state(NOW));
    expect(s.halt).toBeNull();
    expect(s.findings.recent.some((f) => f.kind === 'cf-usage-warn' && /estimated spend/.test(f.title))).toBe(true);
    const quiet = await run(ok, huge);
    expect((await quiet.run((b) => b.state(NOW))).halt).toBeNull();
    await quiet.run((b) => b.digest(NOW));
    expect(quiet.sent.at(-1)).toMatch(/; est \$0\.\d\d\/month\./);
  });
  it('estimateMonthlyUsd follows the published rates above the included amounts', async () => {
    const { estimateMonthlyUsd } = await import('../src/watchers/cf-usage');
    expect(estimateMonthlyUsd({ doRequests: 1000, kvWrites: 1000, workersRequests: 1000, containerVcpuSec: 100 })).toBe(0); // inside the allowances
    expect(estimateMonthlyUsd({ kvWrites: 200_000 })).toBeCloseTo((6_000_000 - 1_000_000) / 1e6 * 5, 6);
    expect(estimateMonthlyUsd({ doRequests: 2_000_000 })).toBeCloseTo((60_000_000 - 1_000_000) / 1e6 * 0.15, 6);
    expect(estimateMonthlyUsd({ containerVcpuSec: 3600 * 24 })).toBeGreaterThan(20); // a standard-1 container up all day
  });
  it('GraphQL 200 + errors: a watcher-error and "footprint unknown", NEVER 0 and never a halt', async () => {
    const h = await run({ ...ok, containersUsageAdaptiveGroups: 'error' });
    const s = await h.run((b) => b.state(NOW));
    expect(s.footprint).toMatchObject({ unknown: true });
    expect(s.halt).toBeNull();
    expect(s.findings.recent.some((f) => f.kind === 'watcher-error' && /containerVcpuSec/.test(f.title + f.fp))).toBeDefined();
    await h.run((b) => b.digest(NOW));
    expect(h.sent.at(-1)).toMatch(/Footprint \(24 h\): unknown/);
    expect(h.sent.at(-1)).not.toMatch(/containers 0 min/);
  });
});

describe('F-12: GitHub App installation tokens', () => {
  it('mints one token per owner, narrowed to the run\'s repositories, contents + pull_requests write only', async () => {
    const { mintInstallationTokens } = await import('../src/gh-app');
    const kp = (await crypto.subtle.generateKey({ name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' }, true, ['sign', 'verify'])) as CryptoKeyPair;
    const pk8 = new Uint8Array((await crypto.subtle.exportKey('pkcs8', kp.privateKey)) as ArrayBuffer);
    let bin = '';
    for (const b of pk8) bin += String.fromCharCode(b);
    const pem = `-----BEGIN PRIVATE KEY-----\n${btoa(bin)}\n-----END PRIVATE KEY-----`;
    const seen: Array<{ url: string; body: any; auth: string }> = [];
    const fetchImpl = (async (u: RequestInfo | URL, init?: RequestInit) => {
      seen.push({ url: String(u), body: JSON.parse(String(init?.body)), auth: String((init?.headers as Record<string, string>).authorization) });
      return Response.json({ token: `ghs_${seen.length}` }, { status: 201 });
    }) as typeof fetch;
    const out = await mintInstallationTokens({ GH_APP_ID: '123', GH_APP_PRIVATE_KEY: pem, GH_APP_INSTALLATIONS: JSON.stringify({ 'Ebda-AI-Studio': 11, 'Whisky-11': 22 }) }, ['Ebda-AI-Studio/ebda-store', 'Ebda-AI-Studio/ebda-whatsapp', 'Whisky-11/x'], fetchImpl, T0);
    expect(out).toEqual({ 'Ebda-AI-Studio': 'ghs_1', 'Whisky-11': 'ghs_2' });
    expect(seen[0]!.url).toBe('https://api.github.com/app/installations/11/access_tokens');
    expect(seen[0]!.body).toEqual({ repositories: ['ebda-store', 'ebda-whatsapp'], permissions: { contents: 'write', pull_requests: 'write' } });
    expect(JSON.stringify(seen[0]!.body)).not.toMatch(/workflows|administration/);
    expect(seen[0]!.auth).toMatch(/^Bearer [\w-]+\.[\w-]+\.[\w-]+$/);
  });
  it('an owner without an installation, or a refused mint, throws (the container start is refused, never silently downgraded to the PAT)', async () => {
    const { mintInstallationTokens } = await import('../src/gh-app');
    await expect(mintInstallationTokens({ GH_APP_ID: '1', GH_APP_PRIVATE_KEY: 'x', GH_APP_INSTALLATIONS: '{}' }, ['o/r'], (async () => new Response('x')) as typeof fetch, T0)).rejects.toBeDefined();
  });
});

describe('F-16 / F-03: the platform egress policy and the model-API request check', () => {
  it('only the short host list (and the brain host) is reachable; example.com is not', async () => {
    const { hostAllowed } = await import('../src/egress-policy');
    for (const h of ['github.com', 'api.github.com', 'registry.npmjs.org', 'api.anthropic.com']) expect(hostAllowed(h)).toBe(true);
    expect(hostAllowed('example.com')).toBe(false);
    expect(hostAllowed('brain.example.dev', 'brain.example.dev')).toBe(true);
    expect(hostAllowed('github.com.evil.example')).toBe(false);
  });
  it('api mode: our key on POST /v1/messages passes; a different key, the Files API, a GET, or an Authorization header is refused', async () => {
    const { checkAnthropicRequest } = await import('../src/egress-policy');
    const cred = { mode: 'api' as const, secret: 'sk-ours' };
    const call = (m: string, path: string, h: Record<string, string>) => checkAnthropicRequest(m, `https://api.anthropic.com${path}`, h, cred).allowed;
    expect(call('POST', '/v1/messages', { 'x-api-key': 'sk-ours' })).toBe(true);
    expect(call('POST', '/v1/messages/count_tokens?beta=true', { 'X-Api-Key': 'sk-ours' })).toBe(true);
    expect(call('POST', '/v1/messages', { 'x-api-key': 'sk-attacker' })).toBe(false);
    expect(call('POST', '/v1/files', { 'x-api-key': 'sk-ours' })).toBe(false);
    expect(call('POST', '/v1/files/abc/content', { 'x-api-key': 'sk-ours' })).toBe(false);
    expect(call('GET', '/v1/messages', { 'x-api-key': 'sk-ours' })).toBe(false);
    expect(call('POST', '/v1/messages', { 'x-api-key': 'sk-ours', authorization: 'Bearer other' })).toBe(false);
  });
  it('max mode: only our OAuth token; any x-api-key is refused', async () => {
    const { checkAnthropicRequest } = await import('../src/egress-policy');
    const cred = { mode: 'max' as const, secret: 'oat' };
    expect(checkAnthropicRequest('POST', 'https://api.anthropic.com/v1/messages', { authorization: 'Bearer oat' }, cred).allowed).toBe(true);
    expect(checkAnthropicRequest('POST', 'https://api.anthropic.com/v1/messages', { authorization: 'Bearer oat', 'x-api-key': 'k' }, cred).allowed).toBe(false);
    expect(checkAnthropicRequest('POST', 'https://api.anthropic.com/v1/messages', { authorization: 'Bearer nope' }, cred).allowed).toBe(false);
  });
});

describe('F-15: the cron fan-out stays far under the subrequest limit', () => {
  it('the worst-case fetches of every cron group sum to <= 500 (the config limit), computed from the caps in the code', async () => {
    const { GROUPS } = await import('../src/watchers/run');
    // worst case per watcher, from its caps: services 12 targets, page-load 20 x 3 samples, journeys 20 steps, drift 20, pr-shepherd 10 orgs,
    // cf-workers 3, sentry 10 projects, cost-guard 2, world 8 + npm 20, dr-drill 0, ci-catchup 20 repos x 2, cf-usage 5, advisories 10 orgs x pages
    const worst: Record<string, number> = { services: 12, 'page-load': 60, 'journey-monitor': 20, 'deploy-drift': 20, 'pr-shepherd': 10, 'ci-catchup': 40, 'cf-workers': 3, 'sentry-stale': 10, 'cost-guard': 2, 'cf-usage': 5, 'world-watch': 28, 'dr-drill': 0 };
    for (const [group, entries] of Object.entries(GROUPS)) {
      const sum = entries.reduce((a, e) => a + (worst[e.id] ?? 1000), 0) + 5 /* telegram / KV overhead */;
      expect(sum, `group ${group}`).toBeLessThanOrEqual(500);
    }
    // every watcher in a group has a declared worst case (a new watcher without one fails here, not in production)
    for (const e of Object.values(GROUPS).flat()) expect(worst[e.id], e.id).toBeDefined();
  });
});

describe('C1 / I1: spend is metered as it happens, charged pessimistically when unseen, and recorded even late', () => {
  const NOW = T0;
  async function started(h: Awaited<ReturnType<typeof harness>>, p: Rec, n = 1) {
    await h.run((b) => b.reportUsage({ weeklyUsedPct: 5 }, NOW));
    for (let i = 0; i < n; i++) await h.run((b) => b.ingestFinding(docs({ key: `m${i}` }), NOW + i));
    const r = (await h.run((b) => b.runNightly(NOW + HOUR))) as { runId: string };
    return { runId: r.runId, jobs: p.started[0]!.jobs };
  }
  const call = (costUsd: number) => ({ model: 'claude-sonnet-5-5', inputTokens: 10, outputTokens: 5, cacheReadTokens: 0, cacheWriteTokens: 0, costUsd });
  const monthSpend = async (h: Awaited<ReturnType<typeof harness>>, at = NOW + 2 * HOUR) => (await h.run((b) => b.state(at))).spend.month;

  it('meter posts add spend per call, per run; an outcome that follows does not charge the job twice', async () => {
    const p = rec();
    const h = await harness(p);
    const { runId, jobs } = await started(h, p);
    await h.run((b) => b.recordMeter(runId, { jobId: jobs[0]!.id, started: true }));
    await h.run((b) => b.recordMeter(runId, { jobId: jobs[0]!.id, ...call(0.4) }, NOW + HOUR));
    await h.run((b) => b.recordMeter(runId, { jobId: jobs[0]!.id, ...call(0.6) }, NOW + HOUR));
    expect(await monthSpend(h)).toBeCloseTo(1.0, 6);
    await h.run((b) => b.recordOutcome(jobs[0]!.id, { status: 'merged', claudeRan: true, metered: true, usage: call(1.0) }, NOW + 2 * HOUR));
    expect(await monthSpend(h)).toBeCloseTo(1.0, 6); // the meter already charged it
  });
  it('a meter post for a job outside the run is refused (nothing charged)', async () => {
    const p = rec();
    const h = await harness(p);
    const { jobs } = await started(h, p);
    expect(await h.run((b) => b.recordMeter('run_other', { jobId: jobs[0]!.id, ...call(9) }))).toEqual({ ok: false });
    expect(await monthSpend(h)).toBe(0);
  });
  it('C1: a job that started Claude, was killed, and is swept with NO reading is charged the pessimistic amount (config, never $0), once per attempt', async () => {
    const p = rec();
    const h = await harness(p, { HANDS_JOB_PESSIMISTIC_USD: '3' });
    const { runId, jobs } = await started(h, p);
    await h.run((b) => b.recordMeter(runId, { jobId: jobs[0]!.id, started: true }));
    expect(await h.run((b) => b.sweepStuckRuns(NOW + HOUR + 200 * MIN))).toBe(1);
    expect(await monthSpend(h, NOW + 5 * HOUR)).toBeCloseTo(3, 6);
    // the job is requeued; a second attempt that dies again is charged again (each attempt is real spend)
    const r2 = (await h.run((b) => b.runNightly(NOW + DAY))) as { runId: string };
    const job2 = p.started[1]!.jobs[0]!;
    await h.run((b) => b.recordMeter(r2.runId, { jobId: job2.id, started: true }));
    await h.run((b) => b.sweepStuckRuns(NOW + DAY + 200 * MIN));
    expect(await monthSpend(h, NOW + DAY + 5 * HOUR)).toBeCloseTo(6, 6);
  });
  it('a swept job that never started Claude (queued behind a dead run) is not charged; a metered one is not charged again', async () => {
    const p = rec();
    const h = await harness(p, { HANDS_JOB_PESSIMISTIC_USD: '3' });
    const { runId, jobs } = await started(h, p, 2);
    await h.run((b) => b.recordMeter(runId, { jobId: jobs[0]!.id, started: true }));
    await h.run((b) => b.recordMeter(runId, { jobId: jobs[0]!.id, ...call(0.5) }, NOW + HOUR));
    await h.run((b) => b.sweepStuckRuns(NOW + HOUR + 200 * MIN));
    expect(await monthSpend(h, NOW + 5 * HOUR)).toBeCloseTo(0.5, 6);
  });
  it('an outcome with claudeRan and no reading at all is charged the pessimistic amount; one with no Claude run costs nothing', async () => {
    const p = rec();
    const h = await harness(p, { HANDS_JOB_PESSIMISTIC_USD: '2' });
    const { jobs } = await started(h, p, 2);
    await h.run((b) => b.recordOutcome(jobs[0]!.id, { status: 'timed_out', claudeRan: true, metered: false }, NOW + 2 * HOUR));
    await h.run((b) => b.recordOutcome(jobs[1]!.id, { status: 'could_not_fix', note: 'clone failed' }, NOW + 2 * HOUR));
    expect(await monthSpend(h)).toBeCloseTo(2, 6);
  });
  it('I1: the usage of a LATE outcome (the job was already swept) is still recorded, and only then is the state change refused', async () => {
    const p = rec();
    const h = await harness(p);
    const { jobs } = await started(h, p);
    await h.run((b) => b.sweepStuckRuns(NOW + HOUR + 200 * MIN)); // times the run out: the job is no longer `running`
    const r = await h.run((b) => b.recordOutcome(jobs[0]!.id, { status: 'merged', claudeRan: true, usage: call(1.5) }, NOW + 6 * HOUR));
    expect(r).toMatchObject({ ok: false, reason: expect.stringMatching(/not running/) });
    expect(await monthSpend(h, NOW + 7 * HOUR)).toBeCloseTo(1.5, 6);
    // a second copy of the same late outcome does not charge twice
    await h.run((b) => b.recordOutcome(jobs[0]!.id, { status: 'merged', claudeRan: true, usage: call(1.5) }, NOW + 8 * HOUR));
    expect(await monthSpend(h, NOW + 9 * HOUR)).toBeCloseTo(1.5, 6);
  });
  it('POST /hands/meter needs the run token; a Mac token or another run\'s token is refused', async () => {
    const body = JSON.stringify({ runId: 'run_x', jobId: 'job_x', started: true });
    expect((await SELF.fetch('https://brain.test/hands/meter', { method: 'POST', body })).status).toBe(401);
    expect((await SELF.fetch('https://brain.test/hands/meter', { method: 'POST', headers: { Authorization: 'Bearer test-mac-token' }, body })).status).toBe(401);
    const tok = await runToken('test-hands-token', 'run_x');
    expect((await SELF.fetch('https://brain.test/hands/meter', { method: 'POST', headers: { Authorization: `Bearer ${tok}` }, body })).status).toBe(200);
    const bad = JSON.stringify({ runId: 'run_x', jobId: 'job_x', model: 'm', inputTokens: -1, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0, costUsd: 1 });
    expect((await SELF.fetch('https://brain.test/hands/meter', { method: 'POST', headers: { Authorization: `Bearer ${tok}` }, body: bad })).status).toBe(400);
  });
});
