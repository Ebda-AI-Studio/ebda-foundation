// MANAGED FILE: vendored by `ebda-foundation sync` (listed in foundation.lock.json). Do not edit; change it in ebda-foundation.
// Proves the vendored foundation equals the tagged source and still passes the shared vectors.
import { createHash } from 'node:crypto';
import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs';
import { join, relative, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { describe, expect, it } from 'vitest';

const root = resolve(process.env.FOUNDATION_ROOT ?? process.cwd());
const lock = JSON.parse(readFileSync(join(root, 'foundation.lock.json'), 'utf8')) as {
  tag: string; commit: string; dir: string; ops: string; parity: string; files: Record<string, string>;
};
const sha = (b: Buffer) => createHash('sha256').update(b).digest('hex');
const walk = (d: string): string[] =>
  existsSync(d) ? readdirSync(d).flatMap((n) => (n === 'node_modules' ? [] : statSync(join(d, n)).isDirectory() ? walk(join(d, n)) : [join(d, n)])) : [];
const load = (m: string) => import(/* @vite-ignore */ pathToFileURL(join(root, lock.dir, 'src', m, 'index.ts')).href);
const vec = (f: string) => JSON.parse(readFileSync(join(root, lock.dir, 'vectors', f), 'utf8'));

describe('foundation lock', () => {
  it('every locked file exists with the locked sha256', () => {
    const bad = Object.entries(lock.files).flatMap(([rel, want]) =>
      !existsSync(join(root, rel)) ? [`MISSING ${rel}`] : sha(readFileSync(join(root, rel))) !== want ? [`MODIFIED ${rel}`] : []);
    expect(bad).toEqual([]);
  });
  it('no extra files under the vendored directories', () => {
    const extra = [lock.dir, lock.ops].flatMap((d) => walk(join(root, d)).map((f) => relative(root, f).split('\\').join('/'))).filter((f) => !(f in lock.files));
    expect(extra).toEqual([]);
  });
  it('lock tag and commit match the vendored package.json', () => {
    const pkg = JSON.parse(readFileSync(join(root, lock.dir, 'package.json'), 'utf8'));
    expect(`v${pkg.version}`).toBe(lock.tag);
    expect(pkg.foundationCommit).toBe(lock.commit);
    expect(lock.commit).toMatch(/^[0-9a-f]{40}$/);
  });
});

describe('shared vectors against the vendored code', () => {
  it('phone', async () => {
    const { normaliseE164 } = await load('phone');
    const bad = (vec('phone.json') as { in: string; e164: string | null }[]).filter((c) => normaliseE164(c.in) !== c.e164).map((c) => c.in);
    expect(bad).toEqual([]);
  });
  it('buyerKey', async () => {
    const { buyerKey } = await load('buyer');
    const v = vec('buyer-key.json') as { secret: string; cases: { e164: string; hex: string }[] };
    for (const c of v.cases) expect(await buyerKey(v.secret, c.e164)).toBe(c.hex);
  });
  it('arabic fold, index tokens and phone digits', async () => {
    const t = await load('text');
    const v = vec('arabic.json') as Record<'fold' | 'index' | 'phoneDigits', { in: string; out: string }[]>;
    for (const c of v.fold) expect(t.foldArabic(c.in)).toBe(c.out);
    for (const c of v.index) expect(t.indexTokens(c.in)).toBe(c.out);
    for (const c of v.phoneDigits) expect(t.phoneDigits(c.in)).toBe(c.out);
  });
  it('slugs', async () => {
    const s = await load('slugs');
    const v = vec('slugs.json') as { slugify: { in: string; ascii?: boolean; out: string }[]; validate: { in: string; ok?: boolean; code?: string }[] };
    for (const c of v.slugify) expect(s.slugify(c.in, { ascii: c.ascii })).toBe(c.out);
    for (const c of v.validate) expect(s.validateSlug(c.in)).toEqual(c.ok ? { ok: true, slug: c.in } : { ok: false, code: c.code });
  });
});
