import { describe, expect, it } from 'vitest';
import { fakeAdapter } from '../eval/fake-adapter';
import { APPROVAL_TTL_MS, confirmApproval, issueApproval, rejectApproval } from './approval';
import { createPreviewRecord } from './journal';

async function pending(f = fakeAdapter(), productId = 'p2') {
  const ctx = f.ctx();
  const { record } = await createPreviewRecord(f.adapter, ctx, f.tool('delete_product'), { productId }, 't1');
  const { approvalId, token } = await issueApproval(f.adapter, ctx, record);
  return { f, ctx, record, approvalId, token };
}

describe('issueApproval', () => {
  it('issues a 32-byte base64url token and stores only its hash, bound to the payload hash, expiring in 15 minutes', async () => {
    const { f, ctx, record, approvalId, token } = await pending();
    expect(token).toMatch(/^[A-Za-z0-9_-]{43}$/);
    const rec = (await f.storage.getApproval('s1', approvalId))!;
    expect(rec).toMatchObject({ previewId: record.id, payloadHash: record.payloadHash, status: 'pending', userId: 'u1', expiresAt: ctx.now + APPROVAL_TTL_MS });
    expect(JSON.stringify([...f.storage.approvals.values()])).not.toContain(token);
    expect(rec.tokenHash).toMatch(/^[0-9a-f]{64}$/);
  });
  it('two approvals never share a token', async () => {
    const a = await pending();
    const b = await pending(a.f, 'p1');
    expect(a.token).not.toBe(b.token);
  });
});

describe('confirmApproval', () => {
  it('applies once with the right token and records a confirmed decision', async () => {
    const { f, ctx, approvalId, token } = await pending();
    const r = await confirmApproval(f.adapter, ctx, approvalId, token);
    expect(r.status).toBe('applied');
    expect(f.state.products.has('p2')).toBe(false);
    expect(f.storage.decisions).toEqual([{ approvalId, storeId: 's1', decider: 'u1', decision: 'confirmed', at: ctx.now }]);
  });
  it('second claim returns used', async () => {
    const { f, ctx, approvalId, token } = await pending();
    await confirmApproval(f.adapter, ctx, approvalId, token);
    expect((await confirmApproval(f.adapter, ctx, approvalId, token)).status).toBe('used');
    expect(f.state.applied).toEqual(['delete:p2']);
  });
  it('two parallel confirm requests apply once', async () => {
    const { f, ctx, approvalId, token } = await pending();
    const rs = await Promise.all([confirmApproval(f.adapter, ctx, approvalId, token), confirmApproval(f.adapter, ctx, approvalId, token)]);
    expect(rs.map((r) => r.status).sort()).toEqual(['applied', 'used']);
    expect(f.state.applied).toEqual(['delete:p2']);
  });
  it('claim after 15 min returns expired and records an expired decision', async () => {
    const { f, ctx, approvalId, token } = await pending();
    const late = f.ctx({ now: ctx.now + APPROVAL_TTL_MS + 1 });
    expect((await confirmApproval(f.adapter, late, approvalId, token)).status).toBe('expired');
    expect(f.storage.decisions.map((d) => d.decision)).toEqual(['expired']);
    expect(f.state.products.has('p2')).toBe(true);
  });
  it('a wrong token is a mismatch and does not burn the real one', async () => {
    const { f, ctx, approvalId, token } = await pending();
    expect((await confirmApproval(f.adapter, ctx, approvalId, 'x'.repeat(43))).status).toBe('mismatch');
    expect((await confirmApproval(f.adapter, ctx, approvalId, token)).status).toBe('applied');
  });
  it('token for preview A cannot confirm preview B (mismatch)', async () => {
    const a = await pending();
    const b = await pending(a.f, 'p1');
    expect((await confirmApproval(a.f.adapter, a.ctx, b.approvalId, a.token)).status).toBe('mismatch');
    expect(a.f.state.products.size).toBe(2);
  });
  it('an unknown approval id is missing', async () => {
    const { f, ctx } = await pending();
    expect((await confirmApproval(f.adapter, ctx, 'nope', 'x')).status).toBe('missing');
  });
  it('payload changed between issue and confirm → stale with a new approval and a rejected:stale decision, nothing deleted', async () => {
    const { f, ctx, approvalId, token } = await pending();
    f.state.products.get('p2')!.price = 999; // the delete preview's etag includes the price
    const issued: Array<{ approvalId: string; token: string }> = [];
    const r = await confirmApproval(f.adapter, ctx, approvalId, token, { onApprovalToken: (t) => issued.push(t) });
    expect(r.status).toBe('stale');
    expect(f.state.products.has('p2')).toBe(true);
    expect(f.storage.decisions.map((d) => d.decision)).toEqual(['rejected:stale']);
    if (r.status !== 'stale') return;
    expect(r.card.approvalId).toBeTruthy();
    expect(r.card.approvalId).not.toBe(approvalId);
    expect(issued).toHaveLength(1);
    expect(issued[0]!.approvalId).toBe(r.card.approvalId);
    expect(JSON.stringify(r)).not.toContain(issued[0]!.token); // the token is delivered through the callback only
    // the fresh approval works
    expect((await confirmApproval(f.adapter, ctx, issued[0]!.approvalId, issued[0]!.token)).status).toBe('applied');
  });
  it('confirm after role downgrade is refused and logged rejected:permission', async () => {
    const { f, ctx, approvalId, token } = await pending();
    f.state.denyApply = true;
    expect((await confirmApproval(f.adapter, ctx, approvalId, token)).status).toBe('forbidden');
    expect(f.state.products.has('p2')).toBe(true);
    expect(f.storage.decisions.map((d) => d.decision)).toEqual(['rejected:permission']);
  });
  it('another user cannot confirm the card (forbidden, logged, token not burned)', async () => {
    const { f, ctx, approvalId, token } = await pending();
    expect((await confirmApproval(f.adapter, f.ctx({ userId: 'u2' }), approvalId, token)).status).toBe('forbidden');
    expect(f.storage.decisions.map((d) => [d.decision, d.decider])).toEqual([['rejected:permission', 'u2']]);
    expect((await confirmApproval(f.adapter, ctx, approvalId, token)).status).toBe('applied');
  });
  it('a kill switch stops the confirm without burning the token; clearing it lets the merchant confirm', async () => {
    const { f, ctx, approvalId, token } = await pending();
    f.controls.raw = { storeFlag: 'act', killedTools: ['delete_product'] };
    expect((await confirmApproval(f.adapter, ctx, approvalId, token)).status).toBe('killed');
    f.controls.raw = { storeFlag: 'act' };
    expect((await confirmApproval(f.adapter, ctx, approvalId, token)).status).toBe('applied');
  });
  it('suggest mode refuses to confirm', async () => {
    const { f, ctx, approvalId, token } = await pending();
    f.controls.raw = { storeFlag: 'suggest' };
    expect((await confirmApproval(f.adapter, ctx, approvalId, token)).status).toBe('mode');
  });
});

describe('rejectApproval', () => {
  it('rejects are recorded with the reason and the card can no longer be confirmed', async () => {
    const { f, ctx, approvalId, token } = await pending();
    expect(await rejectApproval(f.adapter, ctx, approvalId, 'غيرت رأيي')).toEqual({ status: 'rejected' });
    expect(f.storage.decisions).toEqual([{ approvalId, storeId: 's1', decider: 'u1', decision: 'rejected', reason: 'غيرت رأيي', at: ctx.now }]);
    expect((await confirmApproval(f.adapter, ctx, approvalId, token)).status).toBe('used');
    expect(f.state.products.has('p2')).toBe(true);
  });
  it('rejecting twice or an unknown id is reported, not thrown', async () => {
    const { f, ctx, approvalId } = await pending();
    await rejectApproval(f.adapter, ctx, approvalId);
    expect(await rejectApproval(f.adapter, ctx, approvalId)).toEqual({ status: 'not_pending' });
    expect(await rejectApproval(f.adapter, ctx, 'nope')).toEqual({ status: 'missing' });
  });
});
