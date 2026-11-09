// Final whole-branch review fixes on the hands side: C-1, I-8, I-9, M-1 (see job/policy tests), M-5.
import net from 'node:net';
import { describe, expect, it } from 'vitest';
import { recordingBrain } from '../lib/brain-client.mjs';
import { diffAllowsAutoMerge, lockfileHostsOk, packageJsonBumpOnly, PROTECTED } from '../lib/diffcheck.mjs';
import { createServer } from 'node:http';
import { claudeAllowList, hostAllowed, proxyEnv, startProxy, startRegistryMirror, testsEnv } from '../lib/egress.mjs';
import { asSandbox } from '../lib/git.mjs';
import { runBatch } from '../lib/run.mjs';
import { UsageGuard } from '../lib/usage-guard.mjs';

const w = (path, buf = 'x', base = null) => ({ path, type: 'write', buf: Buffer.from(buf), base: base === null ? null : Buffer.from(base) });
const pj = (deps, extra = {}) => JSON.stringify({ scripts: { test: 'vitest' }, dependencies: deps, ...extra });

describe('C-1: the hands report the usage that made them refuse', () => {
  it('usage guard refuses at 96%: the reading reaches the brain BEFORE the run stops, and the job is reported skipped_usage', async () => {
    const nowS = Date.now() / 1000;
    const ev = { type: 'rate_limit_event', rate_limit_info: { unifiedWindows: { seven_day: { utilization: 0.96, resetsAt: nowS + 86400 } } } };
    const usage = new UsageGuard({ thresholdPct: 80, probe: async () => [ev], nowS: () => Date.now() / 1000 });
    const batch = { runId: 'run_c1', kind: 'urgent', perJobCapMin: 30, usageThresholdPct: 80, jobs: [{ id: 'job_1', finding: { kind: 'prod-outage', repo: 'o/r' } }] };
    const brain = recordingBrain(batch);
    const res = await runBatch(batch, { brain, cfg: { runCapMin: 90, repos: {} }, exec: async () => ({ code: 0, stdout: '', stderr: '' }), usage, env: {} });
    expect(res[0]).toMatchObject({ status: 'skipped_usage', note: expect.stringMatching(/96%/) });
    expect(brain.usageReports[0]).toMatchObject({ weeklyUsedPct: 96 });
  });
});

describe('I-8 (ruling F-I8): egress allowlist + uid split', () => {
  it('Claude\'s proxy allows the model API (and the extras) and NOTHING else: no GitHub, no registry', () => {
    const allow = claudeAllowList('brain.example.workers.dev');
    for (const h of ['api.anthropic.com', 'brain.example.workers.dev']) expect(hostAllowed(h, allow)).toBe(true);
    for (const h of ['github.com', 'api.github.com', 'gist.github.com', 'codeload.github.com', 'registry.npmjs.org', 'evil.example', 'api.anthropic.com.evil.example', '']) expect(hostAllowed(h, allow)).toBe(false);
  });
  it('the proxy answers 403 to a CONNECT for an unlisted host and records it; an allowed host is tunnelled', async () => {
    const upstream = net.createServer((s) => s.end('UPSTREAM')).listen(0, '127.0.0.1');
    await new Promise((r) => upstream.once('listening', r));
    const p = await startProxy({ allow: ['127.0.0.1'] });
    const connect = (target) =>
      new Promise((resolve) => {
        const s = net.connect(p.port, '127.0.0.1', () => s.write(`CONNECT ${target} HTTP/1.1\r\nHost: ${target}\r\n\r\n`));
        let buf = '';
        s.on('data', (d) => (buf += d));
        s.on('close', () => resolve(buf));
        setTimeout(() => s.destroy(), 500);
      });
    expect(await connect('evil.example:443')).toMatch(/^HTTP\/1.1 403/);
    expect([...p.denied]).toContain('evil.example:443');
    // port other than 443 is refused even for an allowed host
    expect(await connect(`127.0.0.1:${upstream.address().port}`)).toMatch(/^HTTP\/1.1 403/);
    await p.close();
    upstream.close();
  });
  it('the proxy env points a child at the proxy', () => {
    expect(proxyEnv(1234)).toMatchObject({ HTTPS_PROXY: 'http://127.0.0.1:1234', NO_PROXY: '127.0.0.1,localhost' });
  });
  it('Claude and the repo tests run as DIFFERENT uids', () => {
    const cfg = { sandboxUser: 'node', testUser: 'tester' };
    expect(asSandbox(cfg, 'claude', ['-p'], 'claude')[1].slice(0, 2)).toEqual(['--reuid', 'node']);
    expect(asSandbox(cfg, 'npm', ['test'], 'tests')[1].slice(0, 2)).toEqual(['--reuid', 'tester']);
  });
});

describe('RR-egress-roles: the tests role has no CONNECT target and only a read-only registry', () => {
  async function upstream() {
    const seen = [];
    const server = createServer((req, res) => (seen.push(`${req.method} ${req.url} auth=${req.headers.authorization ?? '-'}`), res.writeHead(200, { 'content-type': 'application/json' }).end('{"name":"x"}')));
    await new Promise((r) => server.listen(0, '127.0.0.1', r));
    return { seen, port: server.address().port, close: () => new Promise((r) => server.close(r)) };
  }
  const call = (port, method, path, headers = {}) => fetch(`http://127.0.0.1:${port}${path}`, { method, headers, body: ['GET', 'HEAD'].includes(method) ? undefined : 'x' });

  it('GET and HEAD are forwarded (credentials stripped); publish, dist-tag and unpublish are 405 and never reach the registry', async () => {
    const up = await upstream();
    const m = await startRegistryMirror({ upstream: { host: '127.0.0.1', port: up.port, tls: false } });
    expect((await call(m.port, 'GET', '/left-pad', { authorization: 'Bearer attacker-npm-token' })).status).toBe(200);
    expect((await call(m.port, 'HEAD', '/left-pad')).status).toBe(200);
    for (const [method, path] of [['PUT', '/evil-pkg'], ['PUT', '/-/package/x/dist-tags/latest'], ['DELETE', '/evil-pkg/-rev/1'], ['POST', '/-/v1/login']]) expect((await call(m.port, method, path)).status).toBe(405);
    expect(up.seen).toEqual(['GET /left-pad auth=-', 'HEAD /left-pad auth=-']);
    expect([...m.denied].sort()).toEqual(['DELETE /evil-pkg/-rev/1', 'POST /-/v1/login', 'PUT /-/package/x/dist-tags/latest', 'PUT /evil-pkg']);
    await m.close();
    await up.close();
  });
  it('a proxy with an empty allowlist refuses every CONNECT (the tests role: no gist, no files upload, no publish tunnel)', async () => {
    const p = await startProxy({ allow: [] });
    const status = await new Promise((resolve) => {
      const s = net.connect(p.port, '127.0.0.1', () => s.write('CONNECT api.github.com:443 HTTP/1.1\r\nHost: api.github.com:443\r\n\r\n'));
      let buf = '';
      s.on('data', (d) => (buf += d));
      s.on('close', () => resolve(buf.slice(0, 12)));
      setTimeout(() => s.destroy(), 500);
    });
    expect(status).toBe('HTTP/1.1 403');
    await p.close();
  });
  it('testsEnv points npm at the mirror and the proxy at the empty-allowlist proxy', () => {
    expect(testsEnv(1111, 2222)).toMatchObject({ HTTPS_PROXY: 'http://127.0.0.1:1111', npm_config_registry: 'http://127.0.0.1:2222/' });
  });
});

describe('I-9: dependency fixes are bumps, not new packages or URL specs', () => {
  const base = pj({ a: '^1.0.0' });
  it('accepts a version bump of an existing dependency', () => {
    expect(diffAllowsAutoMerge('dependency-advisory', [w('package.json', pj({ a: '^1.2.0' }), base), w('package-lock.json')], [], { pkg: 'a' }).ok).toBe(true);
  });
  it('refuses a NEW package, a URL spec, a git spec and a removal', () => {
    for (const next of [pj({ a: '^1.0.0', evil: '1.0.0' }), pj({ a: 'https://evil.example/a.tgz' }), pj({ a: 'git+https://github.com/x/y.git' }), pj({})]) {
      const r = diffAllowsAutoMerge('dependency-advisory', [w('package.json', next, base)], [], { pkg: 'a' });
      expect(r.ok).toBe(false);
    }
  });
  it('allows an overrides entry only for the advisory own package', () => {
    expect(packageJsonBumpOnly(base, pj({ a: '^1.0.0' }, { overrides: { lodash: '4.17.21' } }), 'lodash')).toBe(true);
    expect(packageJsonBumpOnly(base, pj({ a: '^1.0.0' }, { overrides: { other: '1.0.0' } }), 'lodash')).toBe(false);
  });
  it('refuses a lockfile that resolves from a foreign host', () => {
    const ok = '{"packages":{"node_modules/a":{"resolved":"https://registry.npmjs.org/a/-/a-1.2.0.tgz"}}}';
    const bad = '{"packages":{"node_modules/a":{"resolved":"https://evil.example/a-1.2.0.tgz"}}}';
    expect(lockfileHostsOk(ok)).toBe(true);
    expect(lockfileHostsOk(bad)).toBe(false);
    expect(diffAllowsAutoMerge('dep-bump', [w('package-lock.json', bad)]).ok).toBe(false);
    expect(diffAllowsAutoMerge('dep-bump', [w('package-lock.json', ok)]).ok).toBe(true);
  });
});

describe('M-5: docs allowlist is markdown only; .changeset is protected', () => {
  it('docs build code and changesets never auto-merge', () => {
    expect(diffAllowsAutoMerge('docs', [w('docs/.vitepress/config.ts')]).ok).toBe(false);
    expect(diffAllowsAutoMerge('docs', [w('.changeset/brave-lions.md')]).ok).toBe(false);
    expect(PROTECTED.test('.changeset/x.md')).toBe(true);
    expect(diffAllowsAutoMerge('docs', [w('docs/guide/setup.md'), w('README.md')]).ok).toBe(true);
  });
});
