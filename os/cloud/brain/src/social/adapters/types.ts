import type { Brand, Network } from '../types';

export interface PublishInput {
  brand: Brand;
  text: string;
  altText: string | null;
  image: ArrayBuffer;
  imageType: string;
}

/**
 * ok        the platform accepted the post (remoteId = its id)
 * retry     a DEFINITE failure the platform answered before creating anything (5xx, 429, transient): safe to try again
 * fatal     a definite failure retrying cannot fix (bad token, missing permission, invalid media): stop and tell Ahmad
 * uncertain the request may have reached the platform but no answer came back: NEVER retried (a post must not go out twice)
 */
export type PublishResult =
  | { kind: 'ok'; remoteId: string }
  | { kind: 'retry' | 'fatal' | 'uncertain'; error: string };

export interface PagePost {
  id: string;
  createdAt: number;
  /** the app that published it (Meta's `application.name`), when the API returns it */
  app: string | null;
}

export interface NetworkAdapter {
  network: Network;
  /** null = ready for this brand; otherwise why the adapter is disabled (reported in the digest and /social/status) */
  disabledReason(brand: Brand): string | null;
  publish(p: PublishInput, fetchImpl: typeof fetch): Promise<PublishResult>;
  /** Facebook only: the Page's own recent posts (spacing around Instagram shares, digest). null = could not read. */
  recentPosts?(brand: Brand, sinceMs: number, fetchImpl: typeof fetch): Promise<PagePost[] | null>;
  /** Facebook only: after an uncertain outcome, find a post with exactly this text since claimAt (null = not readable). */
  findByText?(brand: Brand, text: string, sinceMs: number, fetchImpl: typeof fetch): Promise<string | null | undefined>;
}

/** Classifies a fetch exception. A thrown fetch may or may not have reached the platform: always uncertain. */
export function thrownResult(e: unknown): PublishResult {
  return { kind: 'uncertain', error: `network error after send: ${(e as Error)?.message ?? String(e)}` };
}

export function parseJsonSecret<T>(raw: string | undefined): Partial<Record<Brand, T>> | null {
  if (!raw) return null;
  try {
    const v = JSON.parse(raw);
    return v && typeof v === 'object' ? (v as Partial<Record<Brand, T>>) : null;
  } catch {
    return null;
  }
}
