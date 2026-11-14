import { describe, expect, it } from 'vitest';
import { BUDGET } from './plan/budget';
import { DEFAULT_MODELS } from './models';
import { PROMPT_VERSION, buildSystemPrompt, canonicalJson, computeReleaseId, sha256Hex } from './release';

const parts = () => ({ systemPrompt: 'p', tools: [{ name: 't', description: 'd', policy: 'free' as const, undo: 'none' as const }], models: DEFAULT_MODELS, budget: BUDGET });

describe('release', () => {
  it('release id is 12 hex and stable for the same parts', async () => {
    const a = await computeReleaseId(parts());
    expect(a).toMatch(/^[0-9a-f]{12}$/);
    expect(await computeReleaseId(parts())).toBe(a);
  });
  it('changes when a tool description, policy, model, budget or the prompt changes', async () => {
    const a = await computeReleaseId(parts());
    const p1 = parts(); p1.tools[0]!.description = 'd2';
    const p2 = parts(); p2.tools[0]!.policy = 'preview' as never;
    const p3 = parts(); p3.models = { ...DEFAULT_MODELS, answer: '@cf/other/model' };
    const p4 = parts(); p4.budget = { ...BUDGET, toolCalls: 5 } as never;
    const p5 = parts(); p5.systemPrompt = 'p2';
    for (const p of [p1, p2, p3, p4, p5]) expect(await computeReleaseId(p)).not.toBe(a);
  });
  it('is independent of key order and tool order is significant only by content', async () => {
    expect(canonicalJson({ b: 1, a: { d: 1, c: 2 } })).toBe(canonicalJson({ a: { c: 2, d: 1 }, b: 1 }));
  });
  it('sha256Hex matches the known vector', async () => {
    expect(await sha256Hex('abc')).toBe('ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
  });
  it('the system prompt carries the fence rule, the secrets rule, markers and a version, per locale', () => {
    for (const l of ['ar', 'en'] as const) {
      const s = buildSystemPrompt(l);
      expect(s).toContain('<untrusted>');
      expect(s).toContain('[[cap:');
      expect(s).toContain('[[help:');
      expect(s).toMatch(/password|كلمة السر/);
      expect(s).toContain(PROMPT_VERSION);
    }
    expect(buildSystemPrompt('ar')).toMatch(/[؀-ۿ]/);
  });
});
