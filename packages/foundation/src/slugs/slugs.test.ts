import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { RESERVED_SLUGS, isDemoShowroomSlug, isReservedSlug, slugFormatError } from './index';

const v = JSON.parse(readFileSync(new URL('../../../../vectors/slugs.json', import.meta.url), 'utf8'));

describe('slugs', () => {
  it('format vectors', () => {
    for (const c of v.format) expect(slugFormatError(c.in), c.in).toBe(c.error);
  });
  it('reserved + demo vectors', () => {
    for (const s of v.reserved.yes) expect(isReservedSlug(s), s).toBe(true);
    for (const s of v.reserved.no) expect(isReservedSlug(s), s).toBe(false);
    for (const s of v.demoShowroom.yes) expect(isDemoShowroomSlug(s), s).toBe(true);
    for (const s of v.demoShowroom.no) expect(isDemoShowroomSlug(s), s).toBe(false);
    expect(isReservedSlug(null)).toBe(false);
  });
  it('the list is lowercase and unique', () => {
    expect(new Set(RESERVED_SLUGS).size).toBe(RESERVED_SLUGS.length);
    for (const s of RESERVED_SLUGS) expect(s).toBe(s.toLowerCase());
  });
});
