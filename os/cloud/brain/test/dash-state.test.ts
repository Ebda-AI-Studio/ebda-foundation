// The dashboard's state additions: Cloudflare limits, the watcher gaps with what each is missing, and a digest preview that
// sends nothing and writes nothing.
import { env } from 'cloudflare:workers';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { brainStub } from '../src/index';

afterEach(() => vi.restoreAllMocks());

describe('dashboard state', () => {
  it('carries the Cloudflare warn/stop levels, the unconfigured watchers with what they miss, and a digest preview', async () => {
    const send = vi.spyOn(globalThis, 'fetch');
    const brain = brainStub(env);
    await brain.ingestFinding({ source: 'watcher', kind: 'monitor-unconfigured', key: 'cf-usage:config:unconfigured', title: 'watcher cf-usage is not running: CF_API_TOKEN secret and CF_ACCOUNT_ID is not set' });
    const s = await brain.state();
    expect(s.cfLimits).toEqual({ warnUsd: 10, stopUsd: 20 });
    expect(s.gaps).toContainEqual({ id: 'cf-usage', missing: 'CF_API_TOKEN secret and CF_ACCOUNT_ID' });
    expect(s.digestPreview).toMatch(/^Ebda OS daily digest \d{4}-\d{2}-\d{2}/);
    expect(s.digestPreview).toContain('Hands spend: $0.00 of $150 this month');
    // the preview is built, never sent, and rendering it twice gives the same text (nothing marked shown)
    expect(send.mock.calls.filter(([u]) => String(u).includes('api.telegram.org'))).toHaveLength(0);
    expect((await brain.state()).digestPreview).toBe(s.digestPreview);
  });
});
