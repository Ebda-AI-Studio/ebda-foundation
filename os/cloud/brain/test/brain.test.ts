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
  it('a recurrence after the cool-down with new evidence reopens the same row instead of a second finding', async () => {
    const h = await harness();
    const f = finding({ key: 'recur' });
    await h.run((b) => b.ingestFinding(f, T0));
    await h.run((b) => b.resolveFinding(f, 'fixed upstream', T0 + MIN));
    const again = await h.run((b) => b.ingestFinding({ ...f, detail: { sha: 'new' } }, T0 + 25 * HOUR));
    expect(again).toMatchObject({ deduped: false, reopened: true });
    const s = await h.run((b) => b.state(T0 + 25 * HOUR));
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

describe('usage-starved alert (ruling 4b-6)', () => {
  const DAY = 24 * HOUR;
  it('alerts once after 3 consecutive nightly batches refused by the usage guard, not before', async () => {
    const h = await harness();
    await h.run((b) => b.ingestFinding(finding(), T0));
    await h.run((b) => b.reportUsage({ weeklyUsedPct: 90 }, T0));
    for (let i = 1; i <= 2; i++) await h.run((b) => b.runNightly(T0 + i * DAY));
    expect(h.sent.filter((m) => /nightly batches did no work/.test(m.text))).toHaveLength(0);
    await h.run((b) => b.runNightly(T0 + 3 * DAY));
    const alerts = h.sent.filter((m) => /last 3 nightly batches did no work/.test(m.text));
    expect(alerts).toHaveLength(1);
    expect(alerts[0]!.text).toMatch(/threshold 80%/);
  });
  it('a nightly batch that made progress resets the streak', async () => {
    const h = await harness();
    await h.run((b) => b.ingestFinding(finding(), T0));
    await h.run((b) => b.reportUsage({ weeklyUsedPct: 90 }, T0));
    await h.run((b) => b.runNightly(T0 + DAY));
    await h.run((b) => b.runNightly(T0 + 2 * DAY));
    await h.run((b) => b.reportUsage({ weeklyUsedPct: 10 }, T0 + 2 * DAY));
    const r = await h.run((b) => b.runNightly(T0 + 3 * DAY));
    expect(r.started).toBe(true);
    const [j] = h.hands.started[0]!.jobs;
    await h.run((b) => b.recordOutcome(j!.id, { status: 'merged' }, T0 + 3 * DAY + HOUR));
    await h.run((b) => b.reportUsage({ weeklyUsedPct: 90 }, T0 + 3 * DAY));
    await h.run((b) => b.ingestFinding(finding(), T0 + 4 * DAY));
    await h.run((b) => b.runNightly(T0 + 4 * DAY));
    await h.run((b) => b.runNightly(T0 + 5 * DAY));
    expect(h.sent.filter((m) => /nightly batches did no work/.test(m.text))).toHaveLength(0);
  });
  it('a started run whose every job comes back skipped_usage counts as a starved batch', async () => {
    const h = await harness();
    for (let i = 0; i < 3; i++) {
      await h.run((b) => b.ingestFinding(finding(), T0 + i * DAY));
      const r = await h.run((b) => b.runNightly(T0 + i * DAY + HOUR));
      expect(r.started).toBe(true);
      for (const j of h.hands.started[i]!.jobs) await h.run((b) => b.recordOutcome(j.id, { status: 'skipped_usage' }, T0 + i * DAY + 2 * HOUR));
    }
    expect(h.sent.filter((m) => /last 3 nightly batches did no work/.test(m.text))).toHaveLength(1);
  });
});

describe('urgent lane (Amendment A.1)', () => {
  const outage = (key: string): Finding => ({ source: 'health', kind: 'prod-outage', key, title: `${key} down`, repo: 'o/r', severity: 'P1', selfHealExhausted: true });

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
    // the 3 urgent outcome messages used the urgent bucket: the 4th issue's notice rolls into the digest instead
    expect(h.sent.filter((m) => /urgent:/.test(m.text))).toHaveLength(3);
    expect(h.sent.filter((m) => /not handled yet/.test(m.text))).toHaveLength(0);
    const s = await h.run((b) => b.state(T0 + 45 * MIN));
    expect(s.jobs).toMatchObject({ queuedUrgent: 0, queuedNightly: 1 });
    expect(s.messages.deferred).toBe(1);
    await h.run((b) => b.digest(T0 + 50 * MIN));
    expect(h.sent.at(-1)!.text).toMatch(/urgent cap 3\/day/);
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
    const down = [{ url: 'https://shop/checkout', kind: 'money' as const, repo: 'o/r', ok: false, status: 502, ms: 10 }];
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

describe('fix round 1: re-sighting, promotion, message ceiling, retries', () => {
  const advisory = (x: Partial<Finding> = {}): Finding => ({ source: 'advisory', kind: 'dependency-advisory', key: 'o/r#GHSA-x', title: 'lib GHSA-x', repo: 'o/r', cvss: 7.5, depScope: 'runtime', deployed: true, ...x });

  it('I-1: re-sighting an advisory whose fix PR is open creates no new job', async () => {
    const h = await harness();
    await h.run((b) => b.ingestFinding(advisory(), T0));
    await h.run((b) => b.runNightly(T0 + HOUR));
    await h.run((b) => b.recordOutcome(h.hands.started[0]!.jobs[0]!.id, { status: 'pr_opened', prUrl: 'https://pr/9' }, T0 + 2 * HOUR));
    for (const t of [3, 30, 60]) {
      const r = await h.run((b) => b.ingestFinding(advisory({ cvss: 8.1 }), T0 + t * HOUR)); // even with changed evidence
      expect(r).toMatchObject({ deduped: true, jobId: null });
    }
    expect(await h.run((b) => b.runNightly(T0 + 61 * HOUR))).toMatchObject({ started: false });
    expect((await h.run((b) => b.state(T0 + 61 * HOUR))).findings.recent[0]).toMatchObject({ status: 'waiting', seen_count: 4 });
  });

  it('I-1: a held decision is not re-asked when the finding is seen again', async () => {
    const h = await harness();
    const f = finding({ kind: 'auth-cookie', key: 'held-1' });
    await h.run((b) => b.ingestFinding(f, T0));
    await h.run((b) => b.tick(T0));
    const q = (await h.run((b) => b.state(T0))).questions[0]!;
    await h.run((b) => b.answerQuestion(q.id, 'hold', T0 + HOUR));
    expect(await h.run((b) => b.ingestFinding({ ...f, detail: { new: 1 } }, T0 + 48 * HOUR))).toMatchObject({ deduped: true });
    expect((await h.run((b) => b.state(T0 + 48 * HOUR))).questions).toHaveLength(0);
  });

  it('I-1: a resolved finding reopens only after the cool-down AND with changed evidence', async () => {
    const h = await harness();
    const ci = (sha: string): Finding => ({ source: 'ci', kind: 'ci-failure', key: 'o/r:CI', title: 'CI red', repo: 'o/r', detail: { sha } });
    await h.run((b) => b.ingestFinding(ci('a'), T0));
    await h.run((b) => b.resolveFinding(ci('a'), 'CI green again', T0 + HOUR));
    expect(await h.run((b) => b.ingestFinding(ci('b'), T0 + 2 * HOUR))).toMatchObject({ deduped: true }); // inside 24 h
    expect(await h.run((b) => b.ingestFinding(ci('b'), T0 + 26 * HOUR))).toMatchObject({ deduped: false, reopened: true });
    await h.run((b) => b.resolveFinding(ci('b'), 'CI green again', T0 + 27 * HOUR));
    expect(await h.run((b) => b.ingestFinding(ci('b'), T0 + 60 * HOUR))).toMatchObject({ deduped: true }); // same evidence
  });

  it('I-1: a persistent outage over 1 h is ONE incident and ONE urgent run', async () => {
    const h = await harness();
    const down = [{ url: 'https://api.test/health', kind: 'api' as const, repo: 'o/r', ok: false, status: 503, ms: 5 }];
    for (let i = 0; i <= 14; i++) {
      const t = T0 + i * 5 * MIN;
      await h.run((b) => b.observeHealth(down, t));
      await h.run((b) => b.tick(t));
      if (i === 4) await h.run((b) => b.recordOutcome(h.hands.started[0]!.jobs[0]!.id, { status: 'could_not_fix' }, t));
    }
    expect(h.hands.started).toHaveLength(1);
    expect(h.sent.filter((m) => /urgent: could NOT fix/.test(m.text))).toHaveLength(1);
    // recovery then a NEW streak after the cool-down is a new incident
    await h.run((b) => b.observeHealth([{ ...down[0]!, ok: true, status: 200 }], T0 + 2 * HOUR));
    for (let i = 0; i < 3; i++) await h.run((b) => b.observeHealth(down, T0 + 9 * HOUR + i * 5 * MIN));
    await h.run((b) => b.tick(T0 + 9 * HOUR + 10 * MIN));
    expect(h.hands.started).toHaveLength(2);
  });

  it('I-2: a flood of 10 distinct urgent findings sends at most 6 messages; the rest go to the digest', async () => {
    const h = await harness();
    for (let i = 0; i < 10; i++) await h.run((b) => b.ingestFinding({ source: 'health', kind: 'prod-outage', key: `u${i}`, title: `site ${i} down`, repo: 'o/r', selfHealExhausted: true }, T0));
    for (let i = 0; i < 2; i++) await h.run((b) => b.ingestFinding(finding({ kind: 'payout-x', key: `q${i}`, title: `payout ${i}` }), T0));
    for (let i = 0; i < 6; i++) {
      const t = T0 + i * 10 * MIN;
      await h.run((b) => b.tick(t));
      const running = h.hands.started.at(-1);
      if (running && i < 3) await h.run((b) => b.recordOutcome(running.jobs[0]!.id, { status: 'could_not_fix' }, t + MIN));
    }
    const nonDigest = h.sent.length;
    expect(nonDigest).toBeLessThanOrEqual(6);
    expect((await h.run((b) => b.state(T0 + HOUR))).messages.deferred).toBeGreaterThanOrEqual(7);
    expect(await h.run((b) => b.digest(T0 + 2 * HOUR))).toBe('sent');
    expect(h.sent.at(-1)!.text).toMatch(/Rolled up/);
  });

  it('I-3: a nightly advisory newly listed in CISA KEV is promoted to urgent and gets one urgent run', async () => {
    const h = await harness();
    expect((await h.run((b) => b.ingestFinding(advisory(), T0))).lane).toBe('nightly');
    const r = await h.run((b) => b.ingestFinding(advisory({ kev: true }), T0 + HOUR));
    expect(r).toMatchObject({ deduped: true, lane: 'urgent' });
    await h.run((b) => b.tick(T0 + HOUR));
    await h.run((b) => b.tick(T0 + HOUR + 5 * MIN));
    expect(h.hands.started).toHaveLength(1);
    expect(h.hands.started[0]).toMatchObject({ kind: 'urgent' });
    // never demoted: the KEV listing disappearing does not move the in-flight job back
    expect((await h.run((b) => b.ingestFinding(advisory({ kev: false }), T0 + 2 * HOUR))).lane).toBe('urgent');
  });

  it('I-3: a dev-only KEV advisory stays nightly', async () => {
    const h = await harness();
    await h.run((b) => b.ingestFinding(advisory({ depScope: 'development' }), T0));
    expect((await h.run((b) => b.ingestFinding(advisory({ depScope: 'development', kev: true }), T0 + HOUR))).lane).toBe('nightly');
  });

  it('I-5: a failed urgent-outcome send is retried (3 tries over 15 min), then rolls into the digest marked delivery failed', async () => {
    const h = await harness();
    // real-time base: the DO alarm uses the wall clock, so a past base would let it fire during the test
    const B = Date.now();
    let fail = true;
    await h.run((b) => {
      const ok = b.fetchImpl;
      b.fetchImpl = ((u: RequestInfo | URL, i?: RequestInit) => (fail ? Promise.resolve(new Response('down', { status: 502 })) : ok(u, i))) as typeof fetch;
    });
    await h.run((b) => b.ingestFinding({ source: 'health', kind: 'prod-outage', key: 'r1', title: 'r1 down', repo: 'o/r', selfHealExhausted: true }, B));
    await h.run((b) => b.tick(B));
    await h.run((b) => b.recordOutcome(h.hands.started[0]!.jobs[0]!.id, { status: 'fix_deployed' }, B + MIN));
    expect(await h.run((b) => b.retryFailed(B + 2 * MIN))).toEqual({ sent: 0, undelivered: 0 }); // not due yet
    expect(await h.run((b) => b.retryFailed(B + 6 * MIN))).toEqual({ sent: 0, undelivered: 0 }); // try 2 failed
    expect(await h.run((b) => b.retryFailed(B + 16 * MIN))).toEqual({ sent: 0, undelivered: 1 }); // try 3 failed
    fail = false;
    await h.run((b) => b.digest(B + HOUR));
    expect(h.sent.at(-1)!.text).toMatch(/\[delivery failed\] Ebda OS urgent: fix deployed/);
  });

  it('I-5: a retry that succeeds is delivered once, and the DO alarm drives it', async () => {
    const h = await harness();
    let calls = 0;
    await h.run((b) => {
      const ok = b.fetchImpl;
      b.fetchImpl = ((u: RequestInfo | URL, i?: RequestInit) => (++calls === 1 ? Promise.resolve(new Response('x', { status: 500 })) : ok(u, i))) as typeof fetch;
    });
    const now = Date.now();
    await h.run((b) => b.ingestFinding({ source: 'health', kind: 'prod-outage', key: 'r2', title: 'r2 down', repo: 'o/r', selfHealExhausted: true }, now));
    await h.run((b) => b.tick(now));
    await h.run((b) => b.recordOutcome(h.hands.started[0]!.jobs[0]!.id, { status: 'merged' }, now));
    const alarmAt = await h.run((_b) => 0).then(() => runInDurableObject(h.stub, (_i, st) => st.storage.getAlarm()));
    expect(alarmAt).toBe(now + 5 * MIN);
    expect(await h.run((b) => b.retryFailed(now + 5 * MIN))).toEqual({ sent: 1, undelivered: 0 });
    expect(h.sent.filter((m) => /urgent: fixed and merged/.test(m.text))).toHaveLength(1);
  });
});

describe('digest lane (monitor self-reports)', () => {
  const selfReport = (x: Partial<Finding> = {}) => finding({ kind: 'monitor-unconfigured', key: 'services:config:unconfigured', title: 'watcher services is not running: SERVICE_TARGETS is not set', ...x });
  it('no job, no question, no Telegram send; deduped; not an OS bug after 24 h', async () => {
    const h = await harness();
    const a = await h.run((b) => b.ingestFinding(selfReport(), T0));
    const again = await h.run((b) => b.ingestFinding(selfReport(), T0 + 5 * MIN));
    expect(a).toMatchObject({ lane: 'digest', jobId: null, deduped: false });
    expect(again).toMatchObject({ deduped: true, jobId: null });
    await h.run((b) => b.tick(T0 + 26 * HOUR));
    const s = await h.run((b) => b.state(T0 + 26 * HOUR));
    expect(s.jobs).toMatchObject({ queuedNightly: 0, queuedUrgent: 0, awaitingAnswer: 0 });
    expect(s.osBugs).toBe(0);
    expect(s.questions).toHaveLength(0);
    expect(s.findings.recent).toHaveLength(1);
    expect(s.findings.recent[0]).toMatchObject({ lane: 'digest', status: 'digest', seen_count: 2 });
    expect(h.sent).toHaveLength(0);
    expect(h.hands.started).toHaveLength(0);
  });
  it('the daily digest lists it exactly once, as the only message', async () => {
    const h = await harness();
    await h.run((b) => b.ingestFinding(selfReport(), T0));
    await h.run((b) => b.ingestFinding(selfReport({ kind: 'watcher-error', key: 'cf-workers:cloudflare:error', title: 'watcher cf-workers could not read its source: HTTP 401' }), T0));
    await h.run((b) => b.digest(T0 + HOUR));
    expect(h.sent).toHaveLength(1);
    expect(h.sent[0]!.text).toContain('Monitors needing attention');
    expect(h.sent[0]!.text).toContain('SERVICE_TARGETS is not set');
    expect(h.sent[0]!.text).toContain('HTTP 401');
    await h.run((b) => b.digest(T0 + 25 * HOUR));
    expect(h.sent).toHaveLength(2);
    expect(h.sent[1]!.text).not.toContain('Monitors needing attention');
  });
  it('15 notes: digest 1 lists 10 + "+5 more", digest 2 lists the other 5; none lost, none repeated', async () => {
    const h = await harness();
    for (let i = 1; i <= 15; i++) await h.run((b) => b.ingestFinding(selfReport({ key: `w${i}:config:unconfigured`, title: `note-${String(i).padStart(2, '0')}` }), T0 + i));
    await h.run((b) => b.digest(T0 + HOUR));
    const d1 = h.sent[0]!.text;
    const in1 = [...d1.matchAll(/note-(\d\d)/g)].map((m) => m[1]);
    expect(in1).toHaveLength(10);
    expect(d1).toContain('+5 more pending');
    await h.run((b) => b.digest(T0 + 25 * HOUR));
    const d2 = h.sent[1]!.text;
    const in2 = [...d2.matchAll(/note-(\d\d)/g)].map((m) => m[1]);
    expect(in2).toHaveLength(5);
    expect(d2).not.toContain('more pending');
    expect(new Set([...in1, ...in2]).size).toBe(15);
    await h.run((b) => b.digest(T0 + 49 * HOUR));
    expect(h.sent[2]!.text).not.toContain('Monitors needing attention');
  });
  it('a recurrence after resolution is news again in the next digest', async () => {
    const h = await harness();
    await h.run((b) => b.ingestFinding(selfReport(), T0));
    await h.run((b) => b.digest(T0 + HOUR));
    await h.run((b) => b.resolveFinding(selfReport(), 'configured', T0 + 2 * HOUR));
    await h.run((b) => b.ingestFinding(selfReport({ detail: { n: 2 } }), T0 + 30 * HOUR));
    await h.run((b) => b.digest(T0 + 49 * HOUR));
    expect(h.sent.at(-1)!.text).toContain('Monitors needing attention');
  });
});
