// Final whole-branch review fixes (C-1, I-1, I-2, I-4, I-5, I-6, M-2..M-10). Each test is the review's scenario.
import { env } from 'cloudflare:workers';
import { runInDurableObject, SELF } from 'cloudflare:test';
import { afterEach, describe, expect, it, vi } from 'vitest';
import type { BrainDO } from '../src/brain-do';
import { WAITING_MAX_MS } from '../src/brain-do';
import type { Finding } from '../src/findings';
import type { HandsBatch, HandsProvider } from '../src/hands';
import { brainStub } from '../src/index';
import { watchPrShepherd } from '../src/watchers/pr-shepherd';
import { watchServices } from '../src/watchers/services';
import { evidenceOf } from '../src/findings';
import type { Env } from '../src/env';

const T0 = Date.UTC(2026, 10, 5, 8, 0, 0);
const MIN = 60_000;
const HOUR = 60 * MIN;
const DAY = 24 * HOUR;

/** A non-stub provider (so the usage-unknown fail-closed rule applies) that records starts. */
function realish(): HandsProvider & { started: HandsBatch[] } {
  const started: HandsBatch[] = [];
  return { name: 'cloudflare-sandbox', started, start: async (b) => (started.push(b), { runId: b.runId, provider: 'cloudflare-sandbox', startedAt: b.createdAt }) };
}

async function harness(hands: HandsProvider, repos: string[] | null = ['o/r']) {
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
  return { sent, run: <R>(fn: (b: BrainDO) => R | Promise<R>) => runInDurableObject(stub, (b: BrainDO) => fn(b)) };
}
const outage = (key: string, repo: string | null = 'o/r'): Finding => ({ source: 'health', kind: 'prod-outage', key, title: `${key} down`, ...(repo ? { repo } : {}), severity: 'P1', selfHealExhausted: true });
const docs = (x: Partial<Finding> = {}): Finding => ({ source: 'watcher', kind: 'docs', key: crypto.randomUUID(), title: 'fix docs', repo: 'o/r', ...x });

describe('C-1: a P1 the hands refuse is never dropped silently', () => {
  it('urgent job refused at 96%: ONE p1 message, job kept for tonight, and the NEXT urgent job boots no container', async () => {
    const p = realish();
    const h = await harness(p);
    await h.run((b) => b.reportUsage({ weeklyUsedPct: 10 }, T0)); // the brain believes usage is low
    await h.run((b) => b.ingestFinding(outage('a'), T0));
    await h.run((b) => b.tick(T0));
    expect(p.started).toHaveLength(1);
    const jobId = p.started[0]!.jobs[0]!.id;
    // the hands read 96%, report it (run.mjs now does this on refusal) and refuse the job
    await h.run((b) => b.reportUsage({ weeklyUsedPct: 96 }, T0 + MIN));
    await h.run((b) => b.recordOutcome(jobId, { status: 'skipped_usage', note: 'weekly usage 96% >= threshold 80% (claude-cli)' }, T0 + MIN));
    expect(h.sent.filter((t) => /could not self-heal: a down/.test(t))).toHaveLength(1);
    expect(h.sent[0]).toMatch(/96%/);
    const s = await h.run((b) => b.state(T0 + 2 * MIN));
    expect(s.jobs).toMatchObject({ queuedNightly: 1, queuedUrgent: 0 });
    await h.run((b) => b.ingestFinding(outage('b'), T0 + 3 * MIN));
    await h.run((b) => b.tick(T0 + 4 * MIN));
    expect(p.started).toHaveLength(1); // no second container
    expect(h.sent.filter((t) => /could not self-heal|not handled yet/.test(t)).length).toBeGreaterThanOrEqual(2); // b gets its own single notice
  });
  it('with a real provider, an urgent job with UNKNOWN usage boots nothing and says so once (Ruling I-4)', async () => {
    const p = realish();
    const h = await harness(p);
    await h.run((b) => b.ingestFinding(outage('x'), T0));
    await h.run((b) => b.tick(T0));
    await h.run((b) => b.tick(T0 + 5 * MIN));
    expect(p.started).toHaveLength(0);
    expect(h.sent.filter((t) => /usage-unknown/.test(t))).toHaveLength(1);
  });
});

describe('I-1: a nightly run that dies does not strand its jobs', () => {
  it('no outcome after cap+grace: the job is requeued once, then ends timed_out; the digest counts the requeue', async () => {
    const p = realish();
    const h = await harness(p);
    await h.run((b) => b.reportUsage({ weeklyUsedPct: 10 }, T0));
    await h.run((b) => b.ingestFinding(docs(), T0));
    await h.run((b) => b.runNightly(T0 + HOUR));
    expect(p.started).toHaveLength(1);
    await h.run((b) => b.tick(T0 + 3 * HOUR + HOUR)); // +2h after start: past 90 + 10 min
    let s = await h.run((b) => b.state(T0 + 4 * HOUR));
    expect(s.jobs).toMatchObject({ queuedNightly: 1, running: 0 });
    expect(s.runs[0]).toMatchObject({ status: 'timed_out' });
    await h.run((b) => b.digest(T0 + 4 * HOUR));
    expect(h.sent.at(-1)).toMatch(/Runs that died: 1/);
    await h.run((b) => b.reportUsage({ weeklyUsedPct: 10 }, T0 + DAY));
    await h.run((b) => b.runNightly(T0 + DAY));
    await h.run((b) => b.tick(T0 + DAY + 3 * HOUR));
    s = await h.run((b) => b.state(T0 + DAY + 3 * HOUR));
    expect(s.jobs).toMatchObject({ queuedNightly: 0, running: 0 });
    expect(s.findings.recent[0]).toMatchObject({ status: 'failed' });
  });
});

describe('I-2: a config gap never spends a container', () => {
  it('urgent outage with no repo: one p1 message, no job, no run', async () => {
    const p = realish();
    const h = await harness(p);
    await h.run((b) => b.reportUsage({ weeklyUsedPct: 10 }, T0));
    const r = await h.run((b) => b.ingestFinding(outage('norepo', null), T0));
    expect(r).toMatchObject({ lane: 'digest', jobId: null });
    await h.run((b) => b.tick(T0 + MIN));
    expect(p.started).toHaveLength(0);
    expect(h.sent.filter((t) => /no repo mapped/.test(t))).toHaveLength(1);
  });
  it('a nightly finding whose repo is missing from the hands config goes to the digest lane, no job', async () => {
    const h = await harness(realish(), ['o/r']);
    const r = await h.run((b) => b.ingestFinding(docs({ repo: 'o/unmapped' }), T0));
    expect(r).toMatchObject({ lane: 'digest', jobId: null });
    expect((await h.run((b) => b.state(T0))).jobs.queuedNightly).toBe(0);
  });
  it('a dream config self-report (dream-scan-failed) with no repo is digest, not a job', async () => {
    const h = await harness(realish());
    const r = await h.run((b) => b.ingestFinding({ source: 'dream', kind: 'dream-scan-failed', key: 'd1', title: 'scan failed' }, T0));
    expect(r.lane).toBe('digest');
  });
});

describe('I-4: a persistent outage is ONE incident (services evidence has no volatile fields)', () => {
  it('same outage, failed outcome, re-sighting at +7 h with a different latency: no reopen', async () => {
    const mk = (ms: number): Finding => ({ source: 'watcher', kind: 'prod-outage', key: 'services:api:down', title: `service api down (${ms} ms)`, repo: 'o/r', severity: 'P1', selfHealExhausted: true, detail: { incident: 123 } });
    expect(await evidenceOf(mk(10))).toBe(await evidenceOf(mk(999)));
    const p = realish();
    const h = await harness(p);
    await h.run((b) => b.reportUsage({ weeklyUsedPct: 10 }, T0));
    await h.run((b) => b.ingestFinding(mk(10), T0));
    await h.run((b) => b.tick(T0));
    await h.run((b) => b.recordOutcome(p.started[0]!.jobs[0]!.id, { status: 'could_not_fix' }, T0 + MIN));
    const again = await h.run((b) => b.ingestFinding(mk(999), T0 + 7 * HOUR));
    expect(again).toMatchObject({ deduped: true, reopened: false });
  });
  it('the services watcher puts only the incident id in detail', async () => {
    const out: Finding[] = [];
    const sink = { ingestMany: async (fs: Finding[]) => (out.push(...fs), { raised: fs.length, deduped: 0 }), resolveFinding: async () => true, reconcile: async () => 0, lastPassAt: async () => null };
    await env.EVENTS.delete('svc:fails:api');
    const e = { ...env, SERVICE_TARGETS: JSON.stringify([{ name: 'api', url: 'https://api.svc.test/h', kind: 'api', repo: 'o/r' }]), HEALTH_FAIL_BUDGET: '1' } as Env;
    await watchServices({ env: e, sink, now: T0, fetchImpl: (async () => new Response('x', { status: 503 })) as unknown as typeof fetch });
    expect(out[0]!.detail).toEqual({ incident: T0 });
    expect(out[0]!.repo).toBe('o/r');
  });
});

describe('I-5 (ruling F-I5): pr-shepherd', () => {
  const pr = (o: Record<string, unknown>) => ({ number: 7, title: 't', url: 'https://github.com/o/r/pull/7', isDraft: false, updatedAt: new Date(T0 - 3600000).toISOString(), mergeable: 'MERGEABLE', headRefName: 'feat/x', isCrossRepository: false, author: { login: 'ahmad', __typename: 'User' }, repository: { nameWithOwner: 'o/r' }, commits: { nodes: [{ commit: { statusCheckRollup: { state: 'SUCCESS' } } }] }, ...o });
  const run = async (nodes: unknown[]) => {
    const out: Finding[] = [];
    const sink = { ingestMany: async (fs: Finding[]) => (out.push(...fs), { raised: fs.length, deduped: 0 }), resolveFinding: async () => true, reconcile: async () => 0, lastPassAt: async () => null };
    const fetchImpl = (async () => Response.json({ data: { search: { pageInfo: { hasNextPage: false }, nodes } } })) as unknown as typeof fetch;
    await watchPrShepherd({ env: { ...env, OS_ORGS: 'o', GITHUB_TOKEN: 't' } as Env, sink, now: T0, fetchImpl });
    return out;
  };
  it('conflicting PR on the OS own same-repo branch -> pr-stuck with the head ref; a human branch -> digest note', async () => {
    const fixable = await run([pr({ mergeable: 'CONFLICTING', headRefName: 'os/fix-job_1' })]);
    expect(fixable).toMatchObject([{ kind: 'pr-stuck', detail: { pr: 7, head: 'os/fix-job_1', state: 'conflicting' } }]);
    const human = await run([pr({ mergeable: 'CONFLICTING' })]);
    expect(human).toMatchObject([{ kind: 'pr-needs-you' }]);
    const fork = await run([pr({ mergeable: 'CONFLICTING', headRefName: 'os/fix-x', isCrossRepository: true })]);
    expect(fork).toMatchObject([{ kind: 'pr-needs-you' }]);
    const bot = await run([pr({ mergeable: 'CONFLICTING', author: { login: 'dependabot', __typename: 'Bot' } })]);
    expect(bot).toMatchObject([{ kind: 'pr-stuck' }]);
  });
  it('waiting over 24 h alone is a digest note even for an OS branch', async () => {
    const out = await run([pr({ headRefName: 'os/fix-job_1', updatedAt: new Date(T0 - 30 * HOUR).toISOString() })]);
    expect(out).toMatchObject([{ kind: 'pr-needs-you', key: 'pr:o/r#7:waiting' }]);
    const h = await harness(realish());
    expect((await h.run((b) => b.ingestFinding(out[0]!, T0))).lane).toBe('digest');
  });
});

describe('I-6 (ruling F-I6): the drill result posted by the Mac', () => {
  it('POST /drill needs INGEST_TOKEN and validates; a PASS is what the watcher reads', async () => {
    const post = (body: unknown, token?: string) => SELF.fetch('https://brain.test/drill', { method: 'POST', headers: token ? { Authorization: `Bearer ${token}` } : {}, body: JSON.stringify(body) });
    expect((await post({ result: 'pass' })).status).toBe(401);
    expect((await post({ result: 'maybe' }, 'test-ingest-token')).status).toBe(400);
    expect((await post({ result: 'pass' }, 'test-ingest-token')).status).toBe(200);
    expect(await brainStub(env).lastPassAt('watcher', 'dr-drill')).not.toBeNull();
  });
  it('an overdue drill sends ONE unhealed-P1 message and opens no job', async () => {
    const h = await harness(realish(), null);
    const f: Finding = { source: 'watcher', kind: 'dr-drill-overdue', key: 'dr-drill:ebda-store:overdue', title: 'no restore drill has passed in 15 days', repo: 'o/r', severity: 'P1' };
    expect(await h.run((b) => b.ingestFinding(f, T0))).toMatchObject({ lane: 'digest', jobId: null });
    expect(h.sent.filter((t) => /no restore drill has passed/.test(t))).toHaveLength(1);
  });
});

describe('M-2 / M-3 / M-4: telegram presser, replay, green-before-red', () => {
  afterEach(() => vi.restoreAllMocks());
  const tg = (body: unknown) => SELF.fetch('https://brain.test/telegram/webhook', { method: 'POST', headers: { 'X-Telegram-Bot-Api-Secret-Token': 'test-tg-secret' }, body: JSON.stringify(body) });
  it('M-2: a group member who is not the owner cannot press a button', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(new Response('{"ok":true}'));
    await brainStub(env).ingestFinding({ source: 'w', kind: 'auth-cookie', key: 'm2', title: 'm2 cookie', repo: 'o/r' });
    const q = (await brainStub(env).state()).questions.find((x) => String(x.text).startsWith('m2 cookie'))!;
    await tg({ callback_query: { id: 'c', data: `q:${q.id}:hold`, message: { chat: { id: 4242 } }, from: { id: 777 } } });
    expect((await brainStub(env).state()).questions.some((x) => x.id === q.id)).toBe(true);
    await tg({ callback_query: { id: 'c', data: `q:${q.id}:hold`, message: { chat: { id: 4242 } }, from: { id: 4242 } } });
    expect((await brainStub(env).state()).questions.some((x) => x.id === q.id)).toBe(false);
  });
  const body = (conclusion: string, id: number, updated = new Date().toISOString(), workflow = 'M3') =>
    JSON.stringify({ action: 'completed', repository: { full_name: 'o/m3', default_branch: 'main' }, workflow_run: { id, run_attempt: 1, updated_at: updated, conclusion, head_sha: 'abc', head_branch: 'main', name: workflow, html_url: 'https://gh/run' } });
  async function hook(b: string, delivery: string) {
    const key = await crypto.subtle.importKey('raw', new TextEncoder().encode('test-gh-secret'), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
    const mac = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(b));
    const sig = `sha256=${[...new Uint8Array(mac)].map((x) => x.toString(16).padStart(2, '0')).join('')}`;
    return SELF.fetch('https://brain.test/github/webhook', { method: 'POST', headers: { 'X-GitHub-Event': 'workflow_run', 'X-GitHub-Delivery': delivery, 'X-Hub-Signature-256': sig }, body: b });
  }
  it('M-3: the same signed body under a NEW delivery id is deduped; a run last updated over an hour ago is ignored', async () => {
    const b = body('failure', 9001);
    await hook(b, 'd-a');
    await hook(b, 'd-b');
    expect(await brainStub(env).processCiEvents(Date.now())).toMatchObject({ processed: 1 });
    await hook(body('failure', 9002, new Date(Date.now() - 2 * HOUR).toISOString()), 'd-c');
    expect(await brainStub(env).processCiEvents(Date.now())).toMatchObject({ processed: 0 });
  });
  it('M-4: a red event that arrived before a green run of the same workflow raises no finding', async () => {
    await hook(body('failure', 9101, undefined, 'M4'), 'm4-red');
    await hook(body('success', 9102, undefined, 'M4'), 'm4-green');
    expect(await brainStub(env).processCiEvents(Date.now() + 1000)).toMatchObject({ processed: 1, findings: 0 });
  });
});

describe('M-6 / M-7 / M-10', () => {
  it('M-6: a fix PR waiting over 14 days moves to the digest', async () => {
    const p = realish();
    const h = await harness(p);
    await h.run((b) => b.reportUsage({ weeklyUsedPct: 10 }, T0));
    await h.run((b) => b.ingestFinding(docs({ kind: 'improvement' }), T0));
    await h.run((b) => b.runNightly(T0 + HOUR));
    await h.run((b) => b.recordOutcome(p.started[0]!.jobs[0]!.id, { status: 'pr_opened', prUrl: 'https://pr/1' }, T0 + 2 * HOUR));
    expect((await h.run((b) => b.state(T0 + 3 * HOUR))).findings.recent[0]).toMatchObject({ status: 'waiting' });
    await h.run((b) => b.tick(T0 + 2 * HOUR + WAITING_MAX_MS + MIN));
    expect((await h.run((b) => b.state(T0 + 20 * DAY))).findings.recent[0]).toMatchObject({ status: 'digest', lane: 'digest' });
  });
  it('M-7: a tick that interleaves with the outbound start call starts no second urgent run', async () => {
    let release!: () => void;
    const gate = new Promise<void>((r) => (release = r));
    const started: HandsBatch[] = [];
    const slow: HandsProvider = { name: 'stub', start: async (b) => (started.push(b), await gate, { runId: b.runId, provider: 'stub', startedAt: T0 }) };
    const h = await harness(slow);
    await h.run((b) => b.ingestFinding(outage('a'), T0));
    await h.run((b) => b.ingestFinding(outage('b'), T0));
    const first = h.run((b) => b.tick(T0));
    await new Promise((r) => setTimeout(r, 20));
    await h.run((b) => b.tick(T0 + MIN)); // interleaves while start() is pending
    release();
    await first;
    expect(started).toHaveLength(1);
  });
  it('M-10 (R-4a-3): more than 500 already-shown digest rows cannot hide a new monitor note', async () => {
    const h = await harness(realish());
    for (let i = 0; i < 3; i++) await h.run((b) => b.ingestFinding({ source: 'watcher', kind: 'monitor-unconfigured', key: `w${i}:config:unconfigured`, title: `watcher w${i} not running` }, T0 + i));
    await h.run((b) => b.digest(T0 + HOUR));
    await h.run((b) => b.ingestFinding({ source: 'watcher', kind: 'monitor-unconfigured', key: 'new:config:unconfigured', title: 'watcher NEWONE not running' }, T0 + 2 * HOUR));
    await h.run((b) => b.digest(T0 + DAY + HOUR));
    expect(h.sent.at(-1)).toMatch(/NEWONE/);
    expect(h.sent.at(-1)).not.toMatch(/watcher w0/);
  });
});

describe('I-10: the Mac hands never claim third-party-text work (ruling 4b-5); /api/state lists unconfigured watchers', () => {
  it('mac-local claim skips advisory, pr-stuck and world-watch jobs; the container batch still gets them', async () => {
    const p = realish();
    const h = await harness(p);
    await h.run((b) => b.reportUsage({ weeklyUsedPct: 10 }, T0));
    await h.run((b) => b.ingestFinding(docs({ title: 'own docs' }), T0));
    await h.run((b) => b.ingestFinding({ source: 'advisory', kind: 'dependency-advisory', key: 'o/r#GHSA-1', title: 'lib GHSA-1', repo: 'o/r', cvss: 5, depScope: 'runtime' }, T0));
    await h.run((b) => b.ingestFinding({ source: 'watcher', kind: 'pr-stuck', key: 'pr:o/r#1:conflicting', title: 'PR conflicts', repo: 'o/r', detail: { head: 'os/fix-x', state: 'conflicting' } }, T0));
    await h.run((b) => b.ingestFinding({ source: 'watcher', kind: 'docs', key: 'world-watch:npm:x', title: 'dep note', repo: 'o/r' }, T0));
    const c = (await h.run((b) => b.claim('mac-local', 10, T0 + MIN))) as HandsBatch;
    expect(c.jobs.map((j) => j.finding.title)).toEqual(['own docs']);
    const r = await h.run((b) => b.runNightly(T0 + HOUR));
    expect(r).toMatchObject({ started: true, jobs: 3 });
  });
  it('state().unconfigured names the watchers that raised monitor-unconfigured', async () => {
    const h = await harness(realish());
    await h.run((b) => b.ingestFinding({ source: 'watcher', kind: 'monitor-unconfigured', key: 'services:config:unconfigured', title: 'x' }, T0));
    expect((await h.run((b) => b.state(T0))).unconfigured).toEqual(['services']);
  });
});
