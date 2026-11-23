import { describe, expect, it } from 'vitest';
import { mkdirSync, mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
// @ts-expect-error plain .mjs without types
import { backfillPlan, scaffoldArticle } from '../lib/capability-backfill.mjs';
import { checkHelp, parseHelpFrontMatter, toHelpArticle } from '../packages/foundation/src/help-article';
import { entry } from './helpers/capability-fixture';
import type { Capability } from '../packages/foundation/src/capability';

const cfg = { helpExemptAreas: ['platform'] };
const es: Capability[] = [
  entry({ id: 'orders.list', area: 'orders', helpArticle: 'orders' }),
  entry({ id: 'orders.refund', area: 'orders', helpArticle: null }),
  entry({ id: 'billing.plans', area: 'billing', helpArticle: 'plans', version: 2 }),
  entry({ id: 'platform.tax', area: 'platform', helpArticle: null }),
  entry({ id: 'ops.only', area: 'ops', roles: ['super_admin'], helpArticle: null }),
  entry({ id: 'later.thing', area: 'later', status: 'planned', plan: 'p', helpArticle: null }),
];

function fixture() {
  const dir = mkdtempSync(join(tmpdir(), 'cap-bf-'));
  const art = mkdtempSync(join(tmpdir(), 'cap-art-'));
  for (const e of es) writeFileSync(join(dir, `${e.id}.capability.json`), JSON.stringify(e));
  for (const lang of ['ar', 'en']) mkdirSync(join(art, lang));
  const w = (lang: string, slug: string, cap: string) => writeFileSync(join(art, lang, `${slug}.mdx`), `---\ntitle: t\ncapabilities:\n  - ${cap}\n---\nbody`);
  w('ar', 'orders', 'orders.list@1'); w('en', 'orders', 'orders.list@1'); // fresh: absent from the plan
  w('ar', 'plans', 'billing.plans@1'); w('en', 'plans', 'billing.plans@1'); // stale vs version 2: present
  return { dir, art };
}

describe('backfillPlan', () => {
  const { dir, art } = fixture();
  it('groups needs-help entries by area, ordered area then id; fresh, exempt, operator-only and planned entries are absent', () => {
    expect(backfillPlan(dir, cfg, { articlesDir: art })).toEqual({ batches: [{ name: 'billing', ids: ['billing.plans'] }, { name: 'orders', ids: ['orders.refund'] }] });
  });
  it('without an articles dir every needs-help entry is planned', () => {
    expect(backfillPlan(dir, cfg).batches.flatMap((b: { ids: string[] }) => b.ids)).toEqual(['billing.plans', 'orders.list', 'orders.refund']);
  });
  it('agrees with checkHelp (the .mjs mirrors the TS rules)', () => {
    const arts = [toHelpArticle('orders', 'ar', '---\ncapabilities:\n  - orders.list@1\n---'), toHelpArticle('orders', 'en', '---\ncapabilities:\n  - orders.list@1\n---'), toHelpArticle('plans', 'ar', '---\ncapabilities:\n  - billing.plans@1\n---'), toHelpArticle('plans', 'en', '---\ncapabilities:\n  - billing.plans@1\n---')];
    const flagged = new Set(checkHelp(es, arts, cfg).map((v) => v.key.split(' ')[0]));
    const planned = backfillPlan(dir, cfg, { articlesDir: art }).batches.flatMap((b: { ids: string[] }) => b.ids);
    expect(new Set(planned)).toEqual(flagged);
  });
});

describe('scaffoldArticle', () => {
  const e = entry({ id: 'a.b', version: 3, screens: ['view:X', '/stores/[id]/orders'], steps: ['one', 'two'], edgeCases: ['edge'], titleEn: 'My: title' });
  it('front matter parses with the guard parser and carries id@version, appPath and section', () => {
    const { data } = parseHelpFrontMatter(scaffoldArticle(e, 'en'));
    expect(data.capabilities).toEqual(['a.b@3']);
    expect(data.appPath).toBe('/stores/[id]/orders');
    expect(data.title).toBe('My: title');
    expect(data.section).toBe('orders');
    expect(toHelpArticle('s', 'en', scaffoldArticle(e, 'en')).capabilities).toEqual([{ id: 'a.b', version: 3 }]);
  });
  it('lists steps, questions in the requested language and edge cases', () => {
    const ar = scaffoldArticle(e, 'ar');
    expect(ar).toContain('1. one');
    expect(ar).toContain('## الخطوات');
    expect(ar).toContain('- edge');
    expect(scaffoldArticle(e, 'en')).toContain('## Questions merchants ask');
  });
});
