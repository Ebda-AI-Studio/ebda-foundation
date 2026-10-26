import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { BARE_AR, BARE_EN } from '../packages/foundation/src/brand';

function walk(dir: string): string[] {
  return readdirSync(dir).flatMap((n) => {
    if (n === 'node_modules') return [];
    const p = join(dir, n);
    return statSync(p).isDirectory() ? walk(p) : [p];
  });
}

describe('repo guards', () => {
  it('no bare "Ebda" in shipped sources, docs, skeleton or checklists', () => {
    const files = ['packages', 'create', 'checklists', 'docs', 'README.md', 'CONTRIBUTING.md'].filter((r) => existsSync(r))
      .flatMap((r) => (statSync(r).isDirectory() ? walk(r) : [r]))
      .filter((f) => /\.(ts|tsx|md|css|json|tmpl|html|mjs)$/.test(f) && !/\.test\.ts$/.test(f) && !f.endsWith('RULINGS.md'));
    const hits = files.flatMap((f) => readFileSync(f, 'utf8').split('\n').flatMap((l, i) => (!/BARE_(EN|AR)\s*=/.test(l) && (BARE_EN.test(l) || BARE_AR.test(l)) ? [`${f}:${i + 1}: ${l.trim()}`] : [])));
    expect(hits).toEqual([]);
  });
});
