import { afterEach, describe, expect, it } from 'vitest';
import { resetAccessCache, verifyAccessJwt } from '../src/access';

const b64url = (b: Uint8Array | string) => btoa(typeof b === 'string' ? b : String.fromCharCode(...b)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

async function setup() {
  const kp = (await crypto.subtle.generateKey({ name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' }, true, ['sign', 'verify'])) as CryptoKeyPair;
  const pub = (await crypto.subtle.exportKey('jwk', kp.publicKey)) as JsonWebKey;
  const certs = (async () => Response.json({ keys: [{ ...pub, kid: 'k1' }] })) as unknown as typeof fetch;
  const sign = async (claims: object, kid = 'k1') => {
    const h = b64url(JSON.stringify({ alg: 'RS256', kid }));
    const c = b64url(JSON.stringify(claims));
    const sig = new Uint8Array(await crypto.subtle.sign('RSASSA-PKCS1-v1_5', kp.privateKey, new TextEncoder().encode(`${h}.${c}`)));
    return `${h}.${c}.${b64url(sig)}`;
  };
  return { certs, sign };
}

const TEAM = 'team.cloudflareaccess.com';
const now = Date.UTC(2026, 10, 5);
const good = { aud: ['aud-1'], iss: `https://${TEAM}`, exp: now / 1000 + 600, email: 'a@b.c' };

afterEach(() => resetAccessCache());

describe('Cloudflare Access JWT', () => {
  it('accepts a valid token and rejects wrong aud / iss / expiry / kid / tampering', async () => {
    const { certs, sign } = await setup();
    expect(await verifyAccessJwt(await sign(good), TEAM, 'aud-1', now, certs)).toMatchObject({ ok: true, email: 'a@b.c' });
    expect((await verifyAccessJwt(await sign({ ...good, aud: 'other' }), TEAM, 'aud-1', now, certs)).reason).toBe('wrong aud');
    expect((await verifyAccessJwt(await sign({ ...good, iss: 'https://evil' }), TEAM, 'aud-1', now, certs)).reason).toBe('wrong iss');
    expect((await verifyAccessJwt(await sign({ ...good, exp: now / 1000 - 1 }), TEAM, 'aud-1', now, certs)).reason).toBe('expired');
    expect((await verifyAccessJwt(await sign(good, 'k9'), TEAM, 'aud-1', now, certs)).reason).toBe('unknown kid');
    const t = await sign(good);
    const forged = `${t.split('.')[0]}.${b64url(JSON.stringify({ ...good, email: 'x@y.z' }))}.${t.split('.')[2]}`;
    expect((await verifyAccessJwt(forged, TEAM, 'aud-1', now, certs)).reason).toBe('bad signature');
  });
  it('fails closed when unconfigured or the header is missing', async () => {
    const { certs } = await setup();
    expect((await verifyAccessJwt('x.y.z', '__ACCESS_TEAM_DOMAIN__', 'aud', now, certs)).reason).toBe('access not configured');
    expect((await verifyAccessJwt(null, TEAM, 'aud-1', now, certs)).reason).toMatch(/missing/);
  });
});
