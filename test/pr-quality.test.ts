import { describe, it, expect } from 'vitest';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
// @ts-expect-error plain .mjs without types
import { checkPrBody, closedIssues, section } from '../ci/pr-quality/pr-body-check.mjs';
// @ts-expect-error plain .mjs without types
import { scan, compare } from '../ci/pr-quality/slop-guard.mjs';

const GOOD = '## Verified\nnpm test green, 14 new tests\n\n## Not verified\nThe live deploy\n\n## Cost-if-wrong\nA red check until the secret exists\n';

describe('pr-body-check', () => {
  it('passes a complete body', () => expect(checkPrBody({ body: GOOD, title: 'feat: x' })).toEqual([]));
  it('names every missing or placeholder section', () => {
    const p = checkPrBody({ body: '## Verified\nok\n## Not verified\nTBD\n', title: 'feat: x' });
    expect(p.join('\n')).toMatch(/missing section "## Cost-if-wrong"/);
    expect(p.join('\n')).toMatch(/"## Not verified" is empty or a placeholder/);
  });
  it('rejects hedges outside code blocks only', () => {
    expect(checkPrBody({ body: GOOD + 'This should work.', title: 'feat: x' }).join()).toMatch(/hedged claim/);
    expect(checkPrBody({ body: GOOD + '```\nshould work\n```\n', title: 'feat: x' })).toEqual([]);
  });
  it('a fix needs a mutation check and a test file in the diff', () => {
    expect(checkPrBody({ body: GOOD, title: 'fix(api): y', files: ['a.ts'] }).length).toBe(2);
    const body = GOOD + '## Mutation check\nreverted the guard: test X failed with "expected 1 got 2"\n';
    expect(checkPrBody({ body, title: 'fix(api): y', files: ['a.ts', 'a.test.ts'] })).toEqual([]);
    expect(checkPrBody({ body, title: 'chore: y', branch: 'fix/z', files: ['a.ts'] }).join()).toMatch(/no test file/);
  });
  it('closing a review-finding needs a checked Test naming a diff test and a Foundation reference', () => {
    const files = ['apps/api/x.ts', 'apps/api/x.test.ts'];
    expect(checkPrBody({ body: GOOD, title: 'feat: x', files, linkedFindings: [7] }).length).toBe(2);
    const ok = GOOD + '- [x] Test: apps/api/x.test.ts\n- [x] Foundation: os/standard/pr-quality.md\n';
    expect(checkPrBody({ body: ok, title: 'feat: x', files, linkedFindings: [7] })).toEqual([]);
    const wrong = GOOD + '- [x] Test: other.test.ts\n- [ ] Foundation: os/standard/pr-quality.md\n';
    expect(checkPrBody({ body: wrong, title: 'feat: x', files, linkedFindings: [7] }).length).toBe(2);
  });
  it('closedIssues reads Fixes/Closes/Resolves', () => {
    expect(closedIssues('Fixes #3, closes #4 and resolved #3. See #9')).toEqual([3, 4]);
  });
  it('section ignores html comments', () => expect(section('## Verified\n<!-- what -->\n', 'Verified')).toBe(''));
});

function repo(files: Record<string, string>) {
  const root = mkdtempSync(join(tmpdir(), 'pq-'));
  for (const [f, c] of Object.entries(files)) { mkdirSync(join(root, f, '..'), { recursive: true }); writeFileSync(join(root, f), c); }
  return root;
}
const big = (n: string) => `export function ${n}(a: number, b: number) {\n  const total = a * 100 + b;\n  const rounded = Math.round(total) / 100;\n  if (rounded < 0) return 0;\n  if (rounded > 1000000) throw new Error('amount out of range for a single order');\n  if (Number.isNaN(rounded)) throw new Error('amount is not a number');\n  return rounded;\n}\n`;
const ids = (root: string, cfg = {}) => [...scan({ root, config: { roots: ['apps'], ...cfg } }).keys()] as string[];

describe('slop-guard', () => {
  it('flags any, console.log, bare TODO; honours pq-allow and issue-linked TODO', () => {
    const root = repo({ 'apps/a/src/x.ts': 'const a: any = 1;\nconsole.log(a);\n// TODO fix\n// TODO(#12) later\n// pq-allow(no-any): upstream type\nconst b: any = 2;\nexport const used = 1;\n', 'apps/a/src/y.ts': 'import { used } from "./x";\nused;\n' });
    const r = ids(root).map((i) => i.split('|')[0]).sort();
    expect(r).toEqual(['no-any', 'no-console', 'todo-no-issue']);
  });
  it('ignores test files', () => {
    expect(ids(repo({ 'apps/a/src/x.test.ts': 'const a: any = 1; console.log(a);\n' }))).toEqual([]);
  });
  it('flags an export nothing else imports, but not one a sibling imports or a framework name', () => {
    const root = repo({ 'apps/a/src/x.ts': 'export const dead = 1;\nexport const alive = 2;\nexport const GET = 3;\n', 'apps/a/src/y.ts': 'import { alive } from "./x";\nalive;\n', 'apps/a/src/x.test.ts': 'import { dead } from "./x";\ndead;\n' });
    expect(ids(root)).toEqual(['unused-export|apps/a/src/x.ts|dead']);
  });
  it('flags the same function body in two files, not a one-off', () => {
    const root = repo({ 'apps/a/src/a.ts': big('roundMoney') + 'export const k = roundMoney;\n', 'apps/b/src/b.ts': big('roundMoney') + 'export const m = roundMoney;\n', 'apps/c/src/c.ts': big('other').replace('* 100', '* 7') });
    expect(ids(root).filter((i) => i.startsWith('duplicate-helper')).length).toBe(2);
  });
  it('flags emoji in locale copy but not (c)', () => {
    const root = repo({ 'apps/a/messages/ar.json': '{\n"a": "مرحبا 🎉",\n"b": "© 2026"\n}\n' });
    expect(ids(root, { locales: ['apps/a/messages'] }).map((i) => i.split('|')[0])).toEqual(['emoji-copy']);
  });
  it('compare: new ids fail, fixed ids go stale', () => {
    const cur = new Map([['a', ''], ['b', '']]);
    expect(compare(cur, ['b', 'c'])).toEqual({ added: ['a'], stale: ['c'] });
  });
  it('CLI: --update refuses to add, shrinks when fixed, check fails on stale', () => {
    const root = repo({ 'apps/a/src/x.ts': 'const a: any = 1;\nexport const u = a;\n', 'apps/a/src/y.ts': 'u;\n' });
    const cli = join(__dirname, '../ci/pr-quality/slop-guard.mjs');
    const run = (...a: string[]) => spawnSync('node', [cli, '--root', root, ...a], { encoding: 'utf8' });
    writeFileSync(join(root, '.pr-quality.json'), '{"roots":["apps"]}');
    expect(run('--update').status).toBe(1); // no baseline: needs --init
    expect(run('--update', '--init').status).toBe(0);
    expect(run().status).toBe(0);
    writeFileSync(join(root, 'apps/a/src/z.ts'), 'const q: any = 1;\nexport const r = q;\n');
    writeFileSync(join(root, 'apps/a/src/w.ts'), 'r;\n');
    expect(run().status).toBe(1); // new any
    expect(run('--update').status).toBe(1); // cannot launder it into the baseline
    writeFileSync(join(root, 'apps/a/src/x.ts'), 'const a = 1;\nexport const u = a;\n');
    writeFileSync(join(root, 'apps/a/src/z.ts'), 'const q = 1;\nexport const r = q;\n');
    const stale = run();
    expect(stale.status).toBe(1);
    expect(stale.stderr).toMatch(/FIXED but still in the baseline/);
    expect(run('--update').status).toBe(0);
    expect(run().status).toBe(0);
    expect(JSON.parse(readFileSync(join(root, '.pr-quality-baseline.json'), 'utf8')).ids).toEqual([]);
  });
});

