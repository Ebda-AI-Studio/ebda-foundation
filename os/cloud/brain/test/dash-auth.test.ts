// RR-dash-auth: the dashboard (HTML, JS, CSS) and /api/* are never served to an unauthenticated caller.
import { env } from 'cloudflare:workers';
import { createExecutionContext, SELF, waitOnExecutionContext } from 'cloudflare:test';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { resetAccessCache } from '../src/access';
import { gateMode, parseBasic, safeEqual } from '../src/dash-auth';
import type { Env } from '../src/env';
import worker from '../src/index';

const PW = 'correct-horse-battery-staple-test';
const basic = (user: string, pass: string) => `Basic ${btoa(`${user}:${pass}`)}`;
const withBasic = (extra: Partial<Env> = {}) => ({ ...env, DASH_BASIC_PASSWORD: PW, ...extra }) as Env;

async function call(e: Env, path: string, headers: Record<string, string> = {}, init: RequestInit = {}): Promise<Response> {
  const ctx = createExecutionContext();
  const r = await worker.fetch(new Request(`https://brain.test${path}`, { ...init, headers }) as any, e, ctx);
  await waitOnExecutionContext(ctx);
  return r;
}

afterEach(() => {
  vi.restoreAllMocks();
  resetAccessCache();
});

describe('dashboard gate: nothing configured (the test env has no password and no Access) fails closed', () => {
  it('every human path answers 503 with an empty body; /health stays public', async () => {
    for (const p of ['/dash/', '/dash/index.html', '/dash/dash.js', '/dash/dash.css', '/api/state']) {
      const r = await SELF.fetch(`https://brain.test${p}`);
      expect(r.status, p).toBe(503);
      expect(await r.text(), p).toBe('');
      expect(r.headers.get('x-robots-tag')).toBe('noindex, nofollow');
    }
    // a percent-encoded spelling of the dashboard never reaches the asset router
    const enc = await SELF.fetch('https://brain.test/%64ash/index.html');
    expect(enc.status).not.toBe(200);
    expect(await enc.text()).not.toContain('<html');
    const h = await SELF.fetch('https://brain.test/health');
    expect(h.status).toBe(200);
    // the test env carries the template placeholder, not a sha: reads 'unknown'
    expect(await h.json()).toEqual({ ok: true, service: 'ebda-os-brain', commit: 'unknown' });
  });
});

describe('/health carries the deploy commit (the verify-against-production rule: "is it deployed?" is answered by the running Worker)', () => {
  const sha = '0123456789abcdef0123456789abcdef01234567';
  it('returns a stamped sha, and +dirty when the tree had uncommitted tracked changes', async () => {
    expect(await (await call({ ...env, GIT_COMMIT: sha } as Env, '/health')).json()).toEqual({ ok: true, service: 'ebda-os-brain', commit: sha });
    expect(((await (await call({ ...env, GIT_COMMIT: `${sha}+dirty` } as Env, '/health')).json()) as { commit: string }).commit).toBe(`${sha}+dirty`);
  });
  it('anything that is not a sha (the template placeholder, an unset var, junk) reads unknown', async () => {
    for (const v of [undefined, '', '__GIT_COMMIT__', 'main', `${sha}; drop`]) {
      expect(((await (await call({ ...env, GIT_COMMIT: v } as Env, '/health')).json()) as { commit: string }).commit, String(v)).toBe('unknown');
    }
  });
});

describe('dashboard gate: interim Basic Auth', () => {
  it('unauthenticated /dash/, /dash/dash.js, /dash/dash.css and /api/state are 401 with no content and a Basic challenge', async () => {
    for (const p of ['/dash/', '/dash/dash.js', '/dash/dash.css', '/api/state', '/dash']) {
      const r = await call(withBasic(), p);
      expect(r.status, p).toBe(401);
      expect(await r.text(), p).toBe('');
      expect(r.headers.get('www-authenticate')).toMatch(/^Basic realm="Ebda OS"/);
      expect(r.headers.get('x-robots-tag')).toBe('noindex, nofollow');
    }
  });

  it('wrong user, wrong password or a malformed header are 401 with no content', async () => {
    for (const h of [basic('ahmad', 'nope'), basic('root', PW), 'Basic !!!', 'Bearer x', basic('ahmad', '')]) {
      const r = await call(withBasic(), '/dash/', { Authorization: h, 'CF-Connecting-IP': '198.51.100.1' });
      expect(r.status, h).toBe(401);
      expect(await r.text()).toBe('');
    }
  });

  it('the right credentials get the dashboard, its JS and CSS (with the CSP and noindex) and the API', async () => {
    const auth = { Authorization: basic('ahmad', PW), 'CF-Connecting-IP': '198.51.100.2' };
    const page = await call(withBasic(), '/dash/', auth);
    expect(page.status).toBe(200);
    expect(await page.text()).toContain('<html');
    expect(page.headers.get('content-security-policy')).toContain("script-src 'self'");
    expect(page.headers.get('x-robots-tag')).toBe('noindex, nofollow');
    for (const p of ['/dash/dash.js', '/dash/dash.css']) expect((await call(withBasic(), p, auth)).status, p).toBe(200);
    const api = await call(withBasic(), '/api/state', auth);
    expect(api.status).toBe(200);
    expect(await api.json()).toHaveProperty('findings');
    expect((await call(withBasic(), '/dash', auth)).headers.get('location')).toBe('https://brain.test/dash/');
  });

  it('rate limits failures per IP: once locked, even the right password is refused (no oracle); other IPs are unaffected', async () => {
    // the limiter lives in the BrainDO and reads ITS env (the deployed default, 10 failures per IP in 15 minutes)
    const e = withBasic();
    const ip = '203.0.113.9';
    for (let i = 0; i < 10; i++) expect((await call(e, '/dash/', { Authorization: basic('ahmad', `bad${i}`), 'CF-Connecting-IP': ip })).status).toBe(401);
    const locked = await call(e, '/dash/', { Authorization: basic('ahmad', PW), 'CF-Connecting-IP': ip });
    expect(locked.status).toBe(429);
    expect(await locked.text()).toBe('');
    expect((await call(e, '/dash/', { Authorization: basic('ahmad', PW), 'CF-Connecting-IP': '203.0.113.10' })).status).toBe(200);
  });

  it('DASH_BASIC_AUTH=off with no Access fails closed (503)', async () => {
    expect((await call(withBasic({ DASH_BASIC_AUTH: 'off' }), '/dash/', { Authorization: basic('ahmad', PW) })).status).toBe(503);
  });
});

describe('dashboard gate: Cloudflare Access wins once configured', () => {
  const b64url = (b: Uint8Array | string) => btoa(typeof b === 'string' ? b : String.fromCharCode(...b)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

  it('Basic credentials are ignored; only a valid Access JWT gets in', async () => {
    const kp = (await crypto.subtle.generateKey({ name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' }, true, ['sign', 'verify'])) as CryptoKeyPair;
    const pub = (await crypto.subtle.exportKey('jwk', kp.publicKey)) as JsonWebKey;
    vi.spyOn(globalThis, 'fetch').mockImplementation(async () => Response.json({ keys: [{ ...pub, kid: 'k1' }] }));
    const team = 'team.cloudflareaccess.com';
    const h = b64url(JSON.stringify({ alg: 'RS256', kid: 'k1' }));
    const c = b64url(JSON.stringify({ aud: ['aud-1'], iss: `https://${team}`, exp: Math.floor(Date.now() / 1000) + 600 }));
    const sig = new Uint8Array(await crypto.subtle.sign('RSASSA-PKCS1-v1_5', kp.privateKey, new TextEncoder().encode(`${h}.${c}`)));
    const e = withBasic({ ACCESS_TEAM_DOMAIN: team, ACCESS_AUD: 'aud-1' });
    expect(gateMode(e)).toBe('access');
    const viaBasic = await call(e, '/dash/', { Authorization: basic('ahmad', PW) });
    expect(viaBasic.status).toBe(403);
    expect(await viaBasic.text()).toBe('');
    expect((await call(e, '/dash/dash.js', { 'Cf-Access-Jwt-Assertion': `${h}.${c}.${b64url(sig)}` })).status).toBe(200);
    expect((await call(e, '/api/state', { 'Cf-Access-Jwt-Assertion': `${h}.${c}.${b64url(sig)}` })).status).toBe(200);
  });
});

describe('helpers', () => {
  it('parseBasic and safeEqual', async () => {
    expect(parseBasic(basic('ahmad', 'a:b'))).toEqual({ user: 'ahmad', pass: 'a:b' });
    expect(parseBasic('Basic ' + btoa('nocolon'))).toBeNull();
    expect(parseBasic(null)).toBeNull();
    expect(await safeEqual('abc', 'abc')).toBe(true);
    expect(await safeEqual('abc', 'abcd')).toBe(false);
  });
});
