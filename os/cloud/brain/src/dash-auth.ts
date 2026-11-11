// RR-dash-auth: who may see the dashboard (/dash/*, its JS and CSS) and call /api/*. Every human route goes through
// gateHuman() before anything is read or served.
//
//   1. Cloudflare Access configured (ACCESS_TEAM_DOMAIN + ACCESS_AUD rendered) -> the Access JWT is the ONLY way in.
//      Basic Auth is not consulted at all, whatever DASH_BASIC_AUTH says.
//   2. Access not configured, DASH_BASIC_AUTH != 'off' and the DASH_BASIC_PASSWORD secret set -> HTTP Basic Auth as
//      DASH_BASIC_USER (default `ahmad`). Credentials are compared as SHA-256 digests with crypto.subtle.timingSafeEqual
//      (no length or prefix leak). A request that CARRIES credentials goes through the BrainDO rate limiter
//      (dashAuthAttempt): 10 failures per IP or 200 overall in 15 minutes lock that IP (or everyone) out, and a locked
//      caller is refused even with the right password, so the lockout is not an oracle. A request with no credentials
//      never wakes the DO (anonymous scanners cost nothing).
//   3. Neither -> 503 (fail closed).
//
// Every refusal has an EMPTY body: no page, no script, no reason string an outsider could read.
import { verifyAccessJwt } from './access';
import { isPlaceholder, type Env } from './env';

export const DENY_HEADERS: Record<string, string> = {
  'cache-control': 'no-store',
  'x-robots-tag': 'noindex, nofollow',
  'x-content-type-options': 'nosniff',
  'referrer-policy': 'no-referrer',
};

export const BASIC_REALM = 'Basic realm="Ebda OS", charset="UTF-8"';

export type GateMode = 'access' | 'basic' | 'none';

export function gateMode(env: Pick<Env, 'ACCESS_TEAM_DOMAIN' | 'ACCESS_AUD' | 'DASH_BASIC_AUTH' | 'DASH_BASIC_PASSWORD'>): GateMode {
  if (!isPlaceholder(env.ACCESS_TEAM_DOMAIN) && !isPlaceholder(env.ACCESS_AUD)) return 'access';
  if (env.DASH_BASIC_AUTH !== 'off' && env.DASH_BASIC_PASSWORD) return 'basic';
  return 'none';
}

function deny(status: number, extra: Record<string, string> = {}): Response {
  return new Response(null, { status, headers: { ...DENY_HEADERS, ...extra } });
}

async function digest(s: string): Promise<ArrayBuffer> {
  return crypto.subtle.digest('SHA-256', new TextEncoder().encode(s));
}

/** Constant-time string equality on SHA-256 digests (equal length by construction, so nothing leaks through timing). */
export async function safeEqual(a: string, b: string): Promise<boolean> {
  const [x, y] = await Promise.all([digest(a), digest(b)]);
  return crypto.subtle.timingSafeEqual(x, y);
}

/** Parse `Authorization: Basic base64(user:pass)`; null when absent or malformed. */
export function parseBasic(h: string | null): { user: string; pass: string } | null {
  if (!h || !/^Basic [A-Za-z0-9+/=]{1,1024}$/.test(h)) return null;
  let raw: string;
  try {
    raw = new TextDecoder().decode(Uint8Array.from(atob(h.slice(6)), (c) => c.charCodeAt(0)));
  } catch {
    return null;
  }
  const i = raw.indexOf(':');
  return i < 0 ? null : { user: raw.slice(0, i), pass: raw.slice(i + 1) };
}

export interface RateLimiter {
  dashAuthAttempt(ip: string, ok: boolean, now?: number): Promise<boolean> | boolean;
}

/** null = allowed; a Response = refused (empty body). */
export async function gateHuman(request: Request, env: Env, limiter: () => RateLimiter, now: number = Date.now()): Promise<Response | null> {
  const mode = gateMode(env);
  if (mode === 'access') {
    const r = await verifyAccessJwt(request.headers.get('Cf-Access-Jwt-Assertion'), env.ACCESS_TEAM_DOMAIN, env.ACCESS_AUD, now);
    return r.ok ? null : deny(403);
  }
  if (mode === 'none') return deny(503);
  const header = request.headers.get('Authorization');
  if (!header) return deny(401, { 'www-authenticate': BASIC_REALM });
  const creds = parseBasic(header);
  const user = env.DASH_BASIC_USER || 'ahmad';
  // both compares always run, so a wrong user and a wrong password take the same time
  const [userOk, passOk] = await Promise.all([safeEqual(creds?.user ?? '', user), safeEqual(creds?.pass ?? '', env.DASH_BASIC_PASSWORD!)]);
  const ok = creds !== null && userOk && passOk;
  const ip = request.headers.get('CF-Connecting-IP') ?? 'unknown';
  const allowed = await limiter().dashAuthAttempt(ip, ok, now);
  if (allowed) return null;
  return ok ? deny(429, { 'retry-after': '900' }) : deny(401, { 'www-authenticate': BASIC_REALM });
}

/** Security headers on every dashboard asset served after the gate (the _headers file is kept as a second copy). */
export const DASH_HEADERS: Record<string, string> = {
  'content-security-policy': "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; font-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
  'x-content-type-options': 'nosniff',
  'referrer-policy': 'no-referrer',
  'strict-transport-security': 'max-age=31536000; includeSubDomains',
  'x-robots-tag': 'noindex, nofollow',
  'cache-control': 'private, no-cache',
};
