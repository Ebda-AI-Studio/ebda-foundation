// Provider `github-actions`: PRESENT BUT DISABLED. GitHub Actions minutes are for CI only (Amendment A); the OS spends
// none on its own work. selectProvider() refuses it unless HANDS_GITHUB_ACTIONS_ENABLED=true AND a repo, workflow and
// token are configured; no workflow for it ships in this repo. If ever enabled, start() dispatches one
// workflow_dispatch with the run id. Worker-compatible ESM: no node: imports.
export const NAME = 'github-actions';

export function githubActionsConfigured(env = {}) {
  const missing = [];
  if (env.HANDS_GITHUB_ACTIONS_ENABLED !== 'true') missing.push('HANDS_GITHUB_ACTIONS_ENABLED=true');
  if (!/^[\w.-]+\/[\w.-]+$/.test(String(env.HANDS_GITHUB_ACTIONS_REPO ?? ''))) missing.push('HANDS_GITHUB_ACTIONS_REPO');
  if (!/^[\w.-]+\.ya?ml$/.test(String(env.HANDS_GITHUB_ACTIONS_WORKFLOW ?? ''))) missing.push('HANDS_GITHUB_ACTIONS_WORKFLOW');
  if (!env.HANDS_GITHUB_ACTIONS_TOKEN) missing.push('HANDS_GITHUB_ACTIONS_TOKEN');
  return { ok: missing.length === 0, missing };
}

export function createGithubActionsProvider({ repo, workflow, token, ref = 'main', fetchImpl = (...a) => fetch(...a), now = () => Date.now() }) {
  return {
    name: NAME,
    async start(batch) {
      const res = await fetchImpl(`https://api.github.com/repos/${repo}/actions/workflows/${workflow}/dispatches`, {
        method: 'POST',
        headers: { authorization: `Bearer ${token}`, accept: 'application/vnd.github+json', 'user-agent': 'ebda-os-brain', 'content-type': 'application/json' },
        body: JSON.stringify({ ref, inputs: { run_id: batch.runId } }),
      });
      if (res.status !== 204) throw new Error(`workflow_dispatch -> ${res.status}`);
      return { runId: batch.runId, provider: NAME, startedAt: now() };
    },
  };
}
