import { env } from 'cloudflare:workers';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { brainStub } from '../src/index';
import { alertToFinding, GitHubHost, loadKev } from '../src/githost';
import { checkOne, parseTargets } from '../src/watchers/health';
import { orgsFrom, watchAdvisories } from '../src/watchers/advisories';
import { classifyFinding } from '../src/classify';

afterEach(() => vi.restoreAllMocks());

const alert = (o: { repo?: string; ghsa?: string; cve?: string | null; score?: number; scope?: string }) => ({
  html_url: 'https://gh/alert/1',
  repository: { full_name: o.repo ?? 'org-a/app' },
  dependency: { scope: o.scope ?? 'runtime', package: { name: 'lib', ecosystem: 'npm' }, manifest_path: 'package-lock.json' },
  security_advisory: { ghsa_id: o.ghsa ?? 'GHSA-1', cve_id: o.cve ?? 'CVE-2026-1', severity: 'critical', cvss_severities: { cvss_v3: { score: o.score ?? 9.8 } } },
});

describe('health watcher', () => {
  it('parses only https targets of known kinds', () => {
    expect(parseTargets('[{"url":"http://x","kind":"api"},{"url":"https://y","kind":"page"},{"url":"https://z","kind":"weird"}]')).toEqual([{ url: 'https://y', kind: 'page' }]);
    expect(parseTargets('not json')).toEqual([]);
  });
  it('a 200 with ok:false is a failure; a network error is a failure', async () => {
    const f200 = (async () => Response.json({ ok: false })) as unknown as typeof fetch;
    expect((await checkOne({ url: 'https://a/health', kind: 'api' }, f200)).ok).toBe(false);
    const fErr = (async () => {
      throw new Error('dns');
    }) as unknown as typeof fetch;
    expect(await checkOne({ url: 'https://a/health', kind: 'api' }, fErr)).toMatchObject({ ok: false, status: 0 });
  });
});

describe('advisory watcher', () => {
  it('maps a Dependabot alert, tags KEV and keeps the scope', () => {
    const f = alertToFinding(alert({ scope: 'development', score: 8.8 }), new Set(['CVE-2026-1']))!;
    expect(f).toMatchObject({ kind: 'dependency-advisory', key: 'org-a/app#GHSA-1', cvss: 8.8, kev: true, depScope: 'development' });
    expect(classifyFinding(f).lane).toBe('nightly'); // dev-only: never urgent, even when KEV-listed
  });
  it('sends If-None-Match and treats 304 as not modified', async () => {
    const calls: Array<Record<string, string>> = [];
    const f = (async (_u: string, init: RequestInit) => {
      calls.push(init.headers as Record<string, string>);
      return new Response(null, { status: 304 });
    }) as unknown as typeof fetch;
    const page = await new GitHubHost('t', f).openDependencyAlerts('org-a', '"etag-1"', new Set());
    expect(page.notModified).toBe(true);
    expect(calls[0]!['if-none-match']).toBe('"etag-1"');
  });
  it('runs at most hourly, ingests alerts, stores the ETag, resolves alerts that disappeared', async () => {
    const now = Date.UTC(2026, 10, 5, 9);
    const brain = brainStub(env);
    let listing = [alert({ ghsa: 'GHSA-a' }), alert({ ghsa: 'GHSA-b', score: 5, cve: null })];
    const host = {
      name: 'fake',
      async openDependencyAlerts(org: string, etag: string | null, kev: ReadonlySet<string>) {
        return { notModified: false, etag: `"${org}-${listing.length}"`, complete: true, alerts: org === 'org-a' ? listing.map((a) => alertToFinding(a, kev)!) : [] };
      },
    };
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(Response.json({ vulnerabilities: [{ cveID: 'CVE-2026-1' }] }, { headers: { etag: '"kev-1"' } }));
    const s1 = await watchAdvisories({ ...env, GITHUB_TOKEN: 'x' }, brain, now, fetch, host);
    expect(s1.orgs[0]).toMatchObject({ org: 'org-a', alerts: 2, raised: 2 });
    expect(await env.EVENTS.get('adv:etag:org-a', 'json')).toEqual({ etag: '"org-a-2"', kevSize: 1 });
    expect((await watchAdvisories({ ...env, GITHUB_TOKEN: 'x' }, brain, now + 10 * 60000, fetch, host)).skipped).toMatch(/less than an hour/);
    listing = [alert({ ghsa: 'GHSA-a' })];
    const s3 = await watchAdvisories({ ...env, GITHUB_TOKEN: 'x' }, brain, now + 61 * 60000, fetch, host);
    expect(s3.orgs[0]).toMatchObject({ resolved: 1 });
    const urgent = (await brain.state()).findings.recent.find((f) => f.title === 'lib GHSA-a (CVE-2026-1) critical');
    expect(urgent).toMatchObject({ lane: 'urgent' });
  });
  it('the KEV feed is cached for a day', async () => {
    const spy = vi.spyOn(globalThis, 'fetch').mockResolvedValue(Response.json({ vulnerabilities: [{ cveID: 'CVE-1' }, { cveID: 'CVE-2' }] }));
    await env.EVENTS.delete('kev:v1');
    const t = Date.UTC(2026, 10, 1);
    expect((await loadKev(env.EVENTS, t)).size).toBe(2);
    expect((await loadKev(env.EVENTS, t + 3600 * 1000)).size).toBe(2);
    expect(spy).toHaveBeenCalledTimes(1);
  });
  it('orgs come from the rendered OS_ORGS var; the placeholder means none', () => {
    expect(orgsFrom({ OS_ORGS: 'a b,c' })).toEqual(['a', 'b', 'c']);
    expect(orgsFrom({ OS_ORGS: '__OS_ORGS__' })).toEqual([]);
  });
});
