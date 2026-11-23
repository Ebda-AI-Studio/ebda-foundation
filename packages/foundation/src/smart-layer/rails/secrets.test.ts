import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { detectSecrets } from './secrets';

const raw = JSON.parse(readFileSync(new URL('../../../../../vectors/smart-layer-secrets.json', import.meta.url), 'utf8')) as { tokens: Record<string, string[]>; cases: Array<{ in: string; out: string; found: string[] }> };
// The fake credentials are stored split so no secret-shaped literal is committed; join them at run time.
const fill = (s: string): string => s.replace(/\{\{(\w+)\}\}/g, (_m, k: string) => raw.tokens[k]!.join(''));
const v = { cases: raw.cases.map((c) => ({ ...c, in: fill(c.in), out: fill(c.out) })) };

describe('detectSecrets', () => {
  for (const c of v.cases) it(`vector: ${JSON.stringify(c.in).slice(0, 60)}`, () => {
    const r = detectSecrets(c.in);
    expect(r.text).toBe(c.out);
    expect(r.found).toEqual(c.found);
  });
  it('is idempotent on its own output', () => {
    const once = detectSecrets(`password: hunter2 ${fill('{{meta}}')}`).text;
    expect(detectSecrets(once).text).toBe(once);
  });
  it('a Luhn-invalid 16 digit run is not a card', () => {
    expect(detectSecrets('1234567812345678').found).toEqual([]);
  });
});
