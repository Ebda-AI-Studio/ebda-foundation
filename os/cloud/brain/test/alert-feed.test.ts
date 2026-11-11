// AIOS-8: the platform's Telegram alerts mirrored into the brain. Must fire: an alert is stored with an id, readable newest-first
// through the authenticated GET /api/alerts?since=, and a P1 becomes a finding. Must not fire: no token / bad shape is refused, the
// same alert inside 10 min is one row (count 2), an info alert makes no finding, and /api/alerts without auth is 401.
import { env } from 'cloudflare:workers';
import { createExecutionContext, SELF, waitOnExecutionContext } from 'cloudflare:test';
import { describe, expect, it } from 'vitest';
import type { Env } from '../src/env';
import worker, { brainStub } from '../src/index';

const PW = 'alert-feed-test-password';
const ING = { Authorization: 'Bearer test-ingest-token' };
const post = (body: unknown, headers: Record<string, string> = ING) => SELF.fetch('https://brain.test/alerts', { method: 'POST', headers, body: JSON.stringify(body) });
async function api(path: string, auth = true) {
  const e = { ...env, DASH_BASIC_PASSWORD: PW } as Env;
  const ctx = createExecutionContext();
  const r = await worker.fetch(new Request(`https://brain.test${path}`, { headers: auth ? { Authorization: `Basic ${btoa(`ahmad:${PW}`)}` } : {} }) as never, e, ctx);
  await waitOnExecutionContext(ctx);
  return r;
}
const a = (title: string, level = 'p1', text = `${title} details`) => ({ source: 'ebda-store/api', level, title, text });

describe('platform alert feed', () => {
  it('refuses without the ingest token or with a bad shape', async () => {
    expect((await post(a('x'), {})).status).toBe(401);
    expect((await post({ source: 's', level: 'loud', title: 't', text: 'x' })).status).toBe(400);
    expect((await post({ source: 's', level: 'p1', title: 't' })).status).toBe(400);
  });

  it('stores, dedupes, serves newest first since an id, and turns a P1 into a finding (not an info)', async () => {
    const r1 = (await (await post(a('Ebda Store nightly backup sweep FAILED'))).json()) as { recorded: Array<{ id: number; deduped: boolean }> };
    const first = r1.recorded[0]!;
    expect(first.deduped).toBe(false);
    const again = (await (await post(a('Ebda Store nightly backup sweep FAILED'))).json()) as { recorded: Array<{ id: number; deduped: boolean }> };
    expect(again.recorded[0]).toEqual({ id: first.id, deduped: true }); // must not make a second row
    await post(a('billing-renewal-daily failed', 'p1'));
    await post(a('deploy finished', 'info'));
    expect((await api(`/api/alerts?since=${first.id - 1}`, false)).status).toBe(401);
    const got = (await (await api(`/api/alerts?since=${first.id - 1}`)).json()) as { alerts: Array<{ id: number; title: string; count: number }> };
    expect(got.alerts.map((x) => x.title)).toEqual(['deploy finished', 'billing-renewal-daily failed', 'Ebda Store nightly backup sweep FAILED']);
    expect(got.alerts[2]!.count).toBe(2);
    const newer = (await (await api(`/api/alerts?since=${got.alerts[1]!.id}`)).json()) as { alerts: unknown[] };
    expect(newer.alerts).toHaveLength(1);
    expect((await api('/api/alerts?since=-1')).status).toBe(400);
    const s = await brainStub(env).state();
    const kinds = s.findings.recent.filter((f) => f.kind === 'platform-alert').map((f) => f.title);
    expect(kinds).toContain('Ebda Store nightly backup sweep FAILED'); // must fire
    expect(kinds).toContain('billing-renewal-daily failed');
    expect(kinds).not.toContain('deploy finished'); // must not fire
  });
});

describe('failed default-branch workflow runs land in the feed (every workflow notify step pages on exactly this)', () => {
  async function hook(conclusion: string, branch: string) {
    const body = JSON.stringify({ action: 'completed', repository: { full_name: 'Ebda-AI-Studio/ebda-store', default_branch: 'main' }, workflow_run: { id: Math.floor(Math.random() * 1e9), run_attempt: 1, updated_at: new Date().toISOString(), conclusion, head_sha: 'abcdef1234', head_branch: branch, name: 'Cloudflare data backup', html_url: 'https://github.com/Ebda-AI-Studio/ebda-store/actions/runs/1' } });
    const key = await crypto.subtle.importKey('raw', new TextEncoder().encode('test-gh-secret'), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
    const mac = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(body));
    const sig = `sha256=${[...new Uint8Array(mac)].map((b) => b.toString(16).padStart(2, '0')).join('')}`;
    const r = await SELF.fetch('https://brain.test/github/webhook', { method: 'POST', headers: { 'X-GitHub-Event': 'workflow_run', 'X-GitHub-Delivery': crypto.randomUUID(), 'X-Hub-Signature-256': sig, 'content-type': 'application/json' }, body });
    await new Promise((res) => setTimeout(res, 50));
    return r;
  }
  it('a failure on main is recorded (must fire); a failure on a PR branch and a success on main are not (must not fire)', async () => {
    const before = (await brainStub(env).alertsSince(0, 500)).filter((x) => String(x.source).startsWith('github/')).length;
    await hook('failure', 'feature/x');
    await hook('success', 'main');
    expect((await brainStub(env).alertsSince(0, 500)).filter((x) => String(x.source).startsWith('github/')).length).toBe(before);
    await hook('failure', 'main');
    const rows = (await brainStub(env).alertsSince(0, 500)).filter((x) => String(x.source).startsWith('github/'));
    expect(rows.length).toBe(before + 1);
    expect(rows[0]!.title).toBe('Cloudflare data backup failed on main (Ebda-AI-Studio/ebda-store)');
  });
});

describe('LOOP-WATCH-2: an overdue-control finding also lands in the controller feed (alert-wait.sh reads only /api/alerts)', () => {
  it('loop-main-red and loop-merge-stall each make ONE p1 feed row; a re-sighting adds none; a plain digest finding adds none', async () => {
    const brain = brainStub(env);
    const R = 'Ebda-AI-Studio/ebda-store';
    const before = (await brain.alertsSince(0, 500)).length;
    const red = { source: 'watcher', kind: 'loop-main-red', key: `loop-stall:${R}:red-101`, title: `main CI of ${R} has been red for 168 min (since run 101)`, repo: R, url: `https://github.com/${R}/actions/runs/101`, severity: 'P1' as const };
    const stall = { source: 'watcher', kind: 'loop-merge-stall', key: `loop-stall:${R}:since-1`, title: `no merge in ${R} for 190 min while 17 approved PR(s) wait`, repo: R, severity: 'P1' as const };
    await brain.ingestMany([red, stall], Date.now());
    await brain.ingestMany([red, stall], Date.now() + 15 * 60_000); // next tick: same incident, deduped
    await brain.ingestMany([{ source: 'watcher', kind: 'monitor-unconfigured', key: 'x:config:unconfigured', title: 'watcher x is not running', severity: 'P3' as const }], Date.now());
    const feed = await brain.alertsSince(0, 500);
    expect(feed.length - before).toBe(2); // must fire twice, must not fire for the re-sighting or the P3
    const mine = feed.filter((x) => x.source.startsWith('brain/loop-'));
    expect(mine.map((x) => [x.source, x.level, x.repo])).toEqual([['brain/loop-merge-stall', 'p1', R], ['brain/loop-main-red', 'p1', R]]);
    // asFinding=false: the mirror must not create a second (platform-alert) finding for the same incident
    const s = await brain.state();
    expect(s.findings.recent.filter((f) => f.kind === 'platform-alert' && f.title.includes('has been red for 168 min'))).toEqual([]);
  });
});
