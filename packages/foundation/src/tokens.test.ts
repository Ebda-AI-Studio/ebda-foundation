import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { EBDA } from './brand';
import { TOKENS, isOrange } from './tokens';

const css = readFileSync(new URL('./tokens.css', import.meta.url), 'utf8');
const cssVar = (name: string) => new RegExp(`--ebda-${name}:\\s*(#[0-9A-Fa-f]{6})`).exec(css)?.[1];

describe('tokens', () => {
  it('tokens.css equals tokens.ts and the brand colours', () => {
    expect(cssVar('night')).toBe(TOKENS.night);
    expect(cssVar('gold')).toBe(TOKENS.gold);
    expect(cssVar('lift')).toBe(TOKENS.lift);
    expect(cssVar('cream')).toBe(TOKENS.cream);
    expect(EBDA.colors).toEqual({ night: TOKENS.night, gold: TOKENS.gold, lift: TOKENS.lift });
  });
  it('no orange hue in any colour token', () => {
    for (const hex of css.match(/#[0-9A-Fa-f]{6}/g) ?? []) expect(isOrange(hex), hex).toBe(false);
    for (const hex of Object.values(TOKENS).filter((v) => v.startsWith('#'))) expect(isOrange(hex)).toBe(false);
  });
  it('the orange detector detects orange', () => {
    expect(isOrange('#FF6E01')).toBe(true);
  });
});
