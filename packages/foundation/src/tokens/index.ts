/** TypeScript twin of tokens.css. The two are kept equal by tokens.test.ts. */
export const TOKENS = {
  color: {
    night: '#0A0B0C',
    gold: '#B08D57',
    lift: '#CBA873',
    cream: '#FAF8F3',
    metal900: '#141618',
    metal700: '#2A2D31',
    metal500: '#6B7078',
    metal300: '#A9AEB5',
    metal100: '#E3E5E8',
  },
  radius: { sm: '8px', md: '12px', lg: '20px', appIcon: '22.37%' },
  motion: { fast: '150ms', base: '240ms', ease: 'cubic-bezier(0.2, 0, 0, 1)' },
} as const;

/** HSL of a #RRGGBB colour: hue 0-360, saturation and lightness 0-1. */
export function hexToHsl(hex: string): { h: number; s: number; l: number } {
  const m = /^#([0-9a-f]{6})$/i.exec(hex);
  if (!m) throw new Error(`not a #RRGGBB colour: ${hex}`);
  const n = parseInt(m[1]!, 16);
  const r = ((n >> 16) & 255) / 255, g = ((n >> 8) & 255) / 255, b = (n & 255) / 255;
  const max = Math.max(r, g, b), min = Math.min(r, g, b), d = max - min;
  const l = (max + min) / 2;
  if (d === 0) return { h: 0, s: 0, l };
  const s = d / (1 - Math.abs(2 * l - 1));
  const h = max === r ? ((g - b) / d) % 6 : max === g ? (b - r) / d + 2 : (r - g) / d + 4;
  return { h: (h * 60 + 360) % 360, s, l };
}

/** Orange: hue 20-40 degrees with high saturation (gold sits at the same hue but is muted, so it passes). */
export function isOrange(hex: string): boolean {
  const { h, s } = hexToHsl(hex);
  return h >= 20 && h <= 40 && s > 0.6;
}
