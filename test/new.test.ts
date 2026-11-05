import { describe, expect, it } from 'vitest';
import { existsSync, mkdtempSync, readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
// @ts-expect-error plain .mjs without types
import { namesFor, reservedSlugs } from '../create/new.mjs';

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
  it('the reserved list covers every Ebda product host', () => {
    for (const slug of ['crm', 'erp', 'wa', 'accounts', 'help', 'docs', 'status', 'store']) expect(reservedSlugs(), slug).toContain(slug);
  });
  it('refuses to scaffold a product whose slug is not reserved', () => {
    const out = join(mkdtempSync(join(tmpdir(), 'fnd-new-')), 'ebda-sandbox');
    expect(() => execFileSync('node', [join(ROOT, 'bin/ebda-foundation.mjs'), 'new', 'ebda-sandbox', '--no-remote', '--no-install', '--out', out], { encoding: 'utf8', stdio: 'pipe' })).toThrow(/RESERVED_SLUGS/);
    expect(existsSync(out)).toBe(false);
  });
  it('scaffolds a repo with the vendored foundation and a passing lock (no remote, no install)', () => {
    const out = join(mkdtempSync(join(tmpdir(), 'fnd-new-')), 'ebda-crm');
    const r = execFileSync('node', [join(ROOT, 'bin/ebda-foundation.mjs'), 'new', 'ebda-crm', '--no-remote', '--no-install', '--out', out], { encoding: 'utf8' });
    expect(r).toContain('Ebda CRM created');
    for (const f of ['package.json', 'wrangler.jsonc', 'CLAUDE.md', 'foundation.lock.json', 'foundation/phone.ts', 'test/foundation-parity.test.ts', 'src/index.ts', '.github/workflows/ci.yml']) expect(existsSync(join(out, f)), f).toBe(true);
    const wrangler = readFileSync(join(out, 'wrangler.jsonc'), 'utf8');
    expect(wrangler).toContain('"name": "ebda-crm"');
    expect(readFileSync(join(out, 'src/index.ts'), 'utf8')).not.toContain('{{');
    expect(execFileSync('node', [join(ROOT, 'bin/ebda-foundation.mjs'), 'check', '--target', out], { encoding: 'utf8' })).toContain('in sync');
    expect(execFileSync('git', ['log', '--format=%s'], { cwd: out, encoding: 'utf8' })).toMatch(/^chore: init ebda-crm from ebda-foundation v0\.1\.0/);
  });
});
