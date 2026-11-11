import { describe, expect, it } from 'vitest';
import { checkBearerAuth, mapEvent, signEvent, timingSafeEqualStr, verifyGitHubSig } from '../src/relay';

// Cross-impl HMAC parity vector, computed independently with python (see src/relay.ts). The Mac listener depends on it.
const PY_EXPECTED_HEX = '58547be63654fa17a2edde1cc8eb7939c5e670b19b4ddc48e55af72df26d336c';

async function ghSig(body: string, secret: string): Promise<string> {
  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const mac = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(body));
  return `sha256=${[...new Uint8Array(mac)].map((b) => b.toString(16).padStart(2, '0')).join('')}`;
}

describe('relay contract (ported, unchanged)', () => {
  it('signEvent matches the python HMAC fixed vector', async () => {
    expect(await signEvent('e1', 'ci-failure', 1000, { slug: 'o/r', sha: 's1' }, 's3cr3t')).toBe(PY_EXPECTED_HEX);
  });
  it('signEvent changes with any field', async () => {
    const a = await signEvent('e1', 'ci-failure', 1000, { slug: 'o/r', sha: 's1' }, 's3cr3t');
    expect(await signEvent('e1', 'ci-failure', 1001, { slug: 'o/r', sha: 's1' }, 's3cr3t')).not.toBe(a);
    expect(await signEvent('e1', 'ci-failure', 1000, { sha: 's1', slug: 'o/r' }, 's3cr3t')).not.toBe(a); // key order is significant
  });
  it('verifyGitHubSig accepts the right signature and rejects wrong, missing, malformed, unset secret', async () => {
    const body = JSON.stringify({ hello: 'world' });
    const good = await ghSig(body, 'gh-secret');
    expect(await verifyGitHubSig(body, good, 'gh-secret')).toBe(true);
    expect(await verifyGitHubSig(body, `sha256=${'0'.repeat(64)}`, 'gh-secret')).toBe(false);
    expect(await verifyGitHubSig(body, undefined, 'gh-secret')).toBe(false);
    expect(await verifyGitHubSig(body, 'sha256=zz', 'gh-secret')).toBe(false);
    expect(await verifyGitHubSig(body, good, undefined)).toBe(false);
  });
  it('mapEvent maps only failed workflow_run', () => {
    const p = { repository: { full_name: 'o/r' }, workflow_run: { conclusion: 'failure', head_sha: 's1' } };
    expect(mapEvent('workflow_run', p)).toEqual({ kind: 'ci-failure', target: { slug: 'o/r', sha: 's1' } });
    expect(mapEvent('workflow_run', { ...p, workflow_run: { conclusion: 'success', head_sha: 's1' } })).toBeNull();
    expect(mapEvent('push', p)).toBeNull();
  });
  it('timingSafeEqualStr and checkBearerAuth', () => {
    expect(timingSafeEqualStr('abc', 'abc')).toBe(true);
    expect(timingSafeEqualStr('abc', 'abd')).toBe(false);
    expect(timingSafeEqualStr('abc', 'ab')).toBe(false);
    const req = (h?: string) => new Request('https://x/pending', h ? { headers: { Authorization: h } } : {});
    expect(checkBearerAuth(req('Bearer s'), 's')).toBe(true);
    expect(checkBearerAuth(req('Bearer t'), 's')).toBe(false);
    expect(checkBearerAuth(req('s'), 's')).toBe(false);
    expect(checkBearerAuth(req(), 's')).toBe(false);
    expect(checkBearerAuth(req('Bearer '), undefined)).toBe(false); // unset secret never authenticates
  });
});
