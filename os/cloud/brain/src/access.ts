// Cloudflare Access check for the dashboard API. Access sits in front of /dash and /api at the edge; the Worker
// verifies the Cf-Access-Jwt-Assertion itself as well (RS256 against the team's certs, aud, iss, exp), so a request
// that bypassed the edge (e.g. a misconfigured route) is still refused. Unconfigured = refused (fail closed).
import { isPlaceholder } from './env';
import { boundFetch } from './bound-fetch';

interface Jwk extends JsonWebKey {
  kid?: string;
}
let jwksCache: { domain: string; at: number; keys: Jwk[] } | null = null;

function b64urlDecode(s: string): Uint8Array {
  const b = atob(s.replace(/-/g, '+').replace(/_/g, '/') + '='.repeat((4 - (s.length % 4)) % 4));
  return Uint8Array.from(b, (c) => c.charCodeAt(0));
}

export function resetAccessCache(): void {
  jwksCache = null;
}

export async function verifyAccessJwt(token: string | null, teamDomain: string, aud: string, now: number, fetchImpl: typeof fetch = boundFetch): Promise<{ ok: boolean; reason?: string; email?: string }> {
  if (isPlaceholder(teamDomain) || isPlaceholder(aud)) return { ok: false, reason: 'access not configured' };
  if (!token) return { ok: false, reason: 'missing Cf-Access-Jwt-Assertion' };
  const parts = token.split('.');
  if (parts.length !== 3) return { ok: false, reason: 'malformed jwt' };
  let header: { alg?: string; kid?: string };
  let claims: { aud?: string | string[]; iss?: string; exp?: number; nbf?: number; email?: string };
  try {
    header = JSON.parse(new TextDecoder().decode(b64urlDecode(parts[0]!)));
    claims = JSON.parse(new TextDecoder().decode(b64urlDecode(parts[1]!)));
  } catch {
    return { ok: false, reason: 'malformed jwt' };
  }
  if (header.alg !== 'RS256') return { ok: false, reason: 'unexpected alg' };
  if (!jwksCache || jwksCache.domain !== teamDomain || now - jwksCache.at > 3600 * 1000) {
    const r = await fetchImpl(`https://${teamDomain}/cdn-cgi/access/certs`);
    if (!r.ok) return { ok: false, reason: `certs HTTP ${r.status}` };
    jwksCache = { domain: teamDomain, at: now, keys: ((await r.json()) as { keys: Jwk[] }).keys ?? [] };
  }
  const jwk = jwksCache.keys.find((k) => k.kid === header.kid);
  if (!jwk) return { ok: false, reason: 'unknown kid' };
  const key = await crypto.subtle.importKey('jwk', jwk, { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['verify']);
  const valid = await crypto.subtle.verify('RSASSA-PKCS1-v1_5', key, b64urlDecode(parts[2]!), new TextEncoder().encode(`${parts[0]}.${parts[1]}`));
  if (!valid) return { ok: false, reason: 'bad signature' };
  const audOk = Array.isArray(claims.aud) ? claims.aud.includes(aud) : claims.aud === aud;
  if (!audOk) return { ok: false, reason: 'wrong aud' };
  if (claims.iss !== `https://${teamDomain}`) return { ok: false, reason: 'wrong iss' };
  const sec = Math.floor(now / 1000);
  if (typeof claims.exp !== 'number' || claims.exp <= sec) return { ok: false, reason: 'expired' };
  if (typeof claims.nbf === 'number' && claims.nbf > sec + 60) return { ok: false, reason: 'not yet valid' };
  return { ok: true, ...(claims.email ? { email: claims.email } : {}) };
}
