/**
 * Slug rules for `<slug>.ebda.app` hosts. Canonical copy of ebda-store packages/shared/src/hosts/{slug,reserved-slugs}.ts
 * and utils slugify. Stays in the Store: the brand-impersonation list (abuse/protected-slugs), the demo showroom family
 * and the Zod schema, because they need product data.
 */

export const SLUG_MIN_LENGTH = 3;
export const SLUG_MAX_LENGTH = 40;

/**
 * Reserved labels: our own service hosts. A slug equal to one would collide with a real host or let a merchant
 * impersonate the platform. Adding a label is a one-line foundation change.
 */
export const RESERVED_SLUGS = [
  'app',
  'api',
  'docs',
  'help',
  'status',
  'whatsapp',
  'www',
  'admin',
  'orders',
  'mail',
  'cdn',
  'assets',
  'static',
  'store',
  'dashboard',
  'billing',
  'support',
  'blog',
  // product family (PRODUCT-NAME-1): `store` also hosts cache revalidation.
  'crm',
  'erp',
  'hub',
  'id',
  'accounts',
] as const;

export type ReservedSlug = (typeof RESERVED_SLUGS)[number];

const RESERVED_SET: ReadonlySet<string> = new Set(RESERVED_SLUGS);

/** True when `slug` (case-insensitive, trimmed) is reserved and can never be a store. */
export function isReservedSlug(slug: string | null | undefined): boolean {
  if (typeof slug !== 'string') return false;
  return RESERVED_SET.has(slug.trim().toLowerCase());
}

export type SlugErrorCode = 'SLUG_TOO_SHORT' | 'SLUG_TOO_LONG' | 'SLUG_INVALID_CHARS' | 'SLUG_INVALID_HYPHEN' | 'SLUG_RESERVED';

export type SlugValidation = { ok: true; slug: string } | { ok: false; code: SlugErrorCode };

const SLUG_CHARS = /^[a-z0-9-]+$/;

/**
 * Format and reserved-list check: lowercase a-z0-9 and hyphen, 3-40 chars, no leading, trailing or double hyphen.
 * Input is NOT normalised (`Amelia` is invalid, not silently lowercased): what is validated is exactly what is stored.
 */
export function validateSlug(raw: string): SlugValidation {
  if (!SLUG_CHARS.test(raw)) return { ok: false, code: 'SLUG_INVALID_CHARS' };
  if (raw.length < SLUG_MIN_LENGTH) return { ok: false, code: 'SLUG_TOO_SHORT' };
  if (raw.length > SLUG_MAX_LENGTH) return { ok: false, code: 'SLUG_TOO_LONG' };
  if (raw.startsWith('-') || raw.endsWith('-') || raw.includes('--')) return { ok: false, code: 'SLUG_INVALID_HYPHEN' };
  if (isReservedSlug(raw)) return { ok: false, code: 'SLUG_RESERVED' };
  return { ok: true, slug: raw };
}

const SLUG_STRIP = /[^a-z0-9\u0600-\u06FF\s-]+/g;

/** Store slugs are stricter: ASCII only. See `slugifyWithFallback`. */
const SLUG_STRIP_ASCII = /[^a-z0-9\s-]+/g;

/**
 * Generate a URL-friendly slug from a string.
 *
 * Keeps the Arabic block, so an Arabic product name yields an Arabic slug
 * rather than an empty string (`\w` is ASCII-only, and stripping to it meant
 * every Arabic-only name slugified to ''). Product URLs already carry Arabic
 * slugs in production and the storefront encodes/decodes them symmetrically.
 *
 * CAN RETURN AN EMPTY STRING for input with no letters or digits in the
 * supported charset. Callers that persist a slug must use `slugifyWithFallback`.
 */
export function slugify(text: string, opts: { ascii?: boolean } = {}): string {
  return (text ?? '')
    .toLowerCase()
    .trim()
    .replace(opts.ascii ? SLUG_STRIP_ASCII : SLUG_STRIP, '')
    .replace(/[\s_-]+/g, '-')
    .replace(/^-+|-+$/g, '');
}

/**
 * `slugify` that is guaranteed to return a non-empty, URL-safe slug.
 *
 * Persisting an empty slug is never harmless: a product whose slug is '' is
 * unreachable (its URL collapses to the listing page), and a de-duplication
 * loop appending a counter to an empty base produces '-1', '-2', '-3' — which
 * is exactly what reached production on a live store (2026-09-02). Every
 * server-side path that WRITES a slug must use this, not bare `slugify`.
 *
 * PASS `ascii: true` FOR STORE SLUGS. A store slug is the host label of the
 * store's free address (`<slug>.ebda.app`), and DNS labels are ASCII (letters,
 * digits, hyphen): a non-ASCII slug is unroutable. `parseStoreHost` and the
 * slug validation in `./hosts` enforce `[a-z0-9-]` for the same reason. An
 * Arabic-only store name therefore falls back to `store-<id>` rather than
 * minting a slug nothing can resolve. (Reserved labels and the 3-40 length
 * rules are applied on top by `validateStoreSlug`.)
 */
export function slugifyWithFallback(
  text: string,
  prefix = 'item',
  opts: { ascii?: boolean } = {}
): string {
  const base = slugify(text ?? '', opts);
  return base || `${prefix}-${Date.now().toString(36)}`;
}
