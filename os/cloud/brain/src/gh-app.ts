// F-12: GitHub App installation tokens for the hands. The brain mints one per run per owner: 1 h TTL, narrowed to the repositories of
// the run's jobs, contents + pull_requests write only (never workflows, never admin). Replaces the standing 90-day PAT, which stays only
// as the fallback (ruling RR-gh-token). GH_APP_PRIVATE_KEY must be PKCS#8 PEM (openssl pkcs8 -topk8 -nocrypt -in app.pem).
import type { Env } from './env';
import { isPlaceholder } from './env';

const enc = new TextEncoder();
const b64url = (b: ArrayBuffer | Uint8Array | string) => {
  const bytes = typeof b === 'string' ? enc.encode(b) : new Uint8Array(b);
  let s = '';
  for (const x of bytes) s += String.fromCharCode(x);
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
};

export function appConfigured(env: Partial<Env>): boolean {
  return !isPlaceholder(env.GH_APP_ID) && !isPlaceholder(env.GH_APP_PRIVATE_KEY) && !isPlaceholder(env.GH_APP_INSTALLATIONS);
}

async function appJwt(appId: string, pem: string, now: number): Promise<string> {
  const der = Uint8Array.from(atob(pem.replace(/-----[^-]+-----/g, '').replace(/\s+/g, '')), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey('pkcs8', der, { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['sign']);
  const head = b64url(JSON.stringify({ alg: 'RS256', typ: 'JWT' }));
  const body = b64url(JSON.stringify({ iat: Math.floor(now / 1000) - 60, exp: Math.floor(now / 1000) + 540, iss: appId }));
  const sig = await crypto.subtle.sign('RSASSA-PKCS1-v1_5', key, enc.encode(`${head}.${body}`));
  return `${head}.${body}.${b64url(sig)}`;
}

/** Tokens by owner for the given owner/name repos. Throws on any failure (the caller refuses the start: never falls back silently). */
export async function mintInstallationTokens(env: Partial<Env>, repos: string[], fetchImpl: typeof fetch = fetch, now: number = Date.now()): Promise<Record<string, string>> {
  const installs = JSON.parse(String(env.GH_APP_INSTALLATIONS)) as Record<string, number>;
  const byOwner = new Map<string, string[]>();
  for (const r of repos) {
    const [owner, name] = r.split('/');
    if (!owner || !name) continue;
    byOwner.set(owner, [...(byOwner.get(owner) ?? []), name]);
  }
  const jwt = await appJwt(String(env.GH_APP_ID), String(env.GH_APP_PRIVATE_KEY), now);
  const out: Record<string, string> = {};
  for (const [owner, names] of byOwner) {
    const id = installs[owner];
    if (!id) throw new Error(`GitHub App is not installed for owner ${owner}`);
    const res = await fetchImpl(`https://api.github.com/app/installations/${id}/access_tokens`, {
      method: 'POST',
      headers: { authorization: `Bearer ${jwt}`, accept: 'application/vnd.github+json', 'x-github-api-version': '2022-11-28', 'user-agent': 'ebda-os-brain' },
      body: JSON.stringify({ repositories: [...new Set(names)], permissions: { contents: 'write', pull_requests: 'write' } }),
    });
    if (!res.ok) throw new Error(`installation token for ${owner}: HTTP ${res.status}`);
    const j = (await res.json()) as { token?: string };
    if (!j.token) throw new Error(`installation token for ${owner}: no token in the answer`);
    out[owner] = j.token;
  }
  return out;
}
