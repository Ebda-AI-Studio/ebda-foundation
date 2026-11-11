// workerd's global fetch must not be called as a method of another object (`ctx.fetchImpl(url)` / `this.fetchImpl(url)`): it throws
// "Illegal invocation" before any network I/O. Every cloud watcher read its sources that way, so in production each fetch became
// "network error" / "no response" while the unit tests (which inject a mock) stayed green. Measured 2026-11-11: page-load,
// journey-monitor and world-watch all failing against healthy hosts. The defaults now wrap fetch in an arrow function.
import { describe, expect, it } from 'vitest';
import { boundFetch } from '../src/bound-fetch';
import { GitHubHost } from '../src/githost';

describe('the default fetch is callable as a property (workerd Illegal invocation)', () => {
  it('a raw global fetch stored on an object throws Illegal invocation in workerd (the defect, must fire)', () => {
    const holder = { f: fetch };
    expect(() => holder.f('https://unreachable.invalid/')).toThrow(/Illegal invocation/);
  });

  it('boundFetch stored on an object is a normal fetch: it gets as far as the network (must not fire)', async () => {
    const holder = { f: boundFetch };
    let err: unknown = null;
    try {
      await holder.f('https://unreachable.invalid/');
    } catch (e) {
      err = e;
    }
    expect(String(err)).not.toMatch(/Illegal invocation/);
  });

  it('GitHubHost (a class field) defaults to the bound fetch', async () => {
    const g = new GitHubHost('t') as unknown as { fetchImpl: typeof fetch };
    let err: unknown = null;
    try {
      await g.fetchImpl('https://unreachable.invalid/');
    } catch (e) {
      err = e;
    }
    expect(String(err)).not.toMatch(/Illegal invocation/);
  });
});
