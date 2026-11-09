// Provider `cloudflare-sandbox` (the default once Task 7 enables it). Runs INSIDE the brain Worker: start(batch) asks the
// HandsContainer Durable Object (os/cloud/brain/src/hands-container.ts) to boot ONE container from this directory's
// Dockerfile, which runs `run-batch.mjs --run <runId>` and exits.
//
// Who starts it (frugal rule, Amendment A/A.1): the brain's nightly cron (30 21 * * *, one batch a day) and the urgent
// dispatcher (max URGENT_RUNS_PER_DAY a day, one at a time, URGENT_RUN_CAP_MIN cap). Nothing else. This provider adds
// its own guards on top: one container per lane (DO name `hands-<kind>`, a busy container answers 409 and the start is
// reported as a failed run), and a hard wall-clock cap the DO enforces with an alarm (urgent: the job cap; nightly:
// HANDS_NIGHTLY_RUN_CAP_MIN). Worker-compatible ESM: no node: imports.
export const NAME = 'cloudflare-sandbox';
export const DEFAULT_NIGHTLY_RUN_CAP_MIN = 90;

export function runCapFor(batch, nightlyRunCapMin = DEFAULT_NIGHTLY_RUN_CAP_MIN) {
  return batch.kind === 'urgent' ? batch.perJobCapMin : nightlyRunCapMin;
}

export function createCloudflareSandboxProvider({ namespace, nightlyRunCapMin = DEFAULT_NIGHTLY_RUN_CAP_MIN, now = () => Date.now() } = {}) {
  return {
    name: NAME,
    async start(batch) {
      if (!namespace) throw new Error('HANDS_CONTAINER binding missing: containers are not configured (Task 7)');
      const capMin = runCapFor(batch, nightlyRunCapMin);
      const stub = namespace.get(namespace.idFromName(`hands-${batch.kind}`));
      const res = await stub.fetch('https://hands.internal/start', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ runId: batch.runId, kind: batch.kind, capMin, repos: [...new Set((batch.jobs ?? []).map((j) => j?.finding?.repo).filter(Boolean))] }),
      });
      if (!res.ok) throw new Error(`container start refused: ${res.status} ${(await res.text()).slice(0, 200)}`);
      const j = await res.json().catch(() => ({}));
      return { runId: batch.runId, provider: NAME, externalId: j.externalId ?? `hands-${batch.kind}:${batch.runId}`, startedAt: now() };
    },
    /** F-04 / F-01: destroy the lane's container now. halt:true also makes the container DO refuse later starts until resume(). Never throws. */
    async stop(kind, { halt = false } = {}) {
      if (!namespace) return { ok: true, note: 'no container binding' };
      try {
        const res = await namespace.get(namespace.idFromName(`hands-${kind}`)).fetch('https://hands.internal/stop', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ halt }) });
        return { ok: res.ok };
      } catch (e) {
        return { ok: false, note: String(e?.message ?? e).slice(0, 200) };
      }
    },
    async resume(kind) {
      if (!namespace) return { ok: true };
      try {
        const res = await namespace.get(namespace.idFromName(`hands-${kind}`)).fetch('https://hands.internal/resume', { method: 'POST' });
        return { ok: res.ok };
      } catch {
        return { ok: false };
      }
    },
  };
}
