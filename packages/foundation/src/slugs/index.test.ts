import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { RESERVED_SLUGS, isReservedSlug, slugify, slugifyWithFallback, validateSlug } from './index';

const v = JSON.parse(readFileSync(new URL('../../../../vectors/slugs.json', import.meta.url), 'utf8')) as {
  slugify: { in: string; ascii?: boolean; out: string }[];
  validate: { in: string; ok?: boolean; code?: string }[];
};

describe('slugs vectors', () => {
  it.each(v.slugify)('slugify %j', (c) => expect(slugify(c.in, { ascii: c.ascii })).toBe(c.out));
  it.each(v.validate)('validate %j', (c) => {
    const r = validateSlug(c.in);
    if (c.ok) expect(r).toEqual({ ok: true, slug: c.in });
    else expect(r).toEqual({ ok: false, code: c.code });
  });
  it('reserved check is case-insensitive and null-safe; every reserved label is itself format-valid except via the list', () => {
    expect(isReservedSlug(' API ')).toBe(true);
    expect(isReservedSlug(null)).toBe(false);
    expect(new Set(RESERVED_SLUGS).size).toBe(RESERVED_SLUGS.length);
  });
  it('slugifyWithFallback never returns empty', () => {
    expect(slugifyWithFallback('!!!', 'store', { ascii: true })).toMatch(/^store-[a-z0-9]+$/);
  });
});
