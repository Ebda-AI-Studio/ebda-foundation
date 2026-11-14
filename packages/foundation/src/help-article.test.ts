import { describe, expect, it } from 'vitest';
import { checkHelp, parseHelpFrontMatter, toHelpArticle } from './help-article';
import { entry } from '../../../test/helpers/capability-fixture';
import type { Capability } from './capability';

const STORE_HEADER = `---
title: ضيف موديل 3D للمنتج
description: خلّي العميل يلف المنتج، ويشوف كل لون أو معدن، ويحطه في أوضته بالواقع المعزز.
section: البيع
order: 12
appPath: /stores
keywords: 3d موديل glb gltf usdz واقع معزز خاتم مجوهرات لون معدن دهب
---

body here`;

const art = (slug: string, lang: 'ar' | 'en', caps: string[]) => toHelpArticle(slug, lang, `---\ntitle: t\ncapabilities:\n${caps.map((c) => `  - ${c}`).join('\n')}\n---\nbody`);
const run = (es: Capability[], arts: ReturnType<typeof art>[], exempt: string[] = []) => checkHelp(es, arts, { helpExemptAreas: exempt }).map((v) => `${v.rule}|${v.key}`);
const ok = [art('orders', 'ar', ['orders.list@1']), art('orders', 'en', ['orders.list@1'])];

describe('parseHelpFrontMatter', () => {
  it('parses a real Store article header', () => {
    const { data, body } = parseHelpFrontMatter(STORE_HEADER);
    expect(data.appPath).toBe('/stores');
    expect(data.order).toBe('12');
    expect(data.title).toBe('ضيف موديل 3D للمنتج');
    expect(body.trim()).toBe('body here');
  });
  it('parses block lists and quoted scalars, ignores unknown keys', () => {
    const { data } = parseHelpFrontMatter('---\ntitle: "a: b"\nweird: x\ncapabilities:\n  - a.b@2\n  - c.d@1\n---\n');
    expect(data.title).toBe('a: b');
    expect(data.capabilities).toEqual(['a.b@2', 'c.d@1']);
  });
  it('no front matter returns empty data', () => expect(parseHelpFrontMatter('# hi')).toEqual({ data: {}, body: '# hi' }));
});

describe('toHelpArticle', () => {
  it('reads id@version pairs and appPath', () => {
    const a = toHelpArticle('s', 'ar', '---\nappPath: /x\ncapabilities:\n  - a.b@2\n  - c.d@1\n---\n');
    expect(a.capabilities).toEqual([{ id: 'a.b', version: 2 }, { id: 'c.d', version: 1 }]);
    expect(a.appPath).toBe('/x');
  });
});

describe('checkHelp', () => {
  it('a fully linked bilingual article is clean', () => expect(run([entry()], ok)).toEqual([]));
  it('help-missing when helpArticle is null', () => expect(run([entry({ helpArticle: null })], [])).toEqual(['help-missing|orders.list']));
  it('help-article-absent when the slug has no article in either language', () => expect(run([entry()], [])).toEqual(['help-article-absent|orders.list']));
  it('an ar-only article yields help-twin-missing, not a pass', () => expect(run([entry()], [ok[0]!])).toEqual(['help-twin-missing|orders']));
  it('an en-only article yields help-twin-missing too', () => expect(run([entry()], [ok[1]!])).toEqual(['help-twin-missing|orders']));
  it('help-unlinked when the article does not list the id', () => {
    expect(run([entry()], [art('orders', 'ar', ['x.y@1']), art('orders', 'en', ['x.y@1'])]).filter((r) => r.startsWith('help-unlinked'))).toEqual(['help-unlinked|orders.list']);
  });
  it('help-unlinked when only one language lists the id', () => {
    expect(run([entry()], [ok[0]!, art('orders', 'en', [])])).toContain('help-unlinked|orders.list');
  });
  it('entry version 2 with article a.b@1 yields help-stale', () => {
    const e = entry({ id: 'a.b', helpArticle: 's', version: 2 });
    expect(run([e], [art('s', 'ar', ['a.b@1']), art('s', 'en', ['a.b@2'])])).toEqual(['help-stale|a.b']);
  });
  it('help-orphan when an article lists an id with no entry', () => {
    expect(run([entry()], [...ok, art('other', 'ar', ['gone.x@1'])])).toEqual(['help-orphan|other gone.x']);
  });
  it('an entry in an exempt area yields no help-missing', () => expect(run([entry({ helpArticle: null, area: 'platform' })], [], ['platform'])).toEqual([]));
  it('a super-admin-only live entry yields none', () => expect(run([entry({ helpArticle: null, roles: ['super_admin'] })], [])).toEqual([]));
  it('planned and in-pr entries are not checked for articles', () => expect(run([entry({ status: 'planned', plan: 'p', helpArticle: null })], [])).toEqual([]));
});
