import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { BRAND } from '../brand';
import { TOKENS, isOrange } from './index';

const css = readFileSync(new URL('./tokens.css', import.meta.url), 'utf8');
const cssColors = [...css.matchAll(/--ebda-([a-z0-9-]+):\s*(#[0-9a-fA-F]{6})/g)];

describe('tokens', () => {
  it('has no orange hue anywhere, in the css or the ts', () => {
    expect(cssColors.length).toBeGreaterThan(5);
    for (const [, name, hex] of cssColors) expect(isOrange(hex!), `${name} ${hex}`).toBe(false);
    for (const hex of Object.values(TOKENS.color)) expect(isOrange(hex)).toBe(false);
  });
  it('the detector does flag orange', () => {
    expect(isOrange('#ff6e01')).toBe(true);
  });
  it('css and ts agree, and match the brand colours', () => {
    const camel = (s: string) => s.replace(/-(\w)/g, (_, c: string) => c.toUpperCase());
    for (const [, name, hex] of cssColors) {
      const key = camel(name!.replace('metal-', 'metal')) as keyof typeof TOKENS.color;
      expect(TOKENS.color[key]?.toLowerCase(), name).toBe(hex!.toLowerCase());
    }
    expect(TOKENS.color.night).toBe(BRAND.colors.night);
    expect(TOKENS.color.gold).toBe(BRAND.colors.gold);
    expect(TOKENS.color.lift).toBe(BRAND.colors.lift);
  });
});
