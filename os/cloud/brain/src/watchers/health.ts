// Prod health watcher (cron, every 5 min): GET each HEALTH_TARGETS url with a 10 s timeout. Runs in the Worker, not the
// Durable Object, so the DO is never kept awake waiting on the network. A JSON body with ok:false or status:"down"
// counts as a failure even on HTTP 200 (a 200 is not proof of health).
import type { HealthObservation } from '../brain-do';
import { boundFetch } from '../bound-fetch';

export interface HealthTarget {
  url: string;
  kind: 'api' | 'page' | 'money';
  /** optional owner/name of the repo that ships this service: without it an outage can only be messaged, never handed to the hands (I-2) */
  repo?: string;
}

export function parseTargets(raw: string | undefined): HealthTarget[] {
  try {
    const v = JSON.parse(raw ?? '[]') as unknown;
    if (!Array.isArray(v)) return [];
    return v.filter((t): t is HealthTarget => !!t && typeof t.url === 'string' && /^https:\/\//.test(t.url) && ['api', 'page', 'money'].includes(t.kind)).map((t) => (t.repo !== undefined && !/^[\w.-]+\/[\w.-]+$/.test(String(t.repo)) ? { ...t, repo: undefined } : t)).slice(0, 10);
  } catch {
    return [];
  }
}

export async function checkOne(t: HealthTarget, fetchImpl: typeof fetch = boundFetch, timeoutMs = 10000): Promise<HealthObservation> {
  const t0 = Date.now();
  try {
    const r = await fetchImpl(t.url, { method: 'GET', redirect: 'follow', signal: AbortSignal.timeout(timeoutMs), headers: { 'user-agent': 'ebda-os-brain/health' } });
    let ok = r.status >= 200 && r.status < 400;
    if (ok && t.kind === 'api' && (r.headers.get('content-type') ?? '').includes('json')) {
      const j = (await r.json().catch(() => null)) as { ok?: unknown; status?: unknown } | null;
      if (j && (j.ok === false || j.status === 'down' || j.status === 'error')) ok = false;
    } else {
      await r.body?.cancel();
    }
    return { url: t.url, kind: t.kind, ...(t.repo ? { repo: t.repo } : {}), ok, status: r.status, ms: Date.now() - t0 };
  } catch {
    return { url: t.url, kind: t.kind, ...(t.repo ? { repo: t.repo } : {}), ok: false, status: 0, ms: Date.now() - t0 };
  }
}

export async function checkAll(targets: HealthTarget[], fetchImpl: typeof fetch = boundFetch): Promise<HealthObservation[]> {
  return Promise.all(targets.map((t) => checkOne(t, fetchImpl)));
}
