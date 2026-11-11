// Copy rules enforced at the brain's edge (the Mac job's prompt asks for them too; this is the gate, the prompt is a hint).
// Ahmad: no emojis; no invented claims, numbers, reviews or client names; his GCC contracts company is never mentioned (the name
// is assembled at runtime so this repo's predecessor-string guard stays meaningful); Ebda's master brand is always
// "Ebda AI Studio" and products "Ebda <X>", never a bare "Ebda".
import { BRANDS, NETWORKS, type DraftInput } from './types';

const BANNED_ORG = new RegExp(`${['fo', 'rce'].join('')}\\s*-?\\s*${'a'}i`, 'i');

export const MAX_TEXT: Record<string, number> = { facebook: 5000, linkedin: 3000 };
export const MAX_IMAGE_BYTES = 4 * 1024 * 1024;
const ID_RE = /^(whisky11|ebda)-(facebook|linkedin)-\d{12}$/;

/** Returns every rule the copy breaks (empty = clean). */
export function copyViolations(text: string): string[] {
  const out: string[] = [];
  if (/[\p{Extended_Pictographic}\u{1F1E6}-\u{1F1FF}\u{FE0F}]/u.test(text)) out.push('contains an emoji');
  if (BANNED_ORG.test(text)) out.push('mentions the GCC contracts company');
  // every Latin "Ebda" must be followed by a capitalised product word ("Ebda AI Studio", "Ebda Store", "Ebda Chat")
  for (const m of text.matchAll(/\bEbda\b(?!\s+[A-Z])/g)) {
    out.push(`bare "Ebda" at ${m.index}`);
    break;
  }
  // invented numbers and social proof: percentages, counts of clients/customers/merchants/stores/users, ratings, reviews
  if (/\d+(?:[.,]\d+)?\s*%/.test(text)) out.push('contains a percentage');
  if (/\b\d[\d,.]*\+?\s*(?:k\s+)?(?:clients?|customers?|merchants?|stores?|users?|businesses|companies|projects|downloads|orders)\b/i.test(text)) out.push('contains a count of clients/customers/users');
  if (/\b(?:rated\s+\d|\d(?:[.,]\d)?\s*(?:\/\s*5\s*)?stars?|(?:customer|client|user|5-star)\s+reviews?|testimonials?|trusted by|award-winning)\b/i.test(text)) out.push('contains a rating/review/social-proof claim');
  if (/[٠-٩]+\s*[٪%]/.test(text)) out.push('contains a percentage');
  return out;
}

function b64Bytes(b64: string): number {
  const pad = b64.endsWith('==') ? 2 : b64.endsWith('=') ? 1 : 0;
  return Math.floor((b64.length * 3) / 4) - pad;
}

/** Zod-style edge validation of a draft from the Mac job. Returns an error string or null. */
export function validateDraft(d: unknown, now: number): string | null {
  if (!d || typeof d !== 'object') return 'draft must be an object';
  const x = d as Partial<DraftInput>;
  if (typeof x.id !== 'string' || !ID_RE.test(x.id)) return 'id must be <brand>-<network>-<YYYYMMDDHHmm>';
  if (!BRANDS.includes(x.brand as never)) return 'unknown brand';
  if (!NETWORKS.includes(x.network as never)) return 'unknown network (the OS posts to facebook and linkedin only)';
  if (!x.id.startsWith(`${x.brand}-${x.network}-`)) return 'id does not match brand/network';
  if (x.origin !== 'os') return "origin must be 'os' (Instagram content is never re-posted)";
  if (typeof x.scheduledAt !== 'number' || !Number.isFinite(x.scheduledAt)) return 'scheduledAt must be epoch ms';
  if (x.scheduledAt < now - 60_000 || x.scheduledAt > now + 60 * 86_400_000) return 'scheduledAt must be in the next 60 days';
  if (typeof x.text !== 'string' || !x.text.trim()) return 'text is required';
  if (x.text.length > (MAX_TEXT[x.network!] ?? 3000)) return `text longer than ${MAX_TEXT[x.network!]} chars`;
  const v = copyViolations(x.text);
  if (v.length) return `copy rules: ${v.join('; ')}`;
  if (x.altText !== undefined && (typeof x.altText !== 'string' || x.altText.length > 1000)) return 'altText must be a string <= 1000 chars';
  if (x.imageType !== 'image/jpeg' && x.imageType !== 'image/png') return 'imageType must be image/jpeg or image/png';
  if (typeof x.imageBase64 !== 'string' || !/^[A-Za-z0-9+/]+={0,2}$/.test(x.imageBase64)) return 'imageBase64 must be base64';
  const n = b64Bytes(x.imageBase64);
  if (n < 1024 || n > MAX_IMAGE_BYTES) return 'image must be 1 KB - 4 MB';
  return null;
}
