import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { detectSecrets } from './secrets';

const v = JSON.parse(readFileSync(new URL('../../../../../vectors/smart-layer-secrets.json', import.meta.url), 'utf8')) as { cases: Array<{ in: string; out: string; found: string[] }> };

describe('detectSecrets', () => {
  for (const c of v.cases) it(`vector: ${JSON.stringify(c.in).slice(0, 60)}`, () => {
    const r = detectSecrets(c.in);
    expect(r.text).toBe(c.out);
    expect(r.found).toEqual(c.found);
  });
  it('is idempotent on its own output', () => {
    const once = detectSecrets('password: hunter2 EAAGm0PX4ZCpsBO1234567890abcdefghijKLMN').text;
    expect(detectSecrets(once).text).toBe(once);
  });
  it('a Luhn-invalid 16 digit run is not a card', () => {
    expect(detectSecrets('1234567812345678').found).toEqual([]);
  });
});
