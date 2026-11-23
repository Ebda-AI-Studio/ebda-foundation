import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { parsePrompts } from './schema';

const dir = new URL('.', import.meta.url);
const prompts = parsePrompts(readFileSync(new URL('prompts.jsonl', dir), 'utf8'));
const tools: Array<{ name: string; description: string; policy: string }> = JSON.parse(readFileSync(new URL('tools.fixture.json', dir), 'utf8'));
const count = (f: (p: (typeof prompts)[number]) => string) => prompts.reduce<Record<string, number>>((a, p) => ((a[f(p)] = (a[f(p)] ?? 0) + 1), a), {});

describe('bake-off prompt set', () => {
  it('the set has exactly 150 prompts with unique ids', () => {
    expect(prompts).toHaveLength(150);
    expect(new Set(prompts.map((p) => p.id)).size).toBe(150);
  });
  it('language split is 60 ar-EG / 45 franco / 45 en', () => {
    expect(count((p) => p.lang)).toEqual({ 'ar-EG': 60, franco: 45, en: 45 });
  });
  it('job split is 70 answer / 45 plan / 15 template / 20 safety', () => {
    expect(count((p) => p.job)).toEqual({ answer: 70, plan: 45, template: 15, safety: 20 });
  });
  it('every plan prompt names tools that exist in tools.fixture.json', () => {
    const names = new Set(tools.map((t) => t.name));
    const plans = prompts.filter((p) => p.job === 'plan');
    expect(plans.length).toBe(45);
    for (const p of plans) {
      expect(p.expect.tools?.length ?? 0).toBeGreaterThan(0);
      for (const t of p.expect.tools ?? []) expect(names.has(t.name), `${p.id} -> ${t.name}`).toBe(true);
    }
  });
  it('every safety prompt sets mustRefuse or mustConfirm', () => {
    for (const p of prompts.filter((p) => p.job === 'safety')) expect(p.expect.mustRefuse || p.expect.mustConfirm, p.id).toBe(true);
  });
  it('the tool fixture has 15 tools with descriptions of at most 512 chars', () => {
    expect(tools).toHaveLength(15);
    for (const t of tools) expect(t.description.length).toBeLessThanOrEqual(512);
  });
  it('has Arabic-Indic digits in at least 15 rows and typos in at least 10', () => {
    expect(prompts.filter((p) => /[٠-٩]/.test(p.text)).length).toBeGreaterThanOrEqual(15);
    expect(prompts.filter((p) => p.tags?.includes('typo')).length).toBeGreaterThanOrEqual(10);
  });
  it('every confirm-policy tool expected on a plan row sets mustConfirm', () => {
    const confirm = new Set(tools.filter((t) => t.policy === 'confirm').map((t) => t.name));
    for (const p of prompts.filter((p) => p.job === 'plan' && p.expect.tools?.some((t) => confirm.has(t.name)))) expect(p.expect.mustConfirm, p.id).toBe(true);
  });
  it('parsePrompts reports the line number of a malformed row', () => {
    expect(() => parsePrompts('{"id":"a"}\nnot json')).toThrow(/line 1|line 2/);
    expect(() => parsePrompts('{"id":"a","lang":"en","job":"plan","text":"x","expect":{}}\nnot json')).toThrow(/line 2/);
  });
});
