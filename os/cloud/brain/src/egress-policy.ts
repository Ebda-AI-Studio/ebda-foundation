// F-16 / F-03: the platform-side egress policy of the hands container, as pure functions so the same rules are unit-tested and can be
// applied at either layer: Cloudflare's outbound interception for the Container (`outboundByHost`, where even root in the container cannot
// bypass it; UNCONFIRMED on our account, ruling RR-platform-egress) or the local forwarder inside the container (os/cloud/hands/lib/egress.mjs).
// The host list is deliberately short; api.anthropic.com is reachable only through a request-level check (path + credential).
export const PLATFORM_ALLOWED_HOSTS = ['github.com', 'api.github.com', 'codeload.github.com', 'objects.githubusercontent.com', 'registry.npmjs.org', 'api.anthropic.com'] as const;

export function hostAllowed(host: string, brainHost?: string): boolean {
  const h = host.toLowerCase().replace(/\.$/, '');
  return (PLATFORM_ALLOWED_HOSTS as readonly string[]).includes(h) || (!!brainHost && h === brainHost.toLowerCase());
}

/** The only Anthropic endpoints Claude Code needs headless: POST /v1/messages and POST /v1/messages/count_tokens. Never /v1/files*. */
const ANTHROPIC_PATHS = new Set(['/v1/messages', '/v1/messages/count_tokens']);

export interface AnthropicCheck {
  allowed: boolean;
  reason?: string;
}

/**
 * A request to api.anthropic.com from the container. `credential` is the ONE credential the run was given (api mode: the Console key;
 * max mode: the OAuth token). Anything carrying a different key, or a path outside the messages API, is refused: an injected prompt that
 * tries to upload the repo through the Files API with the attacker's own key dies here.
 */
export function checkAnthropicRequest(method: string, url: string, headers: Record<string, string | undefined>, credential: { mode: 'api' | 'max'; secret: string }): AnthropicCheck {
  const u = new URL(url);
  if (u.hostname !== 'api.anthropic.com') return { allowed: false, reason: 'not the model API host' };
  if (method.toUpperCase() !== 'POST') return { allowed: false, reason: 'only POST reaches the model API' };
  if (!ANTHROPIC_PATHS.has(u.pathname)) return { allowed: false, reason: `path ${u.pathname} is not allowed (messages only)` };
  const lower = Object.fromEntries(Object.entries(headers).map(([k, v]) => [k.toLowerCase(), v]));
  const apiKey = lower['x-api-key'];
  const auth = lower['authorization'];
  if (credential.mode === 'api') {
    if (auth) return { allowed: false, reason: 'an Authorization credential is not ours in api mode' };
    if (apiKey !== credential.secret) return { allowed: false, reason: 'x-api-key is not the configured hands key' };
  } else {
    if (apiKey) return { allowed: false, reason: 'an API key is not allowed in max mode' };
    if (auth !== `Bearer ${credential.secret}`) return { allowed: false, reason: 'authorization is not the configured OAuth token' };
  }
  return { allowed: true };
}
