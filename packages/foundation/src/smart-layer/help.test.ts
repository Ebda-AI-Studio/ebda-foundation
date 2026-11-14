import { describe, expect, it } from 'vitest';
import { chunkHelp, corpusHash, groundingVerdict, helpDoc } from './help';
import type { HelpHit } from './types';

const raw = `---
title: إزاي تضيف كوبون
capabilities:
  - marketing.coupons@2
appPath: /stores/[id]/marketing/coupons
---
# إضافة كوبون

افتح صفحة الكوبونات وادوس إضافة.

## الخطوات

1. اكتب الكود
2. اختار الخصم

${'سطر طويل جدا '.repeat(120)}
`;
const hit = (score: number): HelpHit => ({ articleId: 'a', title: 't', url: 'u', appPath: null, text: 'x', score });

describe('help', () => {
  it('helpDoc reads appPath and id@version capabilities via toHelpArticle, url from helpUrl', () => {
    const d = helpDoc('coupons', 'ar', raw);
    expect(d).toMatchObject({ articleId: 'coupons', locale: 'ar', title: 'إزاي تضيف كوبون', url: 'https://help.ebda.app/coupons/', appPath: '/stores/[id]/marketing/coupons', capabilityIds: ['marketing.coupons'] });
    expect(helpDoc('coupons', 'en', raw).url).toBe('https://help.ebda.app/en/coupons/');
    expect(d.body).not.toContain('capabilities:');
  });
  it('title falls back to the first heading', () => {
    expect(helpDoc('x', 'en', '# Hello\ntext').title).toBe('Hello');
  });
  it('chunkHelp never exceeds 800 chars and is heading aware', () => {
    const chunks = chunkHelp(helpDoc('coupons', 'ar', raw));
    expect(chunks.length).toBeGreaterThan(2);
    for (const c of chunks) expect(c.text.length).toBeLessThanOrEqual(800);
    expect(chunks[0]!.text).toContain('إضافة كوبون');
    expect(new Set(chunks.map((c) => c.id)).size).toBe(chunks.length);
  });
  it('corpusHash is stable and changes with the content', async () => {
    const a = helpDoc('a', 'en', '# A\none');
    const b = helpDoc('a', 'en', '# A\ntwo');
    expect(await corpusHash([a])).toBe(await corpusHash([a]));
    expect(await corpusHash([a])).not.toBe(await corpusHash([b]));
  });
  it('groundingVerdict: top score 0.2 is not_covered, 0.45 weak, 0.8 covered, none not_covered', () => {
    expect(groundingVerdict([hit(0.2), hit(0.1)])).toBe('not_covered');
    expect(groundingVerdict([hit(0.45)])).toBe('weak');
    expect(groundingVerdict([hit(0.1), hit(0.8)])).toBe('covered');
    expect(groundingVerdict([])).toBe('not_covered');
  });
});
