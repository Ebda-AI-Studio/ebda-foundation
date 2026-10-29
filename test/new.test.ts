import { describe, expect, it } from 'vitest';
import { existsSync, mkdtempSync, readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
// @ts-expect-error plain .mjs without types
import { namesFor } from '../create/new.mjs';

const ROOT = resolve(__dirname, '..');

describe('new', () => {
  it('derives names', () => {
    expect(namesFor('ebda-crm')).toMatchObject({ slug: 'crm', host: 'crm.ebda.app', displayEn: 'Ebda CRM', displayAr: 'ابدأ CRM' });
    expect(namesFor('ebda-sandbox').displayEn).toBe('Ebda Sandbox');
  });
  it('refuses names that are not ebda-<x>', () => {
    expect(() => namesFor('crm')).toThrow(/ebda-crm/);
    expect(() => namesFor('ebda-')).toThrow();
  });
  it('scaffolds a repo with the vendored foundation and a passing lock (no remote, no install)', () => {
    const out = join(mkdtempSync(join(tmpdir(), 'fnd-new-')), 'ebda-sandbox');
    const r = execFileSync('node', [join(ROOT, 'bin/ebda-foundation.mjs'), 'new', 'ebda-sandbox', '--no-remote', '--no-install', '--out', out], { encoding: 'utf8' });
    expect(r).toContain('Ebda Sandbox created');
    for (const f of ['package.json', 'wrangler.jsonc', 'CLAUDE.md', 'foundation.lock.json', 'foundation/src/phone/index.ts', 'test/foundation-parity.test.ts', 'src/index.ts', '.github/workflows/ci.yml']) expect(existsSync(join(out, f)), f).toBe(true);
    const wrangler = readFileSync(join(out, 'wrangler.jsonc'), 'utf8');
    expect(wrangler).toContain('"name": "ebda-sandbox"');
    expect(readFileSync(join(out, 'src/index.ts'), 'utf8')).not.toContain('{{');
    expect(execFileSync('node', [join(ROOT, 'bin/ebda-foundation.mjs'), 'check', '--target', out], { encoding: 'utf8' })).toContain('in sync');
    expect(execFileSync('git', ['log', '--format=%s'], { cwd: out, encoding: 'utf8' })).toMatch(/^chore: init ebda-sandbox from ebda-foundation v0\.1\.0/);
  });
});
