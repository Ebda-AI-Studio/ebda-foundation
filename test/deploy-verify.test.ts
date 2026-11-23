import { describe, expect, it } from 'vitest';
// @ts-expect-error plain .mjs without types
import { runChecks, runUntilRolledOut, verdict } from '../ops/deploy-verify.mjs';

const SHA = 'abcdef1234567890abcdef1234567890abcdef12';
const run = (over: Record<string, unknown>) => ({ id: 1, workflow_id: 7, run_number: 3, name: 'Deploy API', path: '.github/workflows/deploy.yml', status: 'completed', conclusion: 'success', ...over });

/** A fake fetch that answers by URL substring; anything else is a 404 so an unexpected call fails loudly. */
const fakeFetch = (routes: Record<string, unknown | ((init?: RequestInit) => unknown)>, ok = true) =>
  (async (url: string, init?: RequestInit) => {
    const key = Object.keys(routes).find((k) => String(url).includes(k));
    if (!key) return new Response('{}', { status: 404 });
    const v = routes[key];
    return new Response(JSON.stringify(typeof v === 'function' ? v(init) : v), { status: ok ? 200 : 500 });
  }) as unknown as typeof fetch;

const base = { base: 'https://api.test', expectCommit: SHA, repo: 'o/r', workflow: 'deploy', worker: 'w', crons: ['17 1 * * *'], ghToken: 'g', cfToken: 'c', cfAccount: 'a' };
const green = {
  '/actions/runs': { workflow_runs: [run({})] },
  '/health': { ok: true, commit: SHA.slice(0, 9) },
  '/schedules': { success: true, result: { schedules: [{ cron: '17 1 * * *' }] } },
  '/graphql': { data: { viewer: { accounts: [{ workersInvocationsScheduled: [{ sum: { requests: 2 }, dimensions: { status: 'success', cron: '17 1 * * *' } }] }] } } },
};
const byName = (r: { name: string; ok: boolean | null; detail: string }[], n: string) => r.find((x) => x.name === n)!;

describe('deploy-verify', () => {
  it('all four checks pass when the deploy is green, live and ticking', async () => {
    const r = await runChecks({ ...base, fetchImpl: fakeFetch(green) });
    expect(r.map((x: { ok: boolean | null }) => x.ok)).toEqual([true, true, true, true]);
    expect(verdict(r).text).toBe('VERIFIED');
  });
  it('a cancelled latest run fails check 1, a green re-run after a cancelled one passes', async () => {
    const cancelled = await runChecks({ ...base, fetchImpl: fakeFetch({ ...green, '/actions/runs': { workflow_runs: [run({ conclusion: 'cancelled' })] } }) });
    expect(byName(cancelled, 'deploy job green').ok).toBe(false);
    const rerun = await runChecks({ ...base, fetchImpl: fakeFetch({ ...green, '/actions/runs': { workflow_runs: [run({ conclusion: 'cancelled', run_number: 2 }), run({ run_number: 4 })] } }) });
    expect(byName(rerun, 'deploy job green').ok).toBe(true);
  });
  it('no matching run means the deploy never started (fail, not skip)', async () => {
    const r = await runChecks({ ...base, fetchImpl: fakeFetch({ ...green, '/actions/runs': { workflow_runs: [run({ name: 'Lint', path: '.github/workflows/lint.yml' })] } }) });
    expect(byName(r, 'deploy job green')).toMatchObject({ ok: false });
  });
  it('a stale or empty /health commit fails; an unreachable health fails', async () => {
    const stale = await runChecks({ ...base, fetchImpl: fakeFetch({ ...green, '/health': { ok: true, commit: '1111111' } }) });
    expect(byName(stale, 'health commit')).toMatchObject({ ok: false, detail: expect.stringMatching(/^running 1111111/) });
    const empty = await runChecks({ ...base, fetchImpl: fakeFetch({ ...green, '/health': { ok: true, commit: null } }) });
    expect(byName(empty, 'health commit').ok).toBe(false);
    const down = await runChecks({ ...base, fetchImpl: (async () => { throw new Error('boom'); }) as unknown as typeof fetch });
    expect(byName(down, 'health commit').detail).toContain('unreachable');
  });
  it('live schedules must EQUAL the config: a missing or an extra schedule fails', async () => {
    const missing = await runChecks({ ...base, fetchImpl: fakeFetch({ ...green, '/schedules': { success: true, result: { schedules: [] } } }) });
    expect(byName(missing, 'live schedules match')).toMatchObject({ ok: false, detail: expect.stringContaining('missing live: "17 1 * * *"') });
    const extra = await runChecks({ ...base, fetchImpl: fakeFetch({ ...green, '/schedules': { success: true, result: { schedules: [{ cron: '17 1 * * *' }, { cron: '0 0 * * *' }] } } }) });
    expect(byName(extra, 'live schedules match').ok).toBe(false);
  });
  it('no scheduled invocation in the window fails check 4; only failed invocations fail it too', async () => {
    const none = await runChecks({ ...base, fetchImpl: fakeFetch({ ...green, '/graphql': { data: { viewer: { accounts: [{ workersInvocationsScheduled: [] }] } } } }) });
    expect(byName(none, 'one tick seen').ok).toBe(false);
    const failedOnly = await runChecks({ ...base, fetchImpl: fakeFetch({ ...green, '/graphql': { data: { viewer: { accounts: [{ workersInvocationsScheduled: [{ sum: { requests: 1 }, dimensions: { status: 'exception' } }] }] } } } }) });
    expect(byName(failedOnly, 'one tick seen').ok).toBe(false);
  });
  it('a check it cannot run is SKIP with the reason, never PASS; strict turns skips into failures', async () => {
    const r = await runChecks({ ...base, ghToken: undefined, cfToken: undefined, fetchImpl: fakeFetch(green) });
    expect(byName(r, 'deploy job green')).toMatchObject({ ok: null, detail: expect.stringContaining('GH_TOKEN') });
    expect(byName(r, 'live schedules match').ok).toBeNull();
    expect(verdict(r).text).toMatch(/^VERIFIED \(with skips/);
    expect(verdict(r, true).text).toBe('NOT VERIFIED');
  });
  it('retries only a stale commit, never another failure', async () => {
    let n = 0;
    const seq = async () => (++n < 3 ? [{ name: 'health commit', ok: false, detail: 'running old, expected new' }] : [{ name: 'health commit', ok: true, detail: 'ok' }]);
    const res = await runUntilRolledOut(seq, { sleep: async () => {}, windowMs: 60_000, intervalMs: 1_000 });
    expect(n).toBe(3);
    expect(res[0].ok).toBe(true);
    let m = 0;
    await runUntilRolledOut(async () => (++m, [{ name: 'live schedules match', ok: false, detail: 'x' }]), { sleep: async () => {} });
    expect(m).toBe(1);
  });
});
