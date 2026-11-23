import { describe, it, expect } from 'vitest';
import { readdirSync, statSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { stripTypeScriptTypes } from 'node:module';

// Consumers vendor packages/foundation/src and run it under Node's strip-only TypeScript, which rejects
// parameter properties, enums, namespaces with values, `import x = require` (v0.4.0 shipped one: ERR_UNSUPPORTED_TYPESCRIPT_SYNTAX).
const root = join(__dirname, '..', 'packages', 'foundation', 'src');
function tsFiles(d: string): string[] {
  return readdirSync(d).flatMap((n) => {
    const p = join(d, n);
    return statSync(p).isDirectory() ? tsFiles(p) : /\.tsx?$/.test(n) && !/\.d\.ts$/.test(n) ? [p] : [];
  });
}

describe('vendored foundation source is erasable TypeScript', () => {
  const files = tsFiles(root).filter((f) => !/\.test\.tsx?$/.test(f));
  it('finds the vendored files', () => expect(files.length).toBeGreaterThan(10));
  it('node strip-types accepts every file', () => {
    const bad: string[] = [];
    for (const f of files) {
      try { stripTypeScriptTypes(readFileSync(f, 'utf8'), { mode: 'strip' }); }
      catch (e) { bad.push(`${f}: ${(e as Error).message.split('\n')[0]}`); }
    }
    expect(bad).toEqual([]);
  });
});
