// Provider selection by config (HANDS_PROVIDER on the brain Worker). Returns { provider, reason }; provider null means
// "use the stub" (records only, starts nothing). A typo, or a provider that is not fully configured, never starts an
// unexpected runner. github-actions is selectable ONLY when explicitly enabled and configured (Actions = CI only).
// Worker-compatible ESM: no node: imports (the brain bundles this file).
import { createCloudflareSandboxProvider, DEFAULT_NIGHTLY_RUN_CAP_MIN, NAME as CF } from './cloudflare-sandbox.mjs';
import { createGithubActionsProvider, githubActionsConfigured, NAME as GHA } from './github-actions.mjs';
import { createMacLocalProvider, NAME as MAC } from './mac-local.mjs';

export const PROVIDER_NAMES = [CF, MAC, GHA];

function intOr(v, d) {
  const n = Number.parseInt(String(v ?? ''), 10);
  return Number.isFinite(n) && n > 0 ? n : d;
}

export function selectProvider(name, env = {}) {
  switch (name) {
    case CF:
      // a missing binding still selects the provider: its start() throws and the brain records a failed run (loud)
      return { provider: createCloudflareSandboxProvider({ namespace: env.HANDS_CONTAINER, nightlyRunCapMin: intOr(env.HANDS_NIGHTLY_RUN_CAP_MIN, DEFAULT_NIGHTLY_RUN_CAP_MIN) }), reason: 'cloudflare-sandbox' };
    case MAC:
      return { provider: createMacLocalProvider(), reason: 'mac-local (pull-only)' };
    case GHA: {
      const c = githubActionsConfigured(env);
      if (!c.ok) return { provider: null, reason: `github-actions is disabled (Actions minutes are CI only); missing ${c.missing.join(', ')}` };
      return {
        provider: createGithubActionsProvider({ repo: env.HANDS_GITHUB_ACTIONS_REPO, workflow: env.HANDS_GITHUB_ACTIONS_WORKFLOW, token: env.HANDS_GITHUB_ACTIONS_TOKEN }),
        reason: 'github-actions (explicitly enabled)',
      };
    }
    default:
      return { provider: null, reason: name === 'stub' ? 'stub' : `unknown provider ${String(name).slice(0, 40)}: stub` };
  }
}
