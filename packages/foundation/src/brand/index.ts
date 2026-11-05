/**
 * Ebda AI Studio brand identity: the single source for company and product names, colours, fonts and domains.
 * Pure data and pure helpers (Worker-safe). Product-only helpers (a store host, a "powered by" footer) stay in the product.
 * The company is "Ebda AI Studio" and each product carries its own full name (Ebda Store, Ebda CRM); the bare master name never reaches a user.
 */

export const BRAND = {
  name: 'Ebda AI Studio',
  nameAr: 'ابدأ استوديو للذكاء الاصطناعي',
  company: {
    legalNameAr: 'ابدأ استوديو للذكاء الاصطناعي والبرمجيات والتسويق الرقمي',
    legalNameEn: 'Ebda AI Studio for Artificial Intelligence, Software and Digital Marketing',
    shortNameAr: 'ابدأ استوديو للذكاء الاصطناعي',
    shortNameEn: 'Ebda AI Studio',
    url: 'https://ebda.app',
  },
  colors: { night: '#0A0B0C', gold: '#B08D57', lift: '#CBA873' },
  fonts: {
    sans: 'Geist',
    mono: 'Geist Mono',
    arabic: 'IBM Plex Sans Arabic',
    stacks: {
      sans: '"Geist", ui-sans-serif, system-ui, sans-serif',
      mono: '"Geist Mono", ui-monospace, "SFMono-Regular", monospace',
      arabic: '"IBM Plex Sans Arabic", ui-sans-serif, system-ui, sans-serif',
    },
  },
  domains: {
    marketing: 'ebda.app',
    api: 'api.ebda.app',
    accounts: 'accounts.ebda.app',
    docs: 'docs.ebda.app',
    help: 'help.ebda.app',
    status: 'status.ebda.app',
    /** Free storefront hosts are `<slug>.ebda.app`. */
    suffix: '.ebda.app',
  },
  noReplyEmail: 'no-reply@ebda.app',
} as const;

export type Brand = typeof BRAND;

export interface BrandProduct {
  /** Stable id: also the sub-domain label (`<id>.ebda.app`) and the repo suffix (`ebda-<id>`). */
  id: 'store' | 'whatsapp' | 'crm' | 'erp';
  nameEn: string;
  nameAr: string;
  host: string;
}

/** Every product of the suite. A new product is added here (a foundation PR) before its repo exists. */
export const PRODUCTS: readonly BrandProduct[] = [
  { id: 'store', nameEn: 'Ebda Store', nameAr: 'ابدأ ستور', host: 'store.ebda.app' },
  { id: 'whatsapp', nameEn: 'Ebda WhatsApp', nameAr: 'ابدأ واتساب', host: 'whatsapp.ebda.app' },
  { id: 'crm', nameEn: 'Ebda CRM', nameAr: 'ابدأ CRM', host: 'crm.ebda.app' },
  { id: 'erp', nameEn: 'Ebda ERP', nameAr: 'ابدأ ERP', host: 'erp.ebda.app' },
];

/** Brand name for a locale (`ar*` gives the Arabic wordmark, anything else the Latin one). */
export function brandName(locale?: string | null): string {
  return locale && locale.toLowerCase().startsWith('ar') ? BRAND.nameAr : BRAND.name;
}

/** The product with this id, or throws: an unknown product is a bug, never a default. */
export function getProduct(id: string): BrandProduct {
  const p = PRODUCTS.find((x) => x.id === id);
  if (!p) throw new Error(`unknown product id: ${id}`);
  return p;
}

/** Product display name for a locale. */
export function productName(id: string, locale?: string | null): string {
  const p = getProduct(id);
  return locale && locale.toLowerCase().startsWith('ar') ? p.nameAr : p.nameEn;
}

/** `https://<host>` for a bare hostname. */
export function brandUrl(host: string): string {
  return `https://${host}`;
}

/** True for `ebda.app` itself or any `*.ebda.app` host (port stripped, case-insensitive). */
export function isBrandHost(host: string | null | undefined): boolean {
  if (!host) return false;
  const h = host.toLowerCase().replace(/:\d+$/, '');
  return h === BRAND.domains.marketing || h.endsWith(BRAND.domains.suffix);
}

/** RFC 5322 `From:` value. The sender name must name a product or the studio, never the bare master name. */
export function brandFrom(displayName: string): string {
  if (displayName.trim().toLowerCase() === 'ebda') {
    throw new Error('brandFrom: the sender name must not be the bare brand, name the product');
  }
  return `${displayName} <${BRAND.noReplyEmail}>`;
}

/**
 * Guard patterns for "no bare master brand in user-facing copy" (the stricter WhatsApp set). Header and identifier names
 * (X-Ebda-..., Ebda-Webhooks) are not copy. The plain verb ابدأ ("start") stays allowed; only the brand spellings with
 * hamza under alef are checked.
 */
export const BARE_EN = /(?<!X-)\bEbda\b(?!-Webhooks)(?! (?:Store|AI Studio|WhatsApp|CRM|ERP)\b)/;
export const BARE_AR = /(?:إبدأ|إبدا)(?!\s*(?:ستور|استوديو|واتساب|WhatsApp|CRM|ERP|Store)(?![ء-يٱ-ۓ]))/;

/** Finds bare-brand hits in a string (empty array when clean). */
export function findBareBrand(text: string): string[] {
  return [BARE_EN, BARE_AR].flatMap((re) => {
    const m = re.exec(text);
    return m ? [m[0]] : [];
  });
}
