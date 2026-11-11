import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { EBDA } from './brand';
import { CONTROL, FONT, MOTION, RADIUS, TOKENS, TYPE, isOrange } from './tokens';

const css = readFileSync(new URL('./tokens.css', import.meta.url), 'utf8');
const cssVar = (name: string) => new RegExp(`--ebda-${name}:\\s*(#[0-9A-Fa-f]{6})`).exec(css)?.[1];

describe('tokens', () => {
  it('tokens.css equals tokens.ts and the brand colours', () => {
    expect(cssVar('night')).toBe(TOKENS.night);
    expect(cssVar('gold')).toBe(TOKENS.gold);
    expect(cssVar('lift')).toBe(TOKENS.lift);
    expect(cssVar('cream')).toBe(TOKENS.cream);
    expect(EBDA.colors).toEqual({
      night: TOKENS.night,
      gold: TOKENS.gold,
      lift: TOKENS.lift,
    });
  });
  it('no orange hue in any colour token', () => {
    for (const hex of css.match(/#[0-9A-Fa-f]{6}/g) ?? []) expect(isOrange(hex), hex).toBe(false);
    for (const hex of Object.values(TOKENS).filter((v) => v.startsWith('#'))) expect(isOrange(hex)).toBe(false);
  });
  it('the orange detector detects orange', () => {
    expect(isOrange('#FF6E01')).toBe(true);
  });
  it('design language v1: the CSS variables equal the TS tokens and the font is one family', () => {
    const px = (name: string) => Number(new RegExp(`--ebda-${name}:\\s*(\\d+)(?:px|ms)`).exec(css)?.[1]);
    expect(px('text-caption')).toBe(TYPE.caption.px);
    expect(px('text-ui')).toBe(TYPE.ui.px);
    expect(px('text-body')).toBe(TYPE.body.px);
    expect(px('text-title-sm')).toBe(TYPE.titleSm.px);
    expect(px('text-title')).toBe(TYPE.title.px);
    expect(px('text-kpi')).toBe(TYPE.kpi.px);
    expect(px('text-display')).toBe(TYPE.display.px);
    expect(px('radius-control')).toBe(RADIUS.control);
    expect(px('radius-surface')).toBe(RADIUS.surface);
    expect(px('control-sm')).toBe(CONTROL.sm);
    expect(px('control-md')).toBe(CONTROL.md);
    expect(px('control-lg')).toBe(CONTROL.lg);
    expect(px('dur-fast')).toBe(MOTION.fast);
    expect(css).toContain(`--ebda-font-ui: ${FONT.stack};`);
    expect(css).toContain('--ebda-font-headline: var(--ebda-font-ui);');
    expect(css).not.toMatch(/Playfair|Inter\b/);
  });
  it('Arabic leading is at least 1.6x the size at body sizes and Latin leading never beats it', () => {
    for (const t of Object.values(TYPE)) expect(t.leading[1]).toBeGreaterThanOrEqual(t.leading[0]);
    for (const k of ['ui', 'body'] as const) expect(TYPE[k].leading[1] / TYPE[k].px).toBeGreaterThanOrEqual(1.7);
  });
});
