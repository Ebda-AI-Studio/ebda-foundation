// Route + cron tests through the real Worker entry on workerd (fetch and scheduled handlers, KV, the DO binding).
import { env } from 'cloudflare:workers';
import { createExecutionContext, createScheduledController, SELF, waitOnExecutionContext } from 'cloudflare:test';
import { afterEach, describe, expect, it, vi } from 'vitest';
import worker, { brainStub } from '../src/index';
import { signEvent } from '../src/relay';
import { CRONS } from '../src/schedule';

async function ghSig(body: string, secret: string): Promise<string> {
  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const mac = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(body));
  return `sha256=${[...new Uint8Array(mac)].map((b) => b.toString(16).padStart(2, '0')).join('')}`;
}

const run = (conclusion: string, branch = 'main', workflow = 'CI') =>
  JSON.stringify({ action: 'completed', repository: { full_name: 'o/r', default_branch: 'main' }, workflow_run: { conclusion, head_sha: 'abc', head_branch: branch, name: workflow, html_url: 'https://gh/run/1' } });

async function hook(body: string, id: string, sig?: string, event = 'workflow_run'): Promise<Response> {
  return SELF.fetch('https://brain.test/github/webhook', {
    method: 'POST',
    headers: { 'X-GitHub-Event': event, 'X-GitHub-Delivery': id, 'X-Hub-Signature-256': sig ?? (await ghSig(body, 'test-gh-secret')), 'content-type': 'application/json' },
    body,
  });
}

afterEach(() => vi.restoreAllMocks());

describe('GitHub webhook relay', () => {
  it('rejects a bad signature', async () => {
    const r = await hook(run('failure'), 'bad-1', 'sha256=' + '0'.repeat(64));
    expect(r.status).toBe(401);
  });

  it('a failed run is signed into the Mac fallback queue and the brain inbox; /pending drains it with a valid relay signature', async () => {
    expect((await hook(run('failure'), 'dlv-1')).status).toBe(204);
    expect((await SELF.fetch('https://brain.test/pending')).status).toBe(401);
    const res = await SELF.fetch('https://brain.test/pending', { headers: { Authorization: 'Bearer test-relay-secret' } });
    const events = (await res.json()) as Array<{ id: string; kind: string; ts: number; target: { slug: string; sha: string }; sig: string }>;
    expect(events).toHaveLength(1);
    const e = events[0]!;
    expect(e).toMatchObject({ id: 'dlv-1', kind: 'ci-failure', target: { slug: 'o/r', sha: 'abc' } });
    expect(Object.keys(e.target)).toEqual(['slug', 'sha']); // the signed target keeps the predecessor shape and key order
    expect(e.sig).toBe(await signEvent(e.id, e.kind, e.ts, e.target, 'test-relay-secret'));
    const again = await SELF.fetch('https://brain.test/pending', { headers: { Authorization: 'Bearer test-relay-secret' } });
    expect(await again.json()).toEqual([]);
    expect(await brainStub(env).processCiEvents(Date.now())).toMatchObject({ findings: 1 });
  });

  it('ignores ping, non-completed runs and successes (a default-branch success resolves the CI finding)', async () => {
    expect((await hook('{}', 'p1', undefined, 'ping')).status).toBe(204);
    const inProgress = JSON.stringify({ action: 'in_progress', repository: { full_name: 'o/r' }, workflow_run: {} });
    expect((await hook(inProgress, 'p2')).status).toBe(204);
    await hook(run('failure', 'main', 'Deploy'), 'p3');
    await brainStub(env).processCiEvents(Date.now());
    await hook(run('success', 'main', 'Deploy'), 'p4');
    const s = await brainStub(env).state();
    expect(s.findings.recent.find((f) => f.kind === 'ci-failure' && String(f.title).includes('Deploy'))).toMatchObject({ status: 'resolved' });
  });
});

describe('machine endpoints', () => {
  it('POST /findings needs INGEST_TOKEN and validates the shape', async () => {
    const post = (body: unknown, token?: string) =>
      SELF.fetch('https://brain.test/findings', { method: 'POST', headers: token ? { Authorization: `Bearer ${token}` } : {}, body: JSON.stringify(body) });
    expect((await post({ source: 's', kind: 'docs', key: 'k', title: 't' })).status).toBe(401);
    expect((await post({ source: 's', kind: 'docs', key: 'k' }, 'test-ingest-token')).status).toBe(400);
    expect((await post({ source: 's', kind: 'docs', key: 'k', title: 't', cvss: 11 }, 'test-ingest-token')).status).toBe(400);
    const ok = await post([{ source: 'dream', kind: 'docs', key: 'route-1', title: 't' }], 'test-ingest-token');
    expect(await ok.json()).toEqual({ raised: 1, deduped: 0 });
  });

  it('hands endpoints need HANDS_TOKEN; usage + claim + outcome round-trip', async () => {
    const call = (path: string, body?: unknown, token = 'test-hands-token') =>
      SELF.fetch(`https://brain.test${path}`, { method: body === undefined ? 'GET' : 'POST', headers: { Authorization: `Bearer ${token}` }, ...(body === undefined ? {} : { body: JSON.stringify(body) }) });
    expect((await call('/hands/usage', { weeklyUsedPct: 10 }, 'nope')).status).toBe(401);
    expect((await call('/hands/usage', { weeklyUsedPct: 'x' })).status).toBe(400);
    expect((await call('/hands/usage', { weeklyUsedPct: 10 })).status).toBe(200);
    await SELF.fetch('https://brain.test/findings', { method: 'POST', headers: { Authorization: 'Bearer test-ingest-token' }, body: JSON.stringify({ source: 'dream', kind: 'test', key: 'claim-1', title: 'add a test' }) });
    const batch = (await (await call('/hands/claim', { provider: 'mac-local', max: 1 })).json()) as { runId: string; jobs: Array<{ id: string }> };
    expect(batch.jobs).toHaveLength(1);
    const got = (await (await call(`/hands/runs/${batch.runId}`)).json()) as { jobs: unknown[] };
    expect(got.jobs).toHaveLength(1);
    expect((await call(`/hands/jobs/${batch.jobs[0]!.id}/outcome`, { status: 'nope' })).status).toBe(400);
    expect((await call(`/hands/jobs/${batch.jobs[0]!.id}/outcome`, { status: 'pr_opened', prUrl: 'https://pr/2' })).status).toBe(200);
    expect((await call(`/hands/jobs/${batch.jobs[0]!.id}/outcome`, { status: 'pr_opened' })).status).toBe(409);
  });

  it('the Telegram webhook needs its secret and only accepts answers from the configured chat', async () => {
    const tg = (body: unknown, secret = 'test-tg-secret') =>
      SELF.fetch('https://brain.test/telegram/webhook', { method: 'POST', headers: { 'X-Telegram-Bot-Api-Secret-Token': secret }, body: JSON.stringify(body) });
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(new Response('{"ok":true}'));
    await brainStub(env).ingestFinding({ source: 'w', kind: 'auth-cookie', key: 'tg-q', title: 'cookie flags' });
    const q = (await brainStub(env).state()).questions.find((x) => String(x.text).startsWith('cookie flags'))!;
    expect((await tg({}, 'wrong')).status).toBe(401);
    await tg({ callback_query: { id: 'c1', data: `q:${q.id}:hold`, message: { chat: { id: 999 } } } });
    expect((await brainStub(env).state()).questions.some((x) => x.id === q.id)).toBe(true); // other chat: ignored
    await tg({ callback_query: { id: 'c2', data: `q:${q.id}:hold`, message: { chat: { id: 4242 } } } });
    expect((await brainStub(env).state()).questions.some((x) => x.id === q.id)).toBe(false);
  });

  it('the dashboard API fails closed while Access is not configured', async () => {
    const r = await SELF.fetch('https://brain.test/api/state');
    expect(r.status).toBe(503);
    expect(await r.json()).toMatchObject({ reason: 'access not configured' });
    expect((await SELF.fetch('https://brain.test/health')).status).toBe(200);
    expect((await SELF.fetch('https://brain.test/', { redirect: 'manual' })).headers.get('location')).toBe('https://brain.test/dash/');
  });
});

describe('cron handlers', () => {
  it('tick: checks the health targets (no DO wake-up for the network) and records the result', async () => {
    const seen: string[] = [];
    vi.spyOn(globalThis, 'fetch').mockImplementation(async (input: RequestInfo | URL) => {
      const u = String(input instanceof Request ? input.url : input);
      seen.push(u);
      return u.includes('checkout') ? new Response('bad gateway', { status: 502 }) : Response.json({ ok: true });
    });
    const ctx = createExecutionContext();
    await worker.scheduled(createScheduledController({ cron: CRONS.tick, scheduledTime: Date.now() }), env, ctx);
    await waitOnExecutionContext(ctx);
    expect(seen.sort()).toEqual(['https://api.example.test/health', 'https://shop.example.test/checkout']);
    const s = await brainStub(env).state();
    expect((s.health as { obs: Array<{ ok: boolean }> }).obs.map((o) => o.ok).sort()).toEqual([false, true]);
  });

  it('hourly: advisories skip without GITHUB_TOKEN (recorded, no network)', async () => {
    const spy = vi.spyOn(globalThis, 'fetch');
    const ctx = createExecutionContext();
    await worker.scheduled(createScheduledController({ cron: CRONS.hourly, scheduledTime: Date.now() }), env, ctx);
    expect(spy).not.toHaveBeenCalled();
    expect((await brainStub(env).state()).advisories).toMatchObject({ skipped: 'GITHUB_TOKEN secret unset' });
  });

  it('nightly: the cron drains the queue into one run; a second run the same night finds it empty', async () => {
    const before = (await brainStub(env).state()).runs.length;
    const fire = async () => {
      const ctx = createExecutionContext();
      await worker.scheduled(createScheduledController({ cron: CRONS.nightly, scheduledTime: Date.now() }), env, ctx);
      await waitOnExecutionContext(ctx);
    };
    await fire();
    const mid = await brainStub(env).state();
    expect(mid.jobs.queuedNightly).toBe(0);
    await fire();
    expect((await brainStub(env).state()).runs.length).toBe(mid.runs.length);
    expect(mid.runs.length).toBeGreaterThanOrEqual(before);
  });
});
