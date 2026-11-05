// Ruling I-4: the hands refuse on unknown or over-threshold weekly usage.
import { mkdtemp, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { decide, readingFromManual, readingFromSnapshot, readingFromStreamEvent, UsageGuard } from '../lib/usage-guard.mjs';

const NOW = 1_794_000_000;
const ev = (util, resetsAt = NOW + 86400, extra = {}) => ({ type: 'rate_limit_event', rate_limit_info: { status: 'allowed', rateLimitType: 'seven_day', utilization: util, resetsAt, unifiedWindows: { seven_day: { utilization: util, resetsAt } }, ...extra } });

describe('readings', () => {
  it('reads the CLI rate_limit_event (measured shape: utilization is a fraction)', () => {
    expect(readingFromStreamEvent(ev(0.96), NOW)).toMatchObject({ src: 'claude-cli', pct: 96 });
    expect(readingFromStreamEvent({ type: 'rate_limit_event', rate_limit_info: { status: 'allowed', rateLimitType: 'five_hour', utilization: 0.2 } }, NOW)).toBeNull();
    expect(readingFromStreamEvent({ type: 'result' }, NOW)).toBeNull();
    expect(readingFromStreamEvent(ev(0.5, NOW - 10), NOW)).toBeNull(); // pre-reset reading is unusable
    expect(readingFromStreamEvent({ type: 'rate_limit_event', rate_limit_info: { status: 'rejected', rateLimitType: 'seven_day', resetsAt: NOW + 10 } }, NOW)).toMatchObject({ pct: 100 });
  });
  it('snapshot and manual follow the sentinel rules (freshness, range, future, reset)', () => {
    expect(readingFromSnapshot({ t: NOW - 60, rl: { seven_day: { used_percentage: 40, resets_at: NOW + 99 } } }, NOW).reading).toMatchObject({ pct: 40 });
    expect(readingFromSnapshot({ t: NOW - 901, rl: { seven_day: { used_percentage: 40 } } }, NOW).why).toMatch(/old/);
    expect(readingFromSnapshot({ t: NOW + 400, rl: { seven_day: { used_percentage: 40 } } }, NOW).why).toMatch(/future/);
    expect(readingFromSnapshot({ t: NOW, rl: { seven_day: { used_percentage: 140 } } }, NOW).why).toMatch(/outside/);
    expect(readingFromManual({ pct: 30, t: NOW - 100 }, NOW).reading).toMatchObject({ src: 'manual', pct: 30 });
    expect(readingFromManual({ pct: 30, t: NOW - 4000 }, NOW).why).toMatch(/old/);
    expect(readingFromManual(null, NOW).why).toMatch(/missing/);
  });
  it('decide: unknown refuses; at or over the threshold refuses; under allows', () => {
    expect(decide(null, 80)).toMatchObject({ allowed: false, reason: expect.stringMatching(/usage-unknown/) });
    expect(decide({ src: 'x', pct: 80 }, 80).allowed).toBe(false);
    expect(decide({ src: 'x', pct: 95 }, 80).allowed).toBe(false);
    expect(decide({ src: 'x', pct: 79.9 }, 80).allowed).toBe(true);
  });
});

describe('UsageGuard', () => {
  const nowS = () => NOW;
  it('refuses when nothing is known and the probe yields no weekly reading', async () => {
    const g = new UsageGuard({ thresholdPct: 80, probe: async () => [{ type: 'result' }], nowS });
    const d = await g.check();
    expect(d.allowed).toBe(false);
    expect(d.reason).toMatch(/usage-unknown/);
  });
  it('refuses when the probe throws (unknown is never low)', async () => {
    const g = new UsageGuard({ thresholdPct: 80, probe: async () => Promise.reject(new Error('no auth')), nowS });
    expect(await g.check()).toMatchObject({ allowed: false, reason: expect.stringMatching(/probe failed: no auth/) });
  });
  it('probes once, then uses the live readings each job reports', async () => {
    let probes = 0;
    const g = new UsageGuard({ thresholdPct: 80, probe: async () => (probes++, [ev(0.2)]), nowS });
    expect((await g.check()).allowed).toBe(true);
    g.observe(ev(0.85));
    expect(await g.check()).toMatchObject({ allowed: false, reason: expect.stringMatching(/85% >= threshold 80%/) });
    expect(probes).toBe(1);
  });
  it('uses the Mac sources when fresh (newest wins) and ignores stale ones', async () => {
    const d = await mkdtemp(join(tmpdir(), 'hands-usage-'));
    await writeFile(join(d, 'manual.json'), JSON.stringify({ pct: 90, t: NOW - 600 }));
    await writeFile(join(d, 'snap.json'), JSON.stringify({ t: NOW - 60, rl: { seven_day: { used_percentage: 30 } } }));
    const g = new UsageGuard({ thresholdPct: 80, manualPath: join(d, 'manual.json'), snapshotPath: join(d, 'snap.json'), probe: null, nowS });
    expect(await g.check()).toMatchObject({ allowed: true, reading: { src: 'snapshot', pct: 30 } });
    await writeFile(join(d, 'snap.json'), JSON.stringify({ t: NOW - 5000, rl: { seven_day: { used_percentage: 30 } } }));
    expect(await g.check()).toMatchObject({ allowed: false, reading: { src: 'manual', pct: 90 } });
  });
});
