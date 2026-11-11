// Facebook Page photo post: POST https://graph.facebook.com/{v}/{page-id}/photos (multipart `source` + `caption`, published=true)
// with a never-expiring Page access token (docs/plans/2026-11-11-social-posting.md, "Meta"). Permissions: pages_manage_posts,
// pages_read_engagement, pages_show_list; reading the Page feed (Instagram-share spacing, digest) also needs pages_read_user_content.
// Ref: https://developers.facebook.com/docs/graph-api/reference/page/photos/
import type { Brand } from '../types';
import { parseJsonSecret, thrownResult, type NetworkAdapter, type PagePost, type PublishInput, type PublishResult } from './types';

export interface FacebookPageCreds {
  pageId: string;
  pageToken: string;
}

/** Meta error codes that retrying cannot fix: 190 bad token, 10/200-299 permission, 100 invalid parameter, 368 blocked, 324 bad image. */
const FATAL_CODES = new Set([10, 100, 190, 200, 368, 324, 506]);

export function classifyGraphError(status: number, body: any): PublishResult {
  const err = body?.error ?? {};
  const code = Number(err.code);
  const msg = `facebook HTTP ${status} code ${Number.isFinite(code) ? code : '?'}: ${String(err.message ?? 'no message').slice(0, 200)}`;
  if (err.is_transient === true || status >= 500 || status === 429 || code === 1 || code === 2 || code === 4 || code === 17 || code === 32 || code === 613) return { kind: 'retry', error: msg };
  if (FATAL_CODES.has(code) || (code >= 200 && code < 300) || status === 400 || status === 401 || status === 403) return { kind: 'fatal', error: msg };
  return { kind: 'retry', error: msg };
}

export class FacebookAdapter implements NetworkAdapter {
  readonly network = 'facebook' as const;
  private creds: Partial<Record<Brand, FacebookPageCreds>> | null;
  constructor(secret: string | undefined, private version: string) {
    this.creds = parseJsonSecret<FacebookPageCreds>(secret);
  }

  private c(brand: Brand): FacebookPageCreds | null {
    const c = this.creds?.[brand];
    return c && typeof c.pageId === 'string' && /^\d{5,30}$/.test(c.pageId) && typeof c.pageToken === 'string' && c.pageToken.length > 20 ? c : null;
  }

  disabledReason(brand: Brand): string | null {
    if (!this.creds) return 'SOCIAL_FACEBOOK secret unset (Ahmad: Meta app + Page token, see the plan)';
    return this.c(brand) ? null : `SOCIAL_FACEBOOK has no valid {pageId,pageToken} for ${brand}`;
  }

  async publish(p: PublishInput, fetchImpl: typeof fetch): Promise<PublishResult> {
    const c = this.c(p.brand);
    if (!c) return { kind: 'fatal', error: this.disabledReason(p.brand) ?? 'not configured' };
    const form = new FormData();
    form.append('source', new Blob([p.image], { type: p.imageType }), p.imageType === 'image/png' ? 'post.png' : 'post.jpg');
    form.append('caption', p.text);
    form.append('published', 'true');
    form.append('access_token', c.pageToken);
    let r: Response;
    try {
      r = await fetchImpl(`https://graph.facebook.com/${this.version}/${c.pageId}/photos`, { method: 'POST', body: form });
    } catch (e) {
      return thrownResult(e);
    }
    const body = (await r.json().catch(() => null)) as any;
    if (r.ok && body && (body.post_id || body.id)) return { kind: 'ok', remoteId: String(body.post_id ?? body.id) };
    if (r.ok) return { kind: 'uncertain', error: `facebook HTTP ${r.status} without an id` };
    return classifyGraphError(r.status, body);
  }

  async recentPosts(brand: Brand, sinceMs: number, fetchImpl: typeof fetch): Promise<PagePost[] | null> {
    const c = this.c(brand);
    if (!c) return null;
    const u = new URL(`https://graph.facebook.com/${this.version}/${c.pageId}/feed`);
    u.searchParams.set('fields', 'id,created_time,application{name},message');
    u.searchParams.set('since', String(Math.floor(sinceMs / 1000)));
    u.searchParams.set('limit', '25');
    u.searchParams.set('access_token', c.pageToken);
    try {
      const r = await fetchImpl(u.toString());
      if (!r.ok) return null;
      const j = (await r.json()) as { data?: Array<{ id: string; created_time: string; application?: { name?: string } }> };
      return (j.data ?? []).map((d) => ({ id: String(d.id), createdAt: Date.parse(d.created_time), app: d.application?.name ?? null }));
    } catch {
      return null;
    }
  }

  async findByText(brand: Brand, text: string, sinceMs: number, fetchImpl: typeof fetch): Promise<string | null | undefined> {
    const c = this.c(brand);
    if (!c) return undefined;
    const u = new URL(`https://graph.facebook.com/${this.version}/${c.pageId}/feed`);
    u.searchParams.set('fields', 'id,message');
    u.searchParams.set('since', String(Math.floor(sinceMs / 1000) - 60));
    u.searchParams.set('limit', '25');
    u.searchParams.set('access_token', c.pageToken);
    try {
      const r = await fetchImpl(u.toString());
      if (!r.ok) return undefined;
      const j = (await r.json()) as { data?: Array<{ id: string; message?: string }> };
      return (j.data ?? []).find((d) => (d.message ?? '').trim() === text.trim())?.id ?? null;
    } catch {
      return undefined;
    }
  }

  async checkPage(brand: Brand, fetchImpl: typeof fetch): Promise<{ ok: boolean; pageId?: string; name?: string; error?: string }> {
    const c = this.c(brand);
    if (!c) return { ok: false, error: this.disabledReason(brand) ?? 'not configured' };
    const u = new URL(`https://graph.facebook.com/${this.version}/${c.pageId}`);
    u.searchParams.set('fields', 'id,name');
    u.searchParams.set('access_token', c.pageToken);
    try {
      const r = await fetchImpl(u.toString());
      const j = (await r.json().catch(() => null)) as any;
      if (!r.ok) return { ok: false, pageId: c.pageId, error: `facebook HTTP ${r.status} code ${j?.error?.code ?? '?'}: ${String(j?.error?.message ?? '').slice(0, 120)}` };
      return { ok: true, pageId: String(j?.id ?? c.pageId), name: String(j?.name ?? '') };
    } catch (e) {
      return { ok: false, pageId: c.pageId, error: `fetch failed: ${(e as Error).message}` };
    }
  }
}
