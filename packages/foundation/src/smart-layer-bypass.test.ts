import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { checkModelBypass, MODEL_CALL_PATTERNS } from './smart-layer-bypass';

const cfg = { smartLayerPaths: ['src/smart-layer/'] };
const run = (path: string, src: string) => checkModelBypass([{ path, src }], cfg);

describe('checkModelBypass', () => {
  it('env.AI.run( outside the smart layer is one violation', () => {
    const v = run('src/a.ts', 'const r = await env.AI.run(model, input);');
    expect(v).toHaveLength(1);
    expect(v[0]!.rule).toBe('model-call-outside-smart-layer');
  });
  it('the same text in a // comment yields none', () => expect(run('src/a.ts', '// env.AI.run(x)\n/* api.openai.com */')).toEqual([]));
  it('the same text under a smartLayerPaths prefix yields none', () => expect(run('src/smart-layer/engine.ts', 'env.AI.run(x)')).toEqual([]));
  it('test files and .d.ts are skipped', () => {
    expect(run('src/a.test.ts', 'env.AI.run(x)')).toEqual([]);
    expect(run('src/types.d.ts', 'env.AI.run(x)')).toEqual([]);
  });
  it('two identical lines in one file yield two distinct keys', () => {
    const v = run('src/a.ts', 'env.AI.run(x)\nenv.AI.run(x)');
    expect(new Set(v.map((x) => x.key)).size).toBe(2);
  });
  it('moving the line down 40 lines leaves the key unchanged', () => {
    const a = run('src/a.ts', 'env.AI.run(x)');
    const b = run('src/a.ts', `${'\n'.repeat(40)}env.AI.run(x)`);
    expect(b.map((x) => x.key)).toEqual(a.map((x) => x.key));
  });
  it('editing the offending line changes its key (a different call is a different id)', () => {
    expect(run('src/a.ts', 'env.AI.run(x)')[0]!.key).not.toBe(run('src/a.ts', 'env.AI.run(y)')[0]!.key);
  });
  it('wrangler.jsonc with an ai binding is one violation', () => {
    expect(run('wrangler.jsonc', '{\n  "ai": { "binding": "AI" }\n}')).toHaveLength(1);
    expect(run('src/a.ts', '"ai": { "binding": "AI" }')).toEqual([]);
  });
  it.each([
    ["import { GoogleGenAI } from '@google/genai';"],
    ["import x from '@google/generative-ai';"],
    ["fetch('https://generativelanguage.googleapis.com/v1/models')"],
    ["fetch('https://api.openai.com/v1/chat')"],
    ["fetch('https://api.anthropic.com/v1/messages')"],
    ["import Anthropic from '@anthropic-ai/sdk';"],
    ["import OpenAI from 'openai';"],
  ])('flags %s', (src) => expect(run('src/a.ts', src)).toHaveLength(1));
  it('the guard source does not flag itself (it is vendored into products)', () => {
    const src = readFileSync(new URL('./smart-layer-bypass.ts', import.meta.url), 'utf8');
    expect(run('src/foundation/smart-layer-bypass.ts', src)).toEqual([]);
    expect(MODEL_CALL_PATTERNS.length).toBeGreaterThan(5);
  });
});
