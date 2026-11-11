import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { execFile, spawnSync } from 'node:child_process';
import { createServer, type Server } from 'node:http';
import { mkdtempSync, writeFileSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
// @ts-expect-error plain .mjs without types
import { isRisky, riskyPaths } from '../ci/ai-review/risky-paths.mjs';

describe('risky-paths (fail closed: only docs/markdown/tests are exempt)', () => {
  it('exempts markdown, docs/, and test files', () => {
    for (const p of ['README.md', 'apps/web/CHANGELOG.mdx', 'docs/plans/x.md', 'docs/img/a.png', 'apps/api/src/refunds/refund.test.ts', 'apps/api/test/helpers.ts', 'packages/x/__tests__/a.ts', 'e2e/checkout.spec.ts']) {
      expect(isRisky(p), p).toBe(false);
    }
  });
  it('requires review for the data paths the first (word-list) classifier missed', () => {
    for (const p of ['packages/database/src/index.ts', 'packages/database/prisma/schema.prisma', 'apps/api/src/routes/order.routes.ts', 'apps/api/src/services/order.service.ts', 'apps/api/src/services/cross-store.service.ts', 'packages/database/migrations/002_rls.sql']) {
      expect(isRisky(p), p).toBe(true);
    }
  });
  it('requires review for the gate itself, CI, scripts and configs, so the gate cannot be edited to pass', () => {
    for (const p of ['.github/ai-review/review.mjs', '.github/ai-review/prompt.md', '.github/ai-review/risky-paths.mjs', '.github/workflows/ai-review.yml', '.github/workflows/ci.yml', 'scripts/ci/merge-gate.sh', 'package.json', 'eslint.slop.mjs', 'vitest.config.ts']) {
      expect(isRisky(p), p).toBe(true);
    }
  });
  it('does not let a docs/ or test-looking name smuggle code through', () => {
    for (const p of ['docs/build.mjs', 'docs/../apps/api/src/x.ts', 'apps/api/src/contest.ts', 'apps/api/src/test-utils.ts', 'apps/api/src/readme.md.ts']) expect(isRisky(p), p).toBe(true);
  });
  it('an all-safe diff yields no paths; one risky file among safe ones is reported alone; blanks are ignored', () => {
    expect(riskyPaths(['README.md', '', 'a.test.ts'])).toEqual([]);
    expect(riskyPaths(['README.md', 'apps/api/src/x.ts', '  '])).toEqual(['apps/api/src/x.ts']);
  });
  it('CLI prints only the paths that need review', () => {
    const out = spawnSync('node', [join(__dirname, '../ci/ai-review/risky-paths.mjs')], { input: 'README.md\napps/api/src/x.ts\n', encoding: 'utf8' });
    expect(out.stdout).toBe('apps/api/src/x.ts\n');
  });
});

describe('ai-review.yml keeps the gate out of the PR author\'s hands', () => {
  const wf = readFileSync(join(__dirname, '../.github/workflows/ai-review.yml'), 'utf8');
  it('checks out the BASE branch (scripts and prompt), never the PR head, in both jobs', () => {
    expect((wf.match(/ref: \$\{\{ github\.event\.pull_request\.base\.ref \}\}/g) ?? []).length).toBe(2);
    expect(wf).not.toMatch(/ref: \$\{\{ github\.event\.pull_request\.head/);
  });
  it('fails closed on an oversized diff instead of reviewing part of it', () => {
    expect(wf).toMatch(/-ge 400000/);
    expect(wf).not.toMatch(/head -c/);
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
