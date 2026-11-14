// InstaPay auto-confirm lifecycle (money path). Pure helpers only: storage and side effects stay in each product.
export type AutoState = 'pending_decision' | 'auto_confirmed' | 'needs_human' | 'reverted' | 'failed';
export type AutoEvent = 'decide_auto' | 'decide_human' | 'revert' | 'activation_failed';

const TABLE: Record<AutoState, Partial<Record<AutoEvent, AutoState>>> = {
  pending_decision: { decide_auto: 'auto_confirmed', decide_human: 'needs_human', activation_failed: 'failed' },
  auto_confirmed: { revert: 'reverted' },
  reverted: { revert: 'reverted' }, // a replayed tap is a no-op, not an error
  needs_human: {},
  failed: {},
};

export function nextAutoState(s: AutoState, e: AutoEvent): AutoState | 'illegal' {
  return TABLE[s]?.[e] ?? 'illegal';
}

export function autoConfirmKey(product: 'store' | 'chat', receiptOrRequestId: string): string {
  return `instapay-auto:${product}:${receiptOrRequestId}`;
}
/** idempotency key of the credit-removal ledger entry written by a revert (one removal per payment, however many taps) */
export function revertKey(product: 'store' | 'chat', receiptOrRequestId: string): string {
  return `instapay-revert:${product}:${receiptOrRequestId}`;
}

export const REVERT_GRACE_MS = 48 * 3600_000;
export function revertGraceUntil(now: number): number {
  return now + REVERT_GRACE_MS;
}

/** First auto-confirmed payment is capped at ONE month of the chosen plan (Chat top-up: the Chat plan's monthly price). No plan price -> 0 -> always human. */
export function firstPaymentCapMinor(a: { monthlyPriceMinor: number | null }): number {
  const p = a?.monthlyPriceMinor;
  return typeof p === 'number' && Number.isSafeInteger(p) && p > 0 ? p : 0;
}

export const CLEAN_AFTER_MS = 24 * 3600_000;
/** Human-confirmed: clean at once unless reverted. Auto-confirmed: clean only after 24 h without a revert (two fast uploads cannot skip the cap). */
export function isCleanPayment(p: { confirmedBy: 'human' | 'auto'; confirmedAt: number; revertedAt: number | null }, now: number): boolean {
  if (p.revertedAt !== null) return false;
  if (p.confirmedBy === 'human') return true;
  if (p.confirmedBy !== 'auto') return false;
  return now - p.confirmedAt >= CLEAN_AFTER_MS;
}

/** Credits a revert removes for ONE payment (top-up and package credits alike): what that payment granted and nobody consumed, never more than
 *  the balance, never negative; consumed credits are not clawed back. Any invalid number -> 0 (leave it for the human). */
export function unusedCreditsToRemove(c: { granted: number; consumed: number; balance: number }): number {
  const ok = (n: number) => Number.isSafeInteger(n) && n >= 0;
  if (!ok(c.granted) || !ok(c.consumed) || !ok(c.balance)) return 0;
  return Math.max(0, Math.min(c.granted - c.consumed, c.balance));
}
