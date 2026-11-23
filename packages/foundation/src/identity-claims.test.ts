import { describe, expect, it } from 'vitest';
import { IdentityError, claimAt, claimStrings, isIdToken, mapRole } from './identity-claims';

describe('identity claims', () => {
  it('claimAt walks dotted paths and stops at non-objects', () => {
    expect(claimAt({ a: { b: 'x' } }, 'a.b')).toBe('x');
    expect(claimAt({ a: 'x' }, 'a.b')).toBeUndefined();
    expect(claimAt({ a: null }, 'a.b')).toBeUndefined();
  });
  it('claimStrings accepts a string or a list and drops non-strings', () => {
    expect(claimStrings('a')).toEqual(['a']);
    expect(claimStrings(['a', 1, 'b'])).toEqual(['a', 'b']);
    expect(claimStrings(5)).toEqual([]);
  });
  it('owner wins over staff; unmapped is null', () => {
    const r = { owner: ['admin'], staff: ['agent'] };
    expect(mapRole(['agent', 'admin'], r)).toBe('owner');
    expect(mapRole(['agent'], r)).toBe('staff');
    expect(mapRole(['guest'], r)).toBeNull();
  });
  it('an id token is detected by nonce / at_hash', () => {
    expect(isIdToken({ nonce: 'n' })).toBe(true);
    expect(isIdToken({ at_hash: 'h' })).toBe(true);
    expect(isIdToken({ sub: 'u' })).toBe(false);
  });
  it('IdentityError carries the status', () => expect(new IdentityError(401, 'x').status).toBe(401));
});
