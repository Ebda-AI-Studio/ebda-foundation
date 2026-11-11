import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { execFile } from 'node:child_process';
import { createServer, type Server } from 'node:http';
import { mkdtempSync, writeFileSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
// @ts-expect-error plain .mjs without types
import { isRisky, riskyPaths } from '../ci/ai-review/risky-paths.mjs';

describe('risky-paths', () => {
  it('matches whole tokens in money/auth/data paths, plurals and camelCase', () => {
    for (const p of ['apps/api/src/refunds/service.ts', 'packages/database/migrations/001.sql', 'src/PermissionGuard.ts', 'apps/web/checkout/page.tsx', 'x/webhooks/kashier.ts']) {
      expect(isRisky(p), p).toBe(true);
    }
  });
  it('does not match a risky word hidden inside another word', () => {
    for (const p of ['apps/web/codemod.ts', 'src/author.ts', 'docs/README.md', 'src/decode.ts', 'src/priceless.ts']) expect(isRisky(p), p).toBe(false);
  });
  it('filters a list and ignores blank lines', () => {
    expect(riskyPaths(['a.md', '', 'src/wallet/x.ts'])).toEqual(['src/wallet/x.ts']);
  });
});

const REVIEW = join(__dirname, '../ci/ai-review/review.mjs');
let server: Server;
let api: string;
const posted: string[] = [];
beforeAll(async () => {
  server = createServer((req, res) => {
    posted.push(`${req.method} ${req.url}`);
    req.resume();
    res.writeHead(200, { 'content-type': 'application/json' }).end('{}');
  });
  await new Promise<void>((r) => server.listen(0, '127.0.0.1', r));
  api = `http://127.0.0.1:${(server.address() as { port: number }).port}`;
});
afterAll(() => new Promise<void>((r) => server.close(() => r())));

function run(modelResult: unknown, env: Record<string, string> = {}): Promise<{ code: number; passed: boolean }> {
  const dir = mkdtempSync(join(tmpdir(), 'air-'));
  const out = join(dir, 'claude.json');
  const gh = join(dir, 'gh-output');
  writeFileSync(gh, '');
  if (modelResult !== undefined) writeFileSync(out, JSON.stringify({ result: typeof modelResult === 'string' ? modelResult : JSON.stringify(modelResult) }));
  const full = {
    PATH: process.env.PATH ?? '', GITHUB_TOKEN: 't', GITHUB_REPOSITORY: 'o/r', PR_NUMBER: '1', HEAD_SHA: 'abc',
    CLAUDE_OUTPUT: out, GITHUB_OUTPUT: gh, GITHUB_API_URL: api, ...env,
  };
  return new Promise((resolve) =>
    execFile('node', [REVIEW], { env: full }, (err) =>
      resolve({ code: err ? ((err as { code?: number }).code ?? 1) : 0, passed: /passed=true/.test(readFileSync(gh, 'utf8')) }),
    ),
  );
}
const crit = { findings: [{ file: 'a.ts', line: 1, severity: 'critical', category: 'payments', comment: 'double refund' }] };

describe('review.mjs gate', () => {
  it('passes with no criticals and reports passed=true', async () => {
    expect(await run({ summary: 's', findings: [{ file: 'a.ts', line: 1, severity: 'warning', category: 'slop', comment: 'x' }] })).toEqual({ code: 0, passed: true });
    expect(posted.some((p) => p.includes('/pulls/1/reviews'))).toBe(true);
  });
  it('blocks on a critical finding', async () => {
    expect(await run(crit)).toEqual({ code: 1, passed: false });
  });
  it('FAIL_CLOSED blocks on every infra error; open mode still lets them through', async () => {
    const bad: Array<[string, unknown, Record<string, string>]> = [
      ['not json', 'I think this is fine', {}],
      ['no findings array', { summary: 's' }, {}],
      ['null', 'null', {}],
      ['no output file', undefined, {}],
      ['no token', { findings: [] }, { GITHUB_TOKEN: '' }],
    ];
    for (const [name, model, env] of bad) {
      expect((await run(model, { FAIL_CLOSED: 'true', ...env })).code, `${name} closed`).toBe(1);
      expect((await run(model, env)).code, `${name} open`).toBe(0);
    }
  });
  it('FAIL_CLOSED treats an undefined severity as critical', async () => {
    const odd = { findings: [{ file: 'a.ts', line: 1, severity: 'blocker', category: 'logic', comment: 'x' }] };
    expect((await run(odd, { FAIL_CLOSED: 'true' })).code).toBe(1);
    expect((await run(odd)).code).toBe(0);
  });
  it('never writes passed=true when it blocks', async () => {
    expect((await run('garbage', { FAIL_CLOSED: 'true' })).passed).toBe(false);
  });
});
