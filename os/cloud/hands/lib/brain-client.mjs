// The hands' side of the brain contract (os/cloud/brain/src/hands.ts): Bearer HANDS_TOKEN on every call.
//   GET  /hands/runs/:runId          -> HandsBatch
//   POST /hands/claim {provider,max} -> HandsBatch | {refused}
//   POST /hands/jobs/:jobId/outcome  {status, prUrl?, note?}
//   POST /hands/usage                {weeklyUsedPct, resetsAt?}   (resetsAt epoch ms)
export function brainClient({ url, token, fetchImpl = fetch }) {
  if (!url || !token) throw new Error('BRAIN_URL and HANDS_TOKEN are required (or use --dry-run)');
  const base = url.replace(/\/+$/, '');
  async function call(method, path, body) {
    const res = await fetchImpl(`${base}${path}`, {
      method,
      headers: { authorization: `Bearer ${token}`, ...(body ? { 'content-type': 'application/json' } : {}) },
      ...(body ? { body: JSON.stringify(body) } : {}),
    });
    const text = await res.text();
    let data = null;
    try {
      data = text ? JSON.parse(text) : null;
    } catch {
      data = { raw: text.slice(0, 200) };
    }
    if (!res.ok) throw Object.assign(new Error(`brain ${method} ${path} -> ${res.status}`), { status: res.status, data });
    return data;
  }
  return {
    getRun: (runId) => call('GET', `/hands/runs/${encodeURIComponent(runId)}`),
    claim: (provider, max) => call('POST', '/hands/claim', { provider, max }),
    outcome: (jobId, o) => call('POST', `/hands/jobs/${encodeURIComponent(jobId)}/outcome`, o),
    usage: (u) => call('POST', '/hands/usage', u),
  };
}

/** Offline brain for --dry-run: serves a fixture batch and records what the run reports. */
export function recordingBrain(batch) {
  const outcomes = [];
  const usageReports = [];
  return {
    outcomes,
    usageReports,
    getRun: async () => batch,
    claim: async () => batch,
    outcome: async (jobId, o) => {
      outcomes.push({ jobId, ...o });
      return { ok: true };
    },
    usage: async (u) => {
      usageReports.push(u);
      return { ok: true };
    },
  };
}
