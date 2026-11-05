// The git host behind an interface (GitHub today), so the brain can move hosts without a rewrite.
// Only read calls live here; the brain never calls GitHub Actions (Actions minutes are for CI only).
import type { Finding } from './findings';

export interface AlertPage {
  notModified: boolean;
  etag: string | null;
  /** true when every page was read (safe to resolve findings that are no longer listed) */
  complete: boolean;
  alerts: Finding[];
}

export interface GitHost {
  readonly name: string;
  /** Open dependency security alerts for one org. Conditional on etag: a 304 costs no rate limit and returns notModified. */
  openDependencyAlerts(org: string, etag: string | null, kev: ReadonlySet<string>, deployedRepos: ReadonlySet<string>): Promise<AlertPage>;
}

const MAX_PAGES = 5;

/** Map one GitHub Dependabot alert to a finding. Exported for tests. */
export function alertToFinding(a: any, kev: ReadonlySet<string>, deployedRepos: ReadonlySet<string> = new Set()): Finding | null {
  const repo = a?.repository?.full_name;
  const ghsa = a?.security_advisory?.ghsa_id;
  if (typeof repo !== 'string' || typeof ghsa !== 'string') return null;
  const cve: string | null = a?.security_advisory?.cve_id ?? null;
  const score = Number(a?.security_advisory?.cvss_severities?.cvss_v4?.score || a?.security_advisory?.cvss_severities?.cvss_v3?.score || a?.security_advisory?.cvss?.score || 0) || undefined;
  const scope = a?.dependency?.scope === 'development' ? 'development' : a?.dependency?.scope === 'runtime' ? 'runtime' : 'unknown';
  const pkg = String(a?.dependency?.package?.name ?? 'unknown');
  return {
    source: 'advisory',
    kind: 'dependency-advisory',
    key: `${repo}#${ghsa}`,
    title: `${pkg} ${ghsa}${cve ? ` (${cve})` : ''} ${a?.security_advisory?.severity ?? ''}`.trim(),
    repo,
    url: typeof a?.html_url === 'string' ? a.html_url : undefined,
    ...(score !== undefined ? { cvss: score } : {}),
    kev: cve ? kev.has(cve) : false,
    depScope: scope,
    deployed: deployedRepos.has(repo),
    detail: { ecosystem: a?.dependency?.package?.ecosystem ?? null, manifest: a?.dependency?.manifest_path ?? null, cve },
  };
}

function nextLink(link: string | null): string | null {
  const m = link?.match(/<([^>]+)>;\s*rel="next"/);
  return m ? m[1]! : null;
}

export class GitHubHost implements GitHost {
  readonly name = 'github';
  constructor(private token: string, private fetchImpl: typeof fetch = fetch) {}

  async openDependencyAlerts(org: string, etag: string | null, kev: ReadonlySet<string>, deployedRepos: ReadonlySet<string>): Promise<AlertPage> {
    const headers: Record<string, string> = {
      authorization: `Bearer ${this.token}`,
      accept: 'application/vnd.github+json',
      'x-github-api-version': '2022-11-28',
      'user-agent': 'ebda-os-brain',
    };
    let url: string | null = `https://api.github.com/orgs/${encodeURIComponent(org)}/dependabot/alerts?state=open&per_page=100`;
    const alerts: Finding[] = [];
    let first = true;
    let newEtag: string | null = null;
    let pages = 0;
    while (url && pages < MAX_PAGES) {
      const r: Response = await this.fetchImpl(url, { headers: first && etag ? { ...headers, 'if-none-match': etag } : headers });
      if (first && r.status === 304) return { notModified: true, etag, complete: true, alerts: [] };
      if (!r.ok) throw new Error(`github ${org} alerts HTTP ${r.status}`);
      if (first) newEtag = r.headers.get('etag');
      first = false;
      pages++;
      for (const a of (await r.json()) as unknown[]) {
        const f = alertToFinding(a, kev, deployedRepos);
        if (f) alerts.push(f);
      }
      url = nextLink(r.headers.get('link'));
    }
    return { notModified: false, etag: newEtag, complete: url === null, alerts };
  }
}

/** CISA Known Exploited Vulnerabilities feed: refreshed at most daily, conditional on ETag, cached as a CVE id list in KV. */
export const KEV_URL = 'https://www.cisa.gov/sites/default/files/feeds/known_exploited_vulnerabilities.json';

export async function loadKev(kv: KVNamespace, now: number, fetchImpl: typeof fetch = fetch): Promise<Set<string>> {
  const cached = await kv.get<{ at: number; etag: string | null; ids: string[] }>('kev:v1', 'json');
  if (cached && now - cached.at < 24 * 3600 * 1000) return new Set(cached.ids);
  try {
    const r = await fetchImpl(KEV_URL, { headers: cached?.etag ? { 'if-none-match': cached.etag } : {} });
    if (r.status === 304 && cached) {
      await kv.put('kev:v1', JSON.stringify({ ...cached, at: now }));
      return new Set(cached.ids);
    }
    if (!r.ok) return new Set(cached?.ids ?? []);
    const j = (await r.json()) as { vulnerabilities?: Array<{ cveID?: string }> };
    const ids = (j.vulnerabilities ?? []).map((v) => v.cveID).filter((x): x is string => typeof x === 'string');
    await kv.put('kev:v1', JSON.stringify({ at: now, etag: r.headers.get('etag'), ids }));
    return new Set(ids);
  } catch {
    return new Set(cached?.ids ?? []);
  }
}
