// LinkedIn organization post with one image: Images API initializeUpload -> upload bytes -> Posts API (author = organization URN).
// Needs scope w_organization_social, which only an APPROVED Community Management API product grants (Development tier is enough
// for this volume: 500 calls/app/day). Until SOCIAL_LINKEDIN is set the adapter is disabled and says so.
// Ref: https://learn.microsoft.com/en-us/linkedin/marketing/community-management/shares/posts-api
//      https://learn.microsoft.com/en-us/linkedin/marketing/community-management/shares/images-api
import type { Brand } from '../types';
import { parseJsonSecret, thrownResult, type NetworkAdapter, type PublishInput, type PublishResult } from './types';

export interface LinkedInCreds {
  orgUrn: string;
  token: string;
  /** ISO date the 60-day access token expires (the digest warns 7 days ahead) */
  expiresAt?: string;
}

/** LinkedIn "little text" commentary: these characters must be backslash-escaped or the post text is cut / misparsed. */
export function escapeLittleText(s: string): string {
  return s.replace(/[\\|{}@\[\]()<>#*_~]/g, (c) => `\\${c}`);
}

function classify(status: number, what: string, body: string): PublishResult {
  const error = `linkedin ${what} HTTP ${status}: ${body.slice(0, 200)}`;
  if (status === 429 || status >= 500) return { kind: 'retry', error };
  return { kind: 'fatal', error };
}

export class LinkedInAdapter implements NetworkAdapter {
  readonly network = 'linkedin' as const;
  private creds: Partial<Record<Brand, LinkedInCreds>> | null;
  constructor(secret: string | undefined, private version: string) {
    this.creds = parseJsonSecret<LinkedInCreds>(secret);
  }

  private c(brand: Brand): LinkedInCreds | null {
    const c = this.creds?.[brand];
    return c && typeof c.orgUrn === 'string' && /^urn:li:organization:\d+$/.test(c.orgUrn) && typeof c.token === 'string' && c.token.length > 20 ? c : null;
  }

  tokenExpiry(brand: Brand): number | null {
    const e = this.c(brand)?.expiresAt;
    const t = e ? Date.parse(e) : NaN;
    return Number.isFinite(t) ? t : null;
  }

  disabledReason(brand: Brand): string | null {
    if (!this.creds) return 'SOCIAL_LINKEDIN secret unset (needs an approved Community Management API app, see the plan)';
    return this.c(brand) ? null : `SOCIAL_LINKEDIN has no valid {orgUrn,token} for ${brand}`;
  }

  private headers(c: LinkedInCreds): Record<string, string> {
    return { Authorization: `Bearer ${c.token}`, 'Linkedin-Version': this.version, 'X-Restli-Protocol-Version': '2.0.0', 'Content-Type': 'application/json' };
  }

  async publish(p: PublishInput, fetchImpl: typeof fetch): Promise<PublishResult> {
    const c = this.c(p.brand);
    if (!c) return { kind: 'fatal', error: this.disabledReason(p.brand) ?? 'not configured' };
    // steps 1 and 2 create nothing visible: a failure or a lost answer there is a plain retry
    let uploadUrl: string;
    let imageUrn: string;
    try {
      const r = await fetchImpl('https://api.linkedin.com/rest/images?action=initializeUpload', {
        method: 'POST',
        headers: this.headers(c),
        body: JSON.stringify({ initializeUploadRequest: { owner: c.orgUrn } }),
      });
      if (!r.ok) return classify(r.status, 'initializeUpload', await r.text().catch(() => ''));
      const j = (await r.json()) as { value?: { uploadUrl?: string; image?: string } };
      if (!j.value?.uploadUrl || !j.value.image) return { kind: 'retry', error: 'linkedin initializeUpload answered without uploadUrl/image' };
      uploadUrl = j.value.uploadUrl;
      imageUrn = j.value.image;
      const up = await fetchImpl(uploadUrl, { method: 'PUT', headers: { Authorization: `Bearer ${c.token}`, 'Content-Type': p.imageType }, body: p.image });
      if (!up.ok) return classify(up.status, 'image upload', await up.text().catch(() => ''));
    } catch (e) {
      return { kind: 'retry', error: `linkedin image step failed: ${(e as Error).message}` };
    }
    // step 3 creates the post: from here a lost answer is uncertain
    let r: Response;
    try {
      r = await fetchImpl('https://api.linkedin.com/rest/posts', {
        method: 'POST',
        headers: this.headers(c),
        body: JSON.stringify({
          author: c.orgUrn,
          commentary: escapeLittleText(p.text),
          visibility: 'PUBLIC',
          distribution: { feedDistribution: 'MAIN_FEED', targetEntities: [], thirdPartyDistributionChannels: [] },
          content: { media: { id: imageUrn, ...(p.altText ? { altText: p.altText } : {}) } },
          lifecycleState: 'PUBLISHED',
          isReshareDisabledByAuthor: false,
        }),
      });
    } catch (e) {
      return thrownResult(e);
    }
    if (r.status === 201) {
      const id = r.headers.get('x-restli-id');
      return id ? { kind: 'ok', remoteId: id } : { kind: 'uncertain', error: 'linkedin 201 without x-restli-id' };
    }
    return classify(r.status, 'posts', await r.text().catch(() => ''));
  }
}
