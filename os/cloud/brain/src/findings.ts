// A finding is anything a watcher, the relay, the dreaming cycle or a self-heal recipe noticed. The brain never
// messages about a finding; it turns it into a job (act first) and reports outcomes.
import { hexEncode } from './relay';

export type Lane = 'urgent' | 'nightly' | 'question' | 'digest';
export type MergePolicy = 'auto-when-gate-green' | 'pr-and-question';

export interface Finding {
  /** who raised it: ci | health | advisory | dream | watcher | self-heal | self-check */
  source: string;
  /** what it is: ci-failure, prod-outage, money-path-broken, dependency-advisory, data-exposure, docs, lint, test, ... */
  kind: string;
  /** stable identity within source+kind (repo@sha, url, GHSA@repo); same key = same finding, never raised twice */
  key: string;
  title: string;
  repo?: string;
  url?: string;
  severity?: 'P1' | 'P2' | 'P3';
  /** advisories: CVSS base score, CISA KEV listing, dependency scope, and whether the affected code is deployed
   *  (true only when known: the advisory watcher sets it from DEPLOYED_REPOS; unset counts as not deployed) */
  cvss?: number;
  kev?: boolean;
  depScope?: 'runtime' | 'development' | 'unknown';
  deployed?: boolean;
  /** outages: true once the self-heal recipes spent their retry budget without fixing it */
  selfHealExhausted?: boolean;
  /** areas the fix would touch (money, auth, data-deletion, deploy-config, prod-data, secrets, billing, purchase, ...) */
  touches?: string[];
  detail?: Record<string, unknown>;
}

export interface Classification {
  lane: Lane;
  reason: string;
  mergePolicy: MergePolicy;
}

/** sha-256 over source|kind|key, first 32 hex chars. The dedupe identity of a finding. */
export async function fingerprint(f: Pick<Finding, 'source' | 'kind' | 'key'>): Promise<string> {
  const d = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(`${f.source}|${f.kind}|${f.key}`));
  return hexEncode(d).slice(0, 32);
}

/**
 * The evidence of a finding: the facts that would make a re-sighting a NEW occurrence (a different failing commit, a
 * new outage streak, a changed score / KEV listing / scope). Titles and counters are excluded on purpose.
 */
export async function evidenceOf(f: Finding): Promise<string> {
  const e = { cvss: f.cvss ?? null, kev: f.kev ?? null, depScope: f.depScope ?? null, deployed: f.deployed ?? null, severity: f.severity ?? null, touches: [...(f.touches ?? [])].sort(), detail: f.detail ?? null };
  const d = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(JSON.stringify(e)));
  return hexEncode(d).slice(0, 32);
}

/** Shape check at the ingest edge (POST /findings). Returns an error string or null. */
export function validateFinding(x: unknown): string | null {
  if (!x || typeof x !== 'object') return 'finding must be an object';
  const f = x as Record<string, unknown>;
  for (const k of ['source', 'kind', 'key', 'title'] as const) {
    if (typeof f[k] !== 'string' || !(f[k] as string).trim() || (f[k] as string).length > 500) return `${k} must be a non-empty string <= 500 chars`;
  }
  if (f.cvss !== undefined && (typeof f.cvss !== 'number' || f.cvss < 0 || f.cvss > 10)) return 'cvss must be a number 0..10';
  if (f.touches !== undefined && (!Array.isArray(f.touches) || f.touches.some((t) => typeof t !== 'string'))) return 'touches must be string[]';
  if (f.severity !== undefined && !['P1', 'P2', 'P3'].includes(f.severity as string)) return 'severity must be P1|P2|P3';
  if (f.depScope !== undefined && !['runtime', 'development', 'unknown'].includes(f.depScope as string)) return 'depScope must be runtime|development|unknown';
  return null;
}
