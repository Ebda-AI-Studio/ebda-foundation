// AIOS-7: the primary prod-watch probes run on the brain tick. Must fire: two failing runs in a row open probe:<name> as a finding and
// send ONE Telegram P1; recovery resolves it. Must not fire: a healthy run sends nothing; a run inside 10 min of the last is skipped;
// the GitHub run's log-rule findings are never resolved from here.
import { env } from 'cloudflare:workers';
import { describe, expect, it } from 'vitest';
import { brainStub } from '../src/index';
import { PROD_WATCH_INTERVAL_MS, runProdWatch } from '../src/prod-watch';
import type { Env } from '../src/env';

const on = { ...(env as unknown as Env), PROD_WATCH_ON_BRAIN: '1' } as Env;
const fakeFetch = (down: Set<string>, tg: string[]) =>
  (async (input: RequestInfo | URL) => {
    const u = String(input instanceof Request ? input.url : input);
    if (u.includes('api.telegram.org')) {
      tg.push(u);
      return Response.json({ ok: true, result: { message_id: 1 } });
    }
    const host = new URL(u).host;
    if ([...down].some((d) => host.startsWith(d))) return new Response('down', { status: 503 });
    // every probe in os/config/prod-watch.json expects 200 and some check the body for the brand / ok
    return new Response('ebda "status":"ok" "ok":true data-zone=x', { status: 200 });
  }) as typeof fetch;

describe('prod-watch on the brain cron', () => {
  it('off unless PROD_WATCH_ON_BRAIN=1', async () => {
    expect(await runProdWatch({ ...on, PROD_WATCH_ON_BRAIN: '0' } as Env, brainStub(env), Date.now(), fakeFetch(new Set(), []))).toBeNull();
  });

  it('down twice -> one P1 message + an open probe finding; inside 10 min -> skipped; recovery resolves; log findings untouched', async () => {
    const brain = brainStub(env);
    await brain.ingestMany([{ source: 'prod-watch', kind: 'prod-5xx', key: 'storefront-5xx', title: 'from the GitHub run' }], Date.now());
    const tg: string[] = [];
    let t = Date.now() + 365 * 86_400_000; // clear of any earlier run's KV gate
    const healthy = await runProdWatch(on, brain, t, fakeFetch(new Set(), tg));
    expect(healthy).toMatchObject({ failing: 0, messages: 0 });
    expect(await runProdWatch(on, brain, t + 60_000, fakeFetch(new Set(['api.']), tg))).toBeNull(); // not due
    t += PROD_WATCH_INTERVAL_MS;
    expect(await runProdWatch(on, brain, t, fakeFetch(new Set(['api.']), tg))).toMatchObject({ failing: 1, messages: 0 }); // streak 1 < budget 2
    t += PROD_WATCH_INTERVAL_MS;
    expect(await runProdWatch(on, brain, t, fakeFetch(new Set(['api.']), tg))).toMatchObject({ failing: 1, messages: 1 }); // must fire
    expect(tg.length).toBe(1);
    let s = await brain.state();
    expect(s.findings.recent.find((f) => f.title.startsWith('api down'))?.status).not.toBe('resolved');
    t += PROD_WATCH_INTERVAL_MS;
    await runProdWatch(on, brain, t, fakeFetch(new Set(), tg)); // recovered: "resolved" message + finding resolved
    s = await brain.state();
    expect(s.findings.recent.find((f) => f.title.startsWith('api down'))?.status).toBe('resolved');
    expect(s.findings.recent.find((f) => f.title === 'from the GitHub run')?.status).not.toBe('resolved'); // must not fire
    expect(typeof s.sources.prodWatchCfSeenAt).toBe('number');
  });
});
