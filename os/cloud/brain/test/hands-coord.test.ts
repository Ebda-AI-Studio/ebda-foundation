// HANDS-COORD (launch map): controller leases keep the hands out of a repo a controller is working in, and an external monitor
// (prod-watch) reports its complete listing so cleared alerts resolve in the brain. Each rule has a must-fire and a must-not-fire case.
import { env } from 'cloudflare:workers';
import { SELF } from 'cloudflare:test';
import { describe, expect, it } from 'vitest';
import { brainStub } from '../src/index';
import type { HandsJob } from '../src/hands';

const jobsOf = (b: unknown): HandsJob[] => (b && typeof b === 'object' && 'jobs' in b ? ((b as { jobs: HandsJob[] }).jobs ?? []) : []);

const ING = { Authorization: 'Bearer test-ingest-token' };
const MAC = { Authorization: 'Bearer test-mac-token' };
const req = (path: string, method: string, body?: unknown, headers: Record<string, string> = ING) =>
  SELF.fetch(`https://brain.test${path}`, { method, headers, ...(body === undefined ? {} : { body: JSON.stringify(body) }) });

describe('controller leases', () => {
  it('a lease is exclusive, needs INGEST_TOKEN, validates input and is released only by its holder', async () => {
    expect((await req('/leases', 'POST', { repo: 'o/lease1', holder: 'a' }, {})).status).toBe(401);
    expect((await req('/leases', 'POST', { repo: 'not a repo', holder: 'a' })).status).toBe(400);
    expect((await req('/leases', 'POST', { repo: 'o/lease1', holder: 'bad holder!' })).status).toBe(400);
    expect((await req('/leases', 'POST', { repo: 'o/lease1', holder: 'a', ttlMin: -1 })).status).toBe(400);
    const first = await req('/leases', 'POST', { repo: 'O/Lease1', holder: 'session-a', ttlMin: 9999 });
    expect(first.status).toBe(200);
    const f = (await first.json()) as { ok: boolean; expiresAt: number };
    expect(f.ok).toBe(true);
    expect(f.expiresAt - Date.now()).toBeLessThanOrEqual(240 * 60_000 + 5_000); // capped at LEASE_MAX_MIN
    const clash = await req('/leases', 'POST', { repo: 'o/lease1', holder: 'session-b' });
    expect(clash.status).toBe(409);
    expect(((await clash.json()) as { holder: string }).holder).toBe('session-a');
    expect(((await (await req('/leases', 'DELETE', { repo: 'o/lease1', holder: 'session-b' })).json()) as { released: boolean }).released).toBe(false);
    expect(((await (await req('/leases', 'DELETE', { repo: 'o/lease1', holder: 'session-a' })).json()) as { released: boolean }).released).toBe(true);
    expect((await req('/leases', 'POST', { repo: 'o/lease1', holder: 'session-b' })).status).toBe(200);
    await req('/leases', 'DELETE', { repo: 'o/lease1', holder: 'session-b' });
  });

  it('the hands read the live leases with their Mac token; no token, no answer', async () => {
    await req('/leases', 'POST', { repo: 'o/lease2', holder: 'ctl', note: 'fixing CI' });
    expect((await req('/hands/leases', 'GET', undefined, {})).status).toBe(401);
    expect((await req('/hands/leases', 'GET', undefined, ING)).status).toBe(401); // the ingest token is not a hands token
    const got = (await (await req('/hands/leases', 'GET', undefined, MAC)).json()) as { leases: Array<{ repo: string; holder: string }> };
    expect(got.leases.find((l) => l.repo === 'o/lease2')?.holder).toBe('ctl');
    await req('/leases', 'DELETE', { repo: 'o/lease2', holder: 'ctl' });
  });

  it('a queued job on a leased repo is NOT handed out; the same job is handed out once the lease is released', async () => {
    await req('/findings', 'POST', { source: 'dream', kind: 'test', key: 'coord-leased-1', title: 't', repo: 'o/leased' });
    await req('/leases', 'POST', { repo: 'o/leased', holder: 'ctl' });
    const held = await brainStub(env).claim('mac-local', 25);
    expect(jobsOf(held).some((j) => j.finding.repo === 'o/leased')).toBe(false); // must not fire while leased
    await req('/leases', 'DELETE', { repo: 'o/leased', holder: 'ctl' });
    const freed = await brainStub(env).claim('mac-local', 25);
    expect(jobsOf(freed).some((j) => j.finding.repo === 'o/leased')).toBe(true); // fires once released
  });
});

describe('prod-watch listing reconcile', () => {
  const pw = (key: string, kind = 'prod-5xx') => ({ source: 'prod-watch', kind, key, title: key, severity: 'P2' });

  it('resolves keys that left the listing, keeps the unknown ones, and records the heartbeat', async () => {
    const r1 = (await (await req('/findings', 'POST', { findings: [pw('storefront-5xx'), pw('exceptions:api', 'prod-exception')], reconcile: { source: 'prod-watch' } })).json()) as { raised: number; resolved: number };
    expect(r1.raised).toBe(2);
    expect(r1.resolved).toBe(0);
    // next run: logs could not be read -> exceptions:* is unknown and must stay open; storefront-5xx is unknown too (kept)
    const r2 = (await (await req('/findings', 'POST', { findings: [], reconcile: { source: 'prod-watch', keep: ['exceptions:', 'storefront-5xx'] } })).json()) as { resolved: number };
    expect(r2.resolved).toBe(0); // must not fire
    // next run: everything evaluated, nothing alerting -> both resolve
    const r3 = (await (await req('/findings', 'POST', { findings: [], reconcile: { source: 'prod-watch' } })).json()) as { resolved: number };
    expect(r3.resolved).toBe(2); // must fire
    const s = await brainStub(env).state();
    expect(typeof s.sources.prodWatchSeenAt).toBe('number');
  });

  it('never resolves another source and rejects a mixed listing', async () => {
    await req('/findings', 'POST', { source: 'dream', kind: 'docs', key: 'other-src-1', title: 't' });
    const mixed = await req('/findings', 'POST', { findings: [{ source: 'dream', kind: 'docs', key: 'x', title: 't' }], reconcile: { source: 'prod-watch' } });
    expect(mixed.status).toBe(400);
    expect((await req('/findings', 'POST', { findings: [], reconcile: { source: 'bad source!' } })).status).toBe(400);
    await req('/findings', 'POST', { findings: [], reconcile: { source: 'prod-watch' } });
    const s = await brainStub(env).state();
    const row = s.findings.recent.find((f) => f.title === 't' && f.source === 'dream');
    expect(row?.status).not.toBe('resolved');
  });

  it('an alert drill is digest-only, never a hands job', async () => {
    await req('/findings', 'POST', { findings: [{ source: 'prod-watch', kind: 'alert-drill', key: 'alert-drill:2026-11-10', title: 'drill' }], reconcile: { source: 'prod-watch' } });
    const s = await brainStub(env).state();
    expect(s.findings.recent.find((f) => f.kind === 'alert-drill')?.lane).toBe('digest');
  });
});

describe('prod-watch dead-man switch (AIOS-7: brain cron primary, GitHub secondary)', () => {
  it('GitHub-hosted run silent > 24 h: one digest note (never a page); a new report resolves it', async () => {
    const brain = brainStub(env);
    const t0 = Date.now();
    await req('/findings', 'POST', { findings: [], reconcile: { source: 'prod-watch' } });
    await brain.checkProdWatchAlive(t0 + 23 * 3_600_000);
    let s = await brain.state();
    expect(s.findings.recent.some((f) => f.kind === 'monitor-stale' && f.status !== 'resolved')).toBe(false); // must not fire at 23 h
    await brain.checkProdWatchAlive(t0 + 25 * 3_600_000);
    s = await brain.state();
    const row = s.findings.recent.find((f) => f.kind === 'monitor-stale');
    expect(row?.lane).toBe('digest'); // must fire, digest only
    await req('/findings', 'POST', { findings: [], reconcile: { source: 'prod-watch' } });
    await brain.checkProdWatchAlive(Date.now());
    s = await brain.state();
    expect(s.findings.recent.find((f) => f.kind === 'monitor-stale')?.status).toBe('resolved');
  });

  it('the brain-cron run not completing for > 30 min: one monitor-silent P1 alert; completing again resolves it', async () => {
    const brain = brainStub(env);
    const t0 = Date.now();
    await brain.reconcileSource('prod-watch', [], [], t0, 'prod-watch-cf');
    await brain.checkProdWatchAlive(t0 + 20 * 60_000);
    let s = await brain.state();
    expect(s.findings.recent.some((f) => f.kind === 'monitor-silent' && f.status !== 'resolved')).toBe(false); // must not fire at 20 min
    await brain.checkProdWatchAlive(t0 + 31 * 60_000);
    s = await brain.state();
    const row = s.findings.recent.find((f) => f.kind === 'monitor-silent');
    expect(row?.lane).toBe('digest'); // ALERT_KINDS: digest lane + one P1 message, never a hands job
    expect(row?.status).not.toBe('resolved');
    await brain.reconcileSource('prod-watch', [], [], Date.now(), 'prod-watch-cf');
    await brain.checkProdWatchAlive(Date.now());
    s = await brain.state();
    expect(s.findings.recent.find((f) => f.kind === 'monitor-silent')?.status).toBe('resolved');
    expect(typeof s.sources.prodWatchCfSeenAt).toBe('number');
  });
});
