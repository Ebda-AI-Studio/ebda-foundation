import { describe, expect, it } from 'vitest';
import { canExecute, resolveControls } from './controls';
import type { SchemaLike, ToolSpec } from './types';

const any: SchemaLike<unknown> = { safeParse: (x) => ({ success: true, data: x }) };
const tool = (name: string, policy: ToolSpec['policy']): ToolSpec => ({ name, capabilityId: 'x.y', description: '', args: any, jsonSchema: {}, policy, undo: 'none', resultTrust: 'store-data' });

describe('resolveControls', () => {
  it('no store flag means off', () => expect(resolveControls({}).mode).toBe('off'));
  it('store flag applies when nothing else is set', () => expect(resolveControls({ storeFlag: 'suggest' }).mode).toBe('suggest'));
  it('global kill beats store act', () => {
    const c = resolveControls({ storeFlag: 'act', global: { kill: true } });
    expect(c.mode).toBe('off');
    expect(c.killGlobal).toBe(true);
  });
  it('product kill beats store act', () => {
    const c = resolveControls({ storeFlag: 'act', product: { kill: true } });
    expect(c.mode).toBe('off');
    expect(c.killProduct).toBe(true);
  });
  it('a global mode caps the store flag', () => {
    expect(resolveControls({ storeFlag: 'act', global: { mode: 'answer-only' } }).mode).toBe('answer-only');
    expect(resolveControls({ storeFlag: 'answer-only', global: { mode: 'act' } }).mode).toBe('answer-only');
  });
  it('shadow forces suggest-style behaviour', () => {
    const c = resolveControls({ storeFlag: 'act', shadow: true });
    expect(c.mode).toBe('suggest');
    expect(c.shadow).toBe(true);
  });
  it('an unknown mode string from storage falls back to off', () => {
    expect(resolveControls({ storeFlag: 'turbo' as never }).mode).toBe('off');
  });
});

describe('canExecute', () => {
  it('killed tool returns killed while others run', () => {
    const c = resolveControls({ storeFlag: 'act', killedTools: ['bad'] });
    expect(canExecute(c, tool('bad', 'preview'))).toBe('killed');
    expect(canExecute(c, tool('good', 'preview'))).toBe('ok');
  });
  it('suggest mode refuses apply with mode but allows preview and free reads', () => {
    const c = resolveControls({ storeFlag: 'suggest' });
    expect(canExecute(c, tool('t', 'preview'))).toBe('mode');
    expect(canExecute(c, tool('t', 'preview'), 'preview')).toBe('ok');
    expect(canExecute(c, tool('r', 'free'))).toBe('ok');
  });
  it('answer-only allows free tools only; off allows nothing', () => {
    const a = resolveControls({ storeFlag: 'answer-only' });
    expect(canExecute(a, tool('r', 'free'))).toBe('ok');
    expect(canExecute(a, tool('t', 'preview'), 'preview')).toBe('mode');
    expect(canExecute(resolveControls({}), tool('r', 'free'))).toBe('mode');
  });
  it('a kill switch wins over free tools too', () => {
    expect(canExecute(resolveControls({ storeFlag: 'act', global: { kill: true } }), tool('r', 'free'))).toBe('killed');
  });
});
