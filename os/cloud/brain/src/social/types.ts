// Social posting (plan: docs/plans/2026-11-11-social-posting.md). Scope (Ahmad 2026-11-11): the OS posts ONLY to the Facebook Pages and
// LinkedIn company pages of the two brands. Instagram and TikTok are Ahmad's own; Instagram reaches Facebook through Meta's own
// Accounts Center sharing, which the Facebook schedule spaces around and never re-posts.

export const BRANDS = ['whisky11', 'ebda'] as const;
export type Brand = (typeof BRANDS)[number];
export const NETWORKS = ['facebook', 'linkedin'] as const;
export type Network = (typeof NETWORKS)[number];

export const BRAND_LABEL: Record<Brand, string> = { whisky11: 'Whisky 11', ebda: 'Ebda AI Studio' };

/**
 * draft -> asked (preview sent to Ahmad) -> approved -> publishing -> published
 * asked -> edit_requested (the Mac job re-submits a new revision: back to draft) | skipped | expired
 * publishing -> failed (definite platform error after the retries) | uncertain (the outcome is unknown: never retried, Ahmad is told)
 */
export type PostStatus = 'draft' | 'asked' | 'approved' | 'publishing' | 'published' | 'edit_requested' | 'skipped' | 'expired' | 'failed' | 'uncertain';

export interface DraftInput {
  /** stable slot id from the Mac job, e.g. whisky11-linkedin-202611171000; a re-submit of the same id is a new revision */
  id: string;
  brand: Brand;
  network: Network;
  /** epoch ms of the slot */
  scheduledAt: number;
  text: string;
  /** image bytes, base64 (JPEG or PNG, <= 4 MB decoded) */
  imageBase64: string;
  imageType: 'image/jpeg' | 'image/png';
  altText?: string;
  /** where the copy came from; anything but 'os' is refused (never re-post Instagram content) */
  origin: 'os';
}

export interface PostRow {
  id: string;
  brand: Brand;
  network: Network;
  rev: number;
  status: PostStatus;
  scheduled_at: number;
  orig_scheduled_at: number;
  text: string;
  alt_text: string | null;
  image_key: string;
  image_type: string;
  approved_by: string | null;
  approved_at: number | null;
  edit_note: string | null;
  attempts: number;
  next_at: number | null;
  claim_at: number | null;
  remote_id: string | null;
  last_error: string | null;
  published_at: number | null;
  asked_at: number | null;
  alerted: number;
}

export type Decision = 'approve' | 'edit' | 'skip';
