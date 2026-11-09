// F-06 tripwire: which Claude credential a hands process may hold, enforced before anything runs (fail closed, not just "delete the key").
//   container, api mode (the default): EXACTLY ONE key, ANTHROPIC_API_KEY, plus a configured spend-limit marker; no OAuth token, no
//     base-URL override, no Bedrock / Vertex / Foundry, no other vendor key.
//   container, max mode: exactly CLAUDE_CODE_OAUTH_TOKEN and no API key at all.
//   Mac runner ('login'): NO key of any kind (it uses Ahmad's own login); the hands key never exists on the Mac.
// A key anywhere bills the API in -p mode (documented precedence), so a stray one is a money bug, not a config detail.
/** Variables that change what Claude Code authenticates with or where it sends requests: refused everywhere. */
export const CLAUDE_FOREIGN_KEYS = ['ANTHROPIC_AUTH_TOKEN', 'ANTHROPIC_BASE_URL', 'ANTHROPIC_BEDROCK_BASE_URL', 'ANTHROPIC_VERTEX_BASE_URL', 'ANTHROPIC_VERTEX_PROJECT_ID', 'ANTHROPIC_FOUNDRY_API_KEY', 'ANTHROPIC_FOUNDRY_RESOURCE', 'CLAUDE_CODE_USE_BEDROCK', 'CLAUDE_CODE_USE_VERTEX', 'CLAUDE_CODE_USE_FOUNDRY', 'AWS_BEARER_TOKEN_BEDROCK', 'apiKeyHelper'];
/** Other vendors' keys: they never reach Claude, but the container holds none of them (refused there). On the Mac they may sit in
 *  OS_SERVICES_ENV for other scripts, so the runner drops them from every child's env instead of refusing to run (run-batch.mjs CRED_KEYS). */
export const OTHER_VENDOR_KEYS = ['OPENAI_API_KEY', 'GEMINI_API_KEY', 'GOOGLE_API_KEY'];
export const FOREIGN_KEYS = [...CLAUDE_FOREIGN_KEYS, ...OTHER_VENDOR_KEYS];

const set = (env, k) => typeof env[k] === 'string' && env[k].trim() !== '';

/** mode: 'api' | 'max' | 'login'. Returns a reason (refuse) or null (ok). */
export function billableKeyTripwire(env, mode) {
  const foreign = (mode === 'login' ? CLAUDE_FOREIGN_KEYS : FOREIGN_KEYS).filter((k) => set(env, k));
  if (foreign.length) return `billable or foreign credential variable(s) present: ${foreign.join(', ')}`;
  if (mode === 'api') {
    if (!set(env, 'ANTHROPIC_API_KEY')) return 'api mode needs ANTHROPIC_API_KEY';
    if (set(env, 'CLAUDE_CODE_OAUTH_TOKEN')) return 'api mode must not also hold an OAuth token (two credentials, unclear which bills)';
    if (!(Number(env.HANDS_API_SPEND_LIMIT_USD) > 0)) return 'api mode needs HANDS_API_SPEND_LIMIT_USD (the hard limit set in the Console); refusing an open tab';
    return null;
  }
  if (mode === 'max') {
    if (set(env, 'ANTHROPIC_API_KEY')) return 'max mode must not hold an API key';
    if (!set(env, 'CLAUDE_CODE_OAUTH_TOKEN')) return 'max mode needs CLAUDE_CODE_OAUTH_TOKEN';
    return null;
  }
  // login (the Mac): no key at all, the CLI uses the signed-in account
  for (const k of ['ANTHROPIC_API_KEY', 'CLAUDE_CODE_OAUTH_TOKEN']) if (set(env, k)) return `the Mac runner must not hold ${k} (it runs on Ahmad's own login; the hands key lives in the container only)`;
  return null;
}

/** The mode this process runs in: container -> HANDS_CLAUDE_AUTH (default api); anywhere else -> login. */
export function authModeOf(env, sandboxed) {
  if (!sandboxed) return 'login';
  return String(env.HANDS_CLAUDE_AUTH ?? 'api').toLowerCase() === 'max' ? 'max' : 'api';
}

/** What the `system/init` event's apiKeySource must say for a mode (UNCONFIRMED field on 2.1.309: only checked when present). */
export function expectedApiKeySource(mode) {
  return mode === 'api' ? 'ANTHROPIC_API_KEY' : 'none';
}
