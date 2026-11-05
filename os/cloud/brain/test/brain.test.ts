// Pipeline tests on workerd: the real BrainDO (SQLite storage) with a recording hands provider and a fake Telegram.
import { env } from 'cloudflare:workers';
import { runInDurableObject } from 'cloudflare:test';
import { describe, expect, it } from 'vitest';
import type { BrainDO } from '../src/brain-do';
import type { Finding } from '../src/findings';
import { StubHandsProvider } from '../src/hands';

const T0 = Date.UTC(2026, 10, 5, 8, 0, 0);
const MIN = 60_000;
const HOUR = 60 * MIN;

interface Harness {
  stub: DurableObjectStub<BrainDO>;
  hands: StubHandsProvider;
  sent: Array<{ text: string; buttons?: unknown }>;
  run<R>(fn: (b: BrainDO) => R | Promise<R>): Promise<R>;
}

async function harness(): Promise<Harness> {
  const stub = env.BRAIN.get(env.BRAIN.idFromName(crypto.randomUUID()));
  const hands = new StubHandsProvider();
  const sent: Harness['sent'] = [];
  await runInDurableObject(stub, (b: BrainDO) => {
    b.hands = hands;
    b.fetchImpl = (async (_url: RequestInfo | URL, init?: RequestInit) => {
      const body = JSON.parse(String(init?.body));
      sent.push({ text: body.text, buttons: body.reply_markup });
      return new Response(JSON.stringify({ ok: true }), { status: 200 });
    }) as typeof fetch;
  });
  return { stub, hands, sent, run: (fn) => runInDurableObject(stub, (b: BrainDO) => fn(b)) };
}

const finding = (x: Partial<Finding> = {}): Finding => ({ source: 'watcher', kind: 'docs', key: crypto.randomUUID(), title: 'fix docs', repo: 'o/r', ...x });

describe('dedupe', () => {
  it('the same fingerprint is raised once; repeats only bump the count', async () => {
    const h = await harness();
    const f = finding({ key: 'same' });
    const a = await h.run((b) => b.ingestFinding(f, T0));
    const b2 = await h.run((b) => b.ingestFinding(f, T0 + MIN));
    expect(a.deduped).toBe(false);
    expect(b2).toMatchObject({ deduped: true, fp: a.fp, jobId: null });
    const s = await h.run((b) => b.state(T0 + MIN));
    expect(s.jobs.queuedNightly).toBe(1);
    expect(s.findings.recent[0]).toMatchObject({ seen_count: 2 });
  });
  it('a recurrence after a terminal state reopens the same row instead of a second finding', async () => {
    const h = await harness();
    const f = finding({ key: 'recur' });
    await h.run((b) => b.ingestFinding(f, T0));
    await h.run((b) => b.resolveFinding(f, 'fixed upstream', T0 + MIN));
    const again = await h.run((b) => b.ingestFinding(f, T0 + 2 * MIN));
    expect(again).toMatchObject({ deduped: false, reopened: true });
    const s = await h.run((b) => b.state(T0 + 2 * MIN));
    expect(s.findings.recent).toHaveLength(1);
  });
});

describe('nightly batch', () => {
  it('drains the queue into ONE run through the hands provider; empty queue starts nothing', async () => {
    const h = await harness();
    await h.run((b) => b.ingestFinding(finding({ kind: 'docs' }), T0));
    await h.run((b) => b.ingestFinding(finding({ kind: 'lint' }), T0));
    const r = await h.run((b) => b.runNightly(T0 + HOUR));
    expect(r).toMatchObject({ started: true, jobs: 2 });
    expect(h.hands.started).toHaveLength(1);
    expect(h.hands.started[0]!.jobs.map((j) => j.mergePolicy)).toEqual(['auto-when-gate-green', 'auto-when-gate-green']);
    const again = await h.run((b) => b.runNightly(T0 + 2 * HOUR));
    expect(again).toMatchObject({ started: false, reason: expect.stringMatching(/queue empty/) });
    expect(h.hands.started).toHaveLength(1);
    const batch = await h.run((b) => b.getRun(r.runId!));
    expect(batch?.jobs).toHaveLength(2);
  });
  it('the usage guard refuses to start hands work at the threshold', async () => {
    const h = await harness();
    await h.run((b) => b.ingestFinding(finding(), T0));
    await h.run((b) => b.reportUsage({ weeklyUsedPct: 85 }, T0));
    const r = await h.run((b) => b.runNightly(T0 + HOUR));
    expect(r).toMatchObject({ started: false, reason: expect.stringMatching(/85% >= threshold 80%/) });
    expect(h.hands.started).toHaveLength(0);
    const claim = await h.run((b) => b.claim('mac-local', 5, T0 + HOUR));
    expect(claim).toMatchObject({ refused: expect.stringMatching(/threshold/) });
  });
  it('outcomes close the finding; skipped_usage puts the job back in the queue', async () => {
    const h = await harness();
    await h.run((b) => b.ingestFinding(finding({ title: 'A' }), T0));
    await h.run((b) => b.ingestFinding(finding({ title: 'B' }), T0));
    const r = await h.run((b) => b.runNightly(T0 + HOUR));
    const [j1, j2] = h.hands.started[0]!.jobs;
    expect(await h.run((b) => b.recordOutcome(j1!.id, { status: 'merged', prUrl: 'https://pr/1' }, T0 + 2 * HOUR))).toEqual({ ok: true });
    expect(await h.run((b) => b.recordOutcome(j1!.id, { status: 'merged' }, T0 + 2 * HOUR))).toMatchObject({ ok: false });
    await h.run((b) => b.recordOutcome(j2!.id, { status: 'skipped_usage' }, T0 + 2 * HOUR));
    const s = await h.run((b) => b.state(T0 + 2 * HOUR));
    expect(s.jobs.queuedNightly).toBe(1);
    expect(s.runs.find((x) => x.id === r.runId)).toMatchObject({ status: 'done' });
    expect(h.sent).toHaveLength(0); // nightly outcomes go to the digest, not a message each
  });
});

describe('urgent lane (Amendment A.1)', () => {
  const outage = (key: string): Finding => ({ source: 'health', kind: 'prod-outage', key, title: `${key} down`, severity: 'P1', selfHealExhausted: true });

  it('starts one immediate run with one job and a 30-minute cap; the next urgent job waits', async () => {
    const h = await harness();
    await h.run((b) => b.ingestFinding(outage('a'), T0));
    await h.run((b) => b.ingestFinding(outage('b'), T0));
    await h.run((b) => b.tick(T0));
    expect(h.hands.started).toHaveLength(1);
    expect(h.hands.started[0]).toMatchObject({ kind: 'urgent', perJobCapMin: 30 });
    expect(h.hands.started[0]!.jobs).toHaveLength(1);
    await h.run((b) => b.tick(T0 + 5 * MIN));
    expect(h.hands.started).toHaveLength(1); // one at a time
    await h.run((b) => b.recordOutcome(h.hands.started[0]!.jobs[0]!.id, { status: 'fix_deployed' }, T0 + 10 * MIN));
    expect(h.sent).toHaveLength(1);
    expect(h.sent[0]!.text).toMatch(/urgent: fix deployed/);
    await h.run((b) => b.tick(T0 + 15 * MIN));
    expect(h.hands.started).toHaveLength(2);
  });

  it('caps urgent runs at 3 a day; the 4th is queued for tonight and messaged once', async () => {
    const h = await harness();
    for (const k of ['a', 'b', 'c', 'd']) await h.run((b) => b.ingestFinding(outage(k), T0));
    for (let i = 0; i < 3; i++) {
      await h.run((b) => b.tick(T0 + i * 10 * MIN));
      const job = h.hands.started.at(-1)!.jobs[0]!;
      await h.run((b) => b.recordOutcome(job.id, { status: 'could_not_fix' }, T0 + i * 10 * MIN + MIN));
    }
    expect(h.hands.started).toHaveLength(3);
    await h.run((b) => b.tick(T0 + 40 * MIN));
    await h.run((b) => b.tick(T0 + 45 * MIN));
    expect(h.hands.started).toHaveLength(3);
    const p1 = h.sent.filter((m) => /not handled yet/.test(m.text));
    expect(p1).toHaveLength(1);
    expect(p1[0]!.text).toMatch(/urgent cap 3\/day/);
    const s = await h.run((b) => b.state(T0 + 45 * MIN));
    expect(s.jobs).toMatchObject({ queuedUrgent: 0, queuedNightly: 1 });
  });

  it('a run with no outcome past its cap is timed out, reported once, and frees the slot', async () => {
    const h = await harness();
    await h.run((b) => b.ingestFinding(outage('slow'), T0));
    await h.run((b) => b.tick(T0));
    await h.run((b) => b.tick(T0 + 41 * MIN));
    expect(h.sent.filter((m) => /could NOT fix in time/.test(m.text))).toHaveLength(1);
    const s = await h.run((b) => b.state(T0 + 41 * MIN));
    expect(s.runs[0]).toMatchObject({ status: 'timed_out' });
  });

  it('the usage guard also blocks urgent runs (message once, queued for tonight)', async () => {
    const h = await harness();
    await h.run((b) => b.reportUsage({ weeklyUsedPct: 90 }, T0));
    await h.run((b) => b.ingestFinding(outage('x'), T0));
    await h.run((b) => b.tick(T0));
    expect(h.hands.started).toHaveLength(0);
    expect(h.sent).toHaveLength(1);
    expect(h.sent[0]!.text).toMatch(/90% >= threshold/);
  });
});

describe('questions and the Telegram budget', () => {
  const sensitive = (i: number): Finding => finding({ kind: 'payout-rounding', title: `payout fix ${i}` });

  it('a question goes out once with options + default + deadline; proceed queues the work for the nightly batch', async () => {
    const h = await harness();
    await h.run((b) => b.ingestFinding(sensitive(1), T0));
    await h.run((b) => b.tick(T0));
    await h.run((b) => b.tick(T0 + 5 * MIN));
    expect(h.sent).toHaveLength(1);
    expect(h.sent[0]!.text).toMatch(/Options: proceed \/ hold/);
    const q = (await h.run((b) => b.state(T0))).questions[0]!;
    expect(await h.run((b) => b.answerQuestion(String(q.id), 'proceed', T0 + HOUR))).toEqual({ ok: true });
    expect(await h.run((b) => b.answerQuestion(String(q.id), 'hold', T0 + HOUR))).toMatchObject({ ok: false });
    await h.run((b) => b.runNightly(T0 + 2 * HOUR));
    expect(h.hands.started[0]!.jobs[0]).toMatchObject({ answer: 'proceed', mergePolicy: 'pr-and-question' });
  });

  it('reversible questions take the default after the deadline; destructive ones never proceed on silence', async () => {
    const h = await harness();
    await h.run((b) => b.ingestFinding(sensitive(1), T0));
    await h.run((b) => b.ingestFinding(finding({ kind: 'cleanup', touches: ['data-deletion'], title: 'drop old rows' }), T0));
    await h.run((b) => b.tick(T0));
    await h.run((b) => b.tick(T0 + 25 * HOUR));
    const s = await h.run((b) => b.state(T0 + 25 * HOUR));
    expect(s.questions).toHaveLength(1);
    expect(s.questions[0]).toMatchObject({ default_opt: 'hold', reversible: 0 });
    expect(s.jobs.queuedNightly).toBe(1); // the reversible one defaulted to proceed
  });

  it('at most 3 non-digest messages a day; the rest roll into the ONE digest, which goes once', async () => {
    const h = await harness();
    for (let i = 0; i < 5; i++) await h.run((b) => b.ingestFinding(sensitive(i), T0));
    await h.run((b) => b.tick(T0));
    await h.run((b) => b.tick(T0 + 5 * MIN));
    expect(h.sent).toHaveLength(3);
    expect(await h.run((b) => b.digest(T0 + HOUR))).toBe('sent');
    expect(await h.run((b) => b.digest(T0 + 2 * HOUR))).toBe('duplicate');
    expect(h.sent).toHaveLength(4);
    expect(h.sent[3]!.text).toMatch(/Waiting for you:/);
    expect(h.sent[3]!.text).toMatch(/payout fix 3/);
    const s = await h.run((b) => b.state(T0 + 2 * HOUR));
    expect(s.questions.every((q) => q.status === 'sent')).toBe(true);
  });

  it('missing Telegram secrets record a failed send instead of throwing', async () => {
    const h = await harness();
    await h.run((b) => {
      b.fetchImpl = (() => Promise.reject(new Error('offline'))) as unknown as typeof fetch;
    });
    await h.run((b) => b.ingestFinding(sensitive(9), T0));
    await h.run((b) => b.tick(T0));
    expect((await h.run((b) => b.state(T0))).messages.failed).toBe(1);
  });
});

describe('acted-on ratio and the 24 h self-check', () => {
  it('a finding unacted for 24 h is an OS bug; dispatch clears it and the ratio counts it', async () => {
    const h = await harness();
    await h.run((b) => b.ingestFinding(finding(), T0));
    expect(await h.run((b) => b.selfCheck(T0 + 23 * HOUR))).toHaveLength(0);
    expect(await h.run((b) => b.selfCheck(T0 + 25 * HOUR))).toHaveLength(1);
    expect(await h.run((b) => b.actedOn(T0 + 25 * HOUR, 7 * 24 * HOUR))).toEqual({ raised: 1, acted: 0, ratio: 0 });
    await h.run((b) => b.runNightly(T0 + 25 * HOUR));
    expect(await h.run((b) => b.selfCheck(T0 + 26 * HOUR))).toHaveLength(0);
    expect(await h.run((b) => b.actedOn(T0 + 26 * HOUR, 7 * 24 * HOUR))).toEqual({ raised: 1, acted: 1, ratio: 1 });
  });
  it('a question that was asked counts as acted', async () => {
    const h = await harness();
    await h.run((b) => b.ingestFinding(finding({ kind: 'auth-flow' }), T0));
    await h.run((b) => b.tick(T0));
    expect(await h.run((b) => b.selfCheck(T0 + 25 * HOUR))).toHaveLength(0);
  });
});

describe('CI watcher (webhook inbox) and health watcher', () => {
  const ev = (id: string, branch: string, workflow = 'CI') => ({ id, slug: 'o/r', sha: id, workflow, branch, defaultBranch: 'main', url: 'https://run', ts: T0 });

  it('default-branch failures become one finding per repo+workflow; PR branches are ignored', async () => {
    const h = await harness();
    expect(await h.run((b) => b.ingestCiEvent(ev('d1', 'main')))).toBe(true);
    expect(await h.run((b) => b.ingestCiEvent(ev('d1', 'main')))).toBe(false); // GitHub redelivery
    await h.run((b) => b.ingestCiEvent(ev('d2', 'main')));
    await h.run((b) => b.ingestCiEvent(ev('d3', 'feat/x')));
    expect(await h.run((b) => b.processCiEvents(T0))).toEqual({ processed: 3, findings: 1 });
    expect(await h.run((b) => b.resolveFinding({ source: 'ci', kind: 'ci-failure', key: 'o/r:CI' }, 'CI green again', T0 + HOUR))).toBe(true);
  });

  it('a target is a P1 only after the fail budget (3 checks); recovery resolves it', async () => {
    const h = await harness();
    const down = [{ url: 'https://shop/checkout', kind: 'money' as const, ok: false, status: 502, ms: 10 }];
    expect((await h.run((b) => b.observeHealth(down, T0))).raised).toEqual([]);
    expect((await h.run((b) => b.observeHealth(down, T0 + 5 * MIN))).raised).toEqual([]);
    expect((await h.run((b) => b.observeHealth(down, T0 + 10 * MIN))).raised).toEqual(['https://shop/checkout']);
    expect((await h.run((b) => b.observeHealth(down, T0 + 15 * MIN))).raised).toEqual([]); // deduped
    const s = await h.run((b) => b.state(T0 + 15 * MIN));
    expect(s.findings.recent[0]).toMatchObject({ kind: 'money-path-broken', lane: 'urgent' });
    const up = [{ ...down[0]!, ok: true, status: 200 }];
    expect((await h.run((b) => b.observeHealth(up, T0 + 20 * MIN))).recovered).toEqual(['https://shop/checkout']);
  });
});
