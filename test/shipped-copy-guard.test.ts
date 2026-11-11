import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { BARE_AR, BARE_EN } from '../packages/foundation/src/brand';

// Narrow on purpose: only copy that ships to users or to a new product's repo. Developer prose (README, docs/, CONTRIBUTING,
// code comments, the skeleton's CLAUDE.md.tmpl rule file and its tests) legitimately says "Ebda product" and is not scanned.

function walk(dir: string): string[] {
  if (!existsSync(dir)) return [];
  return readdirSync(dir).flatMap((n) => {
    if (n === 'node_modules') return [];
    const p = join(dir, n);
    return statSync(p).isDirectory() ? walk(p) : [p];
  });
}

/** Quoted string literals of a TS source, comments stripped. */
export function stringLiterals(src: string): string[] {
  const noComments = src.replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|[^:'"`\\])\/\/.*$/gm, '$1');
  return [...noComments.matchAll(/'((?:[^'\\\n]|\\.)*)'|"((?:[^"\\\n]|\\.)*)"|`((?:[^`\\]|\\.)*)`/g)].map((m) => m[1] ?? m[2] ?? m[3] ?? '');
}

export function bareHits(files: Record<string, string>): string[] {
  return Object.entries(files).flatMap(([f, text]) => {
    const parts = f.endsWith('.ts') ? stringLiterals(text) : text.split('\n');
    return parts.filter((s) => BARE_EN.test(s) || BARE_AR.test(s)).map((s) => `${f}: ${s.trim().slice(0, 100)}`);
  });
}

function shipped(): Record<string, string> {
  const skeleton = ['public', 'src', 'docs', 'wrangler.jsonc.tmpl', 'package.json.tmpl'].flatMap((p) => {
    const full = join('create/skeleton', p);
    return existsSync(full) && statSync(full).isDirectory() ? walk(full) : [full];
  });
  const lib = walk('packages/foundation/src').filter((f) => /\.(ts|css)$/.test(f) && !/\.test\.ts$/.test(f));
  const files = [...skeleton, ...walk('checklists'), ...lib].filter((f) => existsSync(f));
  return Object.fromEntries(files.map((f) => [f, readFileSync(f, 'utf8')]));
}

describe('shipped copy has no bare "Ebda"', () => {
  it('the current shipped tree is clean (and the scan really covers files)', () => {
    const files = shipped();
    expect(Object.keys(files).some((f) => f.startsWith('checklists/'))).toBe(true);
    expect(Object.keys(files).some((f) => f.startsWith('create/skeleton/'))).toBe(true);
    expect(Object.keys(files).some((f) => f.startsWith('packages/foundation/src/'))).toBe(true);
    expect(bareHits(files)).toEqual([]);
  });
  it('fails on a planted bare "Ebda" in a checklist, a skeleton page and a TS string', () => {
    expect(bareHits({ 'checklists/x.md': 'Welcome to Ebda\n' })).toHaveLength(1);
    expect(bareHits({ 'create/skeleton/public/index.html': '<h1>Ebda</h1>' })).toHaveLength(1);
    expect(bareHits({ 'packages/foundation/src/x.ts': "export const t = 'Ebda is live';" })).toHaveLength(1);
    expect(bareHits({ 'packages/foundation/src/x.ts': "// Ebda product\nexport const t = 'Ebda Store';" })).toHaveLength(0);
  });
  it('the Arabic arm: a planted bare Arabic brand word is exactly 1 hit, the full product names are 0', () => {
    expect(bareHits({ 'checklists/x.md': 'مرحبا في إبدا\n' })).toHaveLength(1);
    expect(bareHits({ 'checklists/x.md': 'إبدا ستور\nإبدأ شات\nابدأ الآن\n' })).toHaveLength(0);
    expect(bareHits({ 'packages/foundation/src/x.ts': "export const a = 'مرحبا في إبدا';" })).toHaveLength(1);
  });
});
