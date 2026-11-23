import { describe, expect, it, vi } from 'vitest';
import { validateCall } from './validate';
import type { RefCheck, SchemaLike, SmartLayerAdapter, ToolSpec, TurnCtx } from '../types';

const ctx: TurnCtx = { product: 'store', storeId: 's1', userId: 'u1', role: 'owner', locale: 'ar', now: 0, conversationId: 'c', releaseId: 'r' };
type Args = { productId: string; mode: 'percent' | 'fixed'; qty: number };
// A Zod-shaped schema without Zod: enum + coercion, like the adapters' real ones.
const schema: SchemaLike<Args> = {
  safeParse(x) {
    const o = x as Record<string, unknown>;
    const issues: Array<{ path: PropertyKey[]; message: string }> = [];
    if (typeof o?.productId !== 'string') issues.push({ path: ['productId'], message: 'Required' });
    if (o?.mode !== 'percent' && o?.mode !== 'fixed') issues.push({ path: ['mode'], message: `Invalid enum value ${String(o?.mode)}` });
    const qty = Number(o?.qty);
    if (!Number.isFinite(qty)) issues.push({ path: ['qty'], message: 'Expected number' });
    return issues.length ? { success: false, error: { issues } } : { success: true, data: { productId: o.productId as string, mode: o.mode as Args['mode'], qty } };
  },
};
const tool: ToolSpec<Args> = { name: 'set_discount', capabilityId: 'x.y', description: '', args: schema, jsonSchema: {}, policy: 'preview', undo: 'reversible', resultTrust: 'store-data', refs: (a) => [{ kind: 'product', id: a.productId }] };
const adapter = (missing: RefCheck[] = []) => ({ checkRefs: vi.fn(async () => ({ missing })) }) as unknown as SmartLayerAdapter & { checkRefs: ReturnType<typeof vi.fn> };

describe('validateCall', () => {
  it('wrong enum → invalid_args with the path, never the value', async () => {
    const r = await validateCall(adapter(), ctx, tool as ToolSpec, { productId: 'p1', mode: 'SECRET-VALUE', qty: 1 });
    expect(r).toMatchObject({ ok: false, error: 'invalid_args' });
    if (!r.ok) { expect(r.detail).toContain('mode'); expect(r.detail).not.toContain('SECRET-VALUE'); }
  });
  it('hallucinated product id → unknown_ref, and the adapter was asked about exactly that ref', async () => {
    const a = adapter([{ kind: 'product', id: 'p-ghost' }]);
    const r = await validateCall(a, ctx, tool as ToolSpec, { productId: 'p-ghost', mode: 'fixed', qty: 1 });
    expect(r).toMatchObject({ ok: false, error: 'unknown_ref' });
    expect(a.checkRefs).toHaveBeenCalledWith(ctx, [{ kind: 'product', id: 'p-ghost' }]);
    if (!r.ok) expect(r.detail).not.toContain('p-ghost');
  });
  it('valid args pass through parsed (coerced) values', async () => {
    const r = await validateCall(adapter(), ctx, tool as ToolSpec, { productId: 'p1', mode: 'percent', qty: '5' });
    expect(r).toEqual({ ok: true, args: { productId: 'p1', mode: 'percent', qty: 5 } });
  });
  it('refs are checked on the PARSED args, not the raw ones', async () => {
    const a = adapter();
    await validateCall(a, ctx, tool as ToolSpec, { productId: 'p1', mode: 'fixed', qty: 1, productIdEvil: 'x' });
    expect(a.checkRefs).toHaveBeenCalledWith(ctx, [{ kind: 'product', id: 'p1' }]);
  });
  it('a tool without refs does not call the adapter', async () => {
    const a = adapter();
    const t = { ...tool, refs: undefined } as ToolSpec;
    expect((await validateCall(a, ctx, t, { productId: 'p', mode: 'fixed', qty: 1 })).ok).toBe(true);
    expect(a.checkRefs).not.toHaveBeenCalled();
  });
  it('fails closed when the existence check throws', async () => {
    const a = { checkRefs: vi.fn(async () => { throw new Error('db down'); }) } as unknown as SmartLayerAdapter;
    const r = await validateCall(a, ctx, tool as ToolSpec, { productId: 'p', mode: 'fixed', qty: 1 });
    expect(r).toMatchObject({ ok: false, error: 'unknown_ref' });
  });
  it('a model that names 500 ids is refused before any lookup', async () => {
    const a = adapter();
    const t = { ...tool, refs: () => Array.from({ length: 500 }, (_, i) => ({ kind: 'product', id: String(i) })) } as ToolSpec;
    expect(await validateCall(a, ctx, t, { productId: 'p', mode: 'fixed', qty: 1 })).toMatchObject({ ok: false, error: 'invalid_args' });
    expect(a.checkRefs).not.toHaveBeenCalled();
  });
  it('a throwing refs() is invalid_args, not an exception', async () => {
    const t = { ...tool, refs: () => { throw new Error('x'); } } as ToolSpec;
    expect(await validateCall(adapter(), ctx, t, { productId: 'p', mode: 'fixed', qty: 1 })).toMatchObject({ ok: false, error: 'invalid_args' });
  });
});
