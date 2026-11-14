import { describe, expect, it } from 'vitest';
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join, relative } from 'node:path';
import { vendoredSet } from '../../../../lib/foundation.mjs';
import { entry, cfg } from '../../../../test/helpers/capability-fixture';
import { checkModelBypass } from '../smart-layer-bypass';
import { toRegistryView } from './registry-view';
import { DEFAULT_MODELS, resolveModels } from './models';

const DIR = new URL('.', import.meta.url).pathname;
const walk = (d: string): string[] => readdirSync(d).flatMap((n) => (statSync(join(d, n)).isDirectory() ? walk(join(d, n)) : [join(d, n)]));
const engineFiles = () => walk(DIR).filter((f) => f.endsWith('.ts') && !/\.test\.ts$/.test(f));

describe('smart-layer skeleton', () => {
  it('uses no node: imports and no file extensions in relative imports', () => {
    for (const f of engineFiles()) {
      const src = readFileSync(f, 'utf8');
      expect(src, f).not.toMatch(/from\s+['"]node:/);
      expect(src, f).not.toMatch(/from\s+['"]\.[^'"]*\.ts['"]/);
    }
  });
  it('has no npm imports (engine is dependency free)', () => {
    for (const f of engineFiles()) {
      for (const m of readFileSync(f, 'utf8').matchAll(/from\s+['"]([^'"]+)['"]/g)) expect(m[1]!.startsWith('.'), `${relative(DIR, f)} imports ${m[1]}`).toBe(true);
    }
  });
  it('package exports ./smart-layer', () => {
    const pkg = JSON.parse(readFileSync(join(DIR, '../../package.json'), 'utf8'));
    expect(pkg.exports['./smart-layer']).toBe('./src/smart-layer/index.ts');
  });
  it('vendoredSet includes src/smart-layer/index.ts', () => {
    expect(vendoredSet().map(([rel]: [string]) => rel)).toContain('smart-layer/index.ts');
  });
  it('toRegistryView maps a fixture entry and byAppPath finds it', () => {
    const v = toRegistryView([entry({ screens: ['/stores/[id]/orders', 'Settings > x'] })]);
    const cap = v.caps.get('orders.list')!;
    expect(cap.title).toEqual({ ar: 'الطلبات', en: 'Orders' });
    expect(cap.appPaths).toEqual(['/stores/[id]/orders']);
    expect(cap.undo).toBe('none');
    expect(v.byAppPath('/stores/[id]/orders')?.id).toBe('orders.list');
    expect(v.byAppPath('/nope')).toBeUndefined();
  });
  it('model ids appear only in models.ts (config, not literals)', () => {
    for (const f of engineFiles().filter((x) => !x.endsWith('/models.ts'))) expect(readFileSync(f, 'utf8'), f).not.toMatch(/@cf\//);
  });
  it('models: overrides win per job, embed matches both products indexes', () => {
    expect(resolveModels({ answer: '@cf/x/y' }).answer).toBe('@cf/x/y');
    expect(resolveModels({ answer: '  ' }).answer).toBe(DEFAULT_MODELS.answer);
    expect(DEFAULT_MODELS.embed).toBe('@cf/baai/bge-m3');
  });
  it('bypass guard: the engine own provider module is allowlisted by path with a reason, nothing else flagged', () => {
    const files = engineFiles().map((f) => ({ path: relative(join(DIR, '../../../..'), f), src: readFileSync(f, 'utf8') }));
    // Reason: the engine IS the Smart Layer; consumers list the vendored smart-layer directory in capabilities/guard.config.json smartLayerPaths.
    const allow = { ...cfg, smartLayerPaths: ['packages/foundation/src/smart-layer/'] };
    expect(checkModelBypass(files, allow)).toEqual([]);
    // Without the allowlist the guard still must not misread engine source as a bypass of someone else's code path: it reports only real call patterns.
    const flagged = checkModelBypass(files, cfg).map((v) => v.message);
    for (const m of flagged) expect(m).toMatch(/provider|rest-ai|workers-ai/);
  });
});
