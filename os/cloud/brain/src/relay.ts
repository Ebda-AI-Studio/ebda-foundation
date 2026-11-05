// GitHub webhook relay, ported from the predecessor event relay with its wire contract unchanged.
//
// Cross-impl HMAC parity (CRITICAL): signEvent MUST byte-match the Mac listener's event_validate:
//   sig = HMAC_SHA256(RELAY_SECRET, id + "|" + kind + "|" + ts + "|" + compactJSON(target))
// where compactJSON = JSON.stringify with no spaces (the bash side uses json.dumps(target, separators=(",",":"))).
// Both sides preserve the target's own key order and do NOT re-sort keys. test/relay.test.ts pins the fixed vector
// (python: hmac.new(b"s3cr3t", b'e1|ci-failure|1000|{"slug":"o/r","sha":"s1"}', hashlib.sha256).hexdigest()).

const enc = new TextEncoder();

export function hexEncode(buf: ArrayBuffer): string {
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

function hexDecode(hex: string): Uint8Array | null {
  if (hex.length === 0 || hex.length % 2 !== 0 || !/^[0-9a-fA-F]+$/.test(hex)) return null;
  const out = new Uint8Array(hex.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16);
  return out;
}

async function hmacKey(secret: string, usage: Array<'sign' | 'verify'>): Promise<CryptoKey> {
  return crypto.subtle.importKey('raw', enc.encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, usage);
}

/** Verify GitHub's `X-Hub-Signature-256: sha256=<hex>` over the raw body (constant-time inside subtle.verify). */
export async function verifyGitHubSig(rawBody: string, sigHeader: string | null | undefined, secret: string | undefined): Promise<boolean> {
  if (!secret || typeof sigHeader !== 'string' || !sigHeader.startsWith('sha256=')) return false;
  const provided = hexDecode(sigHeader.slice('sha256='.length));
  if (!provided) return false;
  return crypto.subtle.verify('HMAC', await hmacKey(secret, ['verify']), provided, enc.encode(rawBody));
}

/** Sign an event the way the Mac listener validates it (see the parity note above). */
export async function signEvent(id: string, kind: string, ts: number, target: object, secret: string): Promise<string> {
  const msg = `${id}|${kind}|${ts}|${JSON.stringify(target)}`;
  return hexEncode(await crypto.subtle.sign('HMAC', await hmacKey(secret, ['sign']), enc.encode(msg)));
}

/** Constant-time string compare: walks the longer input fully, so timing does not reveal the mismatch position. */
export function timingSafeEqualStr(a: string, b: string): boolean {
  const x = enc.encode(String(a));
  const y = enc.encode(String(b));
  const n = Math.max(x.length, y.length);
  let diff = x.length === y.length ? 0 : 1;
  for (let i = 0; i < n; i++) diff |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return diff === 0;
}

/** `Authorization: Bearer <secret>` check. An unset secret never authenticates (fail closed). */
export function checkBearerAuth(request: Request, secret: string | undefined): boolean {
  if (!secret) return false;
  const h = request.headers.get('Authorization') ?? '';
  return h.startsWith('Bearer ') && timingSafeEqualStr(h.slice(7), secret);
}

export interface RelayEvent {
  id: string;
  kind: string;
  ts: number;
  target: { slug: string; sha: string; [k: string]: unknown };
  sig: string;
}

/**
 * Map a GitHub webhook to the relay's {kind,target}, or null to ignore. The target stays exactly {slug, sha}
 * (the Mac listener signs over it); the brain reads the extra run detail through mapRunDetail.
 */
export function mapEvent(ghEvent: string, payload: any): { kind: string; target: { slug: string; sha: string } } | null {
  if (ghEvent !== 'workflow_run') return null;
  const run = payload?.workflow_run;
  if (!run || run.conclusion !== 'failure') return null;
  return { kind: 'ci-failure', target: { slug: payload?.repository?.full_name, sha: run.head_sha } };
}

/** Extra workflow_run detail the brain keeps alongside the signed event (not part of the signature). */
export function mapRunDetail(payload: any): { workflow: string; branch: string; url: string; defaultBranch: string } {
  const run = payload?.workflow_run ?? {};
  return {
    workflow: String(run.name ?? ''),
    branch: String(run.head_branch ?? ''),
    url: String(run.html_url ?? ''),
    defaultBranch: String(payload?.repository?.default_branch ?? 'main'),
  };
}
