/**
 * Output rail 10: binding-claim check (plan 4 Task A8, gap 3). A sentence that states a currency amount, a percentage, a duration,
 * a plan name or a refund / billing / legal term is a claim the business is held to. It survives only if its numbers and its plan name
 * come from a typed source (`BindingSource.values`) or from this turn's store-data / typed-source tool results; otherwise the sentence
 * is replaced by a pointer to the page that owns the fact. The model is never trusted to remember a price, a fee or a policy.
 */
import { foldArabic } from '../../text';
import type { BindingSource } from '../types';

export type ClaimReason = 'amount' | 'percent' | 'duration' | 'plan_name' | 'policy_term';

const NUM = /(?<![A-Za-z\d.,])\d+(?:[.,]\d+)*(?![A-Za-z]|\d)/g;
const CURRENCY = '(?:جنيه|جنية|ج\\.?\\s?م|egp|le\\b|l\\.e|usd|\\$|دولار|kwd|دينار|ريال|sar|aed|درهم)';
const AMOUNT = new RegExp(`(?<![A-Za-z\\d.,])(\\d+(?:[.,]\\d+)*)\\s*${CURRENCY}|${CURRENCY}\\s*(\\d+(?:[.,]\\d+)*)`, 'giu');
const PERCENT = /(?<![A-Za-z\d.,])(\d+(?:[.,]\d+)*)\s*(?:%|٪|percent|في\s*ال?ميه|بال?ميه)/giu;
const DURATION = /(?<![A-Za-z\d.,])(\d+(?:[.,]\d+)*)\s*(?:يوم|ايام|اسبوع|اسابيع|شهر|شهور|اشهر|ساعه|ساعات|سنه|سنين|days?|weeks?|months?|hours?|years?)/giu;
const LEGAL = /استرجاع|ترجع\w*\s*(?:ال)?فلوس|ارجاع|مرتجع|استرداد|الغاء|ضمان|سياسه|شروط|خصوصيه|refund|cancell?ation|guarantee|warranty|terms|privacy/iu;
// Billing terms with a bad number are reported as the specific number reason (amount / percent / duration); only an unsourced assertion is policy_term.
const BILLING = /رسوم|عموله|فاتوره|تجديد|billing|invoice|renewal|commission|\bfees?\b/iu;
const ASSERTIVE = /تقدر|هتقدر|ينفع|مفيش|ممنوع|مسموح|مضمون|هنرجع|هترجع|بنرجع|you can|you will|no fee|guarantee|full refund|always|never|free of charge/iu;
const PLAN_NAME = /(?:باقه|باقة|خطه|خطة|plan)\s+([A-Z][A-Za-z]+)|\b(Starter|Growth|Business|Pro|Premium|Enterprise|Scale|Basic)\b/g;

const POINTER = {
  plans: { ar: 'شوف التفاصيل في صفحة الباقات.', en: 'See the Plans page for the details.' },
  terms: { ar: 'شوف التفاصيل في صفحة الشروط والسياسات.', en: 'See the Terms and Policies page for the details.' },
};

const canon = (n: string): string => {
  const t = n.replace(/,(?=\d{3}(?:\D|$))/g, '').replace(',', '.');
  const f = Number(t);
  return Number.isFinite(f) ? String(f) : t;
};
const numbersOf = (s: string): Set<string> => new Set([...foldArabic(s).matchAll(NUM)].map((m) => canon(m[0])));
const names = (s: BindingSource): string[] => [s.key, s.text.ar, s.text.en, ...s.values].map((x) => foldArabic(x));

function sentences(reply: string): string[] {
  const protectedText = reply.replace(/(\d)\.(\d)/g, '$1\u0001$2');
  return protectedText.split(/(?<=[.!?؟]+)(?=\s)|(?<=\n)/).map((p) => p.replace(/\u0001/g, '.'));
}
const isArabic = (s: string): boolean => /[؀-ۿ]/.test(s);

export function checkBindingClaims(reply: string, sources: BindingSource[], toolFacts: string[]): { text: string; removed: Array<{ sentence: string; reason: ClaimReason }> } {
  const supported = new Set<string>();
  for (const s of sources) for (const v of s.values) for (const n of numbersOf(v)) supported.add(n);
  for (const f of toolFacts) for (const n of numbersOf(f)) supported.add(n);
  const planNames = sources.filter((s) => s.kind === 'plan').flatMap(names);
  const hasLegal = sources.some((s) => s.kind === 'legal' || s.kind === 'billing');
  const removed: Array<{ sentence: string; reason: ClaimReason }> = [];

  const out = sentences(reply).map((raw) => {
    const sentence = raw.trim();
    if (!sentence) return raw;
    const f = foldArabic(sentence);
    const unsupported = (re: RegExp): boolean => [...f.matchAll(re)].some((m) => !supported.has(canon((m[1] ?? m[2])!)));
    let reason: ClaimReason | null = null;
    const numeric = unsupported(AMOUNT) || unsupported(PERCENT) || unsupported(DURATION);
    const unsourcedAssertion = ASSERTIVE.test(f) && !hasLegal;
    if (LEGAL.test(f) && (numeric || unsourcedAssertion)) reason = 'policy_term';
    else if (BILLING.test(f) && !numeric && unsourcedAssertion) reason = 'policy_term';
    if (!reason) {
      for (const m of sentence.matchAll(PLAN_NAME)) {
        const name = foldArabic((m[1] ?? m[2])!);
        if (!planNames.some((p) => p === name || p.includes(name))) { reason = 'plan_name'; break; }
      }
    }
    if (!reason && unsupported(AMOUNT)) reason = 'amount';
    if (!reason && unsupported(PERCENT)) reason = 'percent';
    if (!reason && unsupported(DURATION)) reason = 'duration';
    if (!reason) return raw;
    removed.push({ sentence, reason });
    const kind = reason === 'policy_term' || reason === 'duration' ? 'terms' : 'plans';
    const pointer = POINTER[kind][isArabic(sentence) ? 'ar' : 'en'];
    return raw.replace(sentence, pointer);
  });
  return { text: out.join(''), removed };
}
