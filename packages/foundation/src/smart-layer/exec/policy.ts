/**
 * Execution rail 8: policy gate with big-change triggers (plan 4 Task B2, spec 4). A `preview` tool escalates to `confirm` when the
 * built preview says so: more than 20 affected items, anything visible at checkout, any price change, money / deletion / customer
 * messaging, an irreversible undo class. The engine trusts ONLY `draft.affectedCount` (computed by the adapter from real rows, with
 * Arabic-Indic digits folded), never a number in model text. A free tool never gets here; `forbidden` capabilities have no tool.
 */
import type { PreviewDraft, ToolSpec } from '../types';

export const BULK_THRESHOLD = 20;
export type PolicyReason = 'money' | 'delete' | 'customer_message' | 'bulk' | 'checkout' | 'price' | 'irreversible' | 'declared';

export function effectivePolicy(tool: ToolSpec, draft: PreviewDraft, o: { bulkThreshold?: number } = {}): { policy: 'preview' | 'confirm'; reasons: PolicyReason[] } {
  if ((tool.policy as string) === 'free' || (tool.policy as string) === 'forbidden') throw new Error(`effectivePolicy: ${tool.name} is ${tool.policy}, it has no preview/confirm gate`);
  const limit = o.bulkThreshold ?? BULK_THRESHOLD;
  const reasons: PolicyReason[] = [];
  if (tool.policy === 'confirm') reasons.push('declared');
  if (tool.money) reasons.push('money');
  if (tool.deletes) reasons.push('delete');
  if (tool.messagesCustomers) reasons.push('customer_message');
  // A count that is not a non-negative integer is a bug upstream: fail toward the stronger gate.
  const n = draft.affectedCount;
  if (!Number.isInteger(n) || n < 0 || n > limit) reasons.push('bulk');
  if (draft.touchesCheckout) reasons.push('checkout');
  if (draft.changesPrice) reasons.push('price');
  if (tool.undo === 'irreversible') reasons.push('irreversible');
  const order: PolicyReason[] = ['declared', 'money', 'delete', 'customer_message', 'bulk', 'checkout', 'price', 'irreversible'];
  reasons.sort((a, b) => order.indexOf(a) - order.indexOf(b));
  return { policy: reasons.length ? 'confirm' : 'preview', reasons };
}
