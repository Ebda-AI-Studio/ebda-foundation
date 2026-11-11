import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { execFile, spawnSync } from 'node:child_process';
import { createServer, type Server } from 'node:http';
import { mkdtempSync, writeFileSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
// @ts-expect-error plain .mjs without types
import { isRisky, riskyPaths } from '../ci/ai-review/risky-paths.mjs';

describe('risky-paths (fail closed: only docs, markdown and NEWLY ADDED tests are exempt)', () => {
  it('exempts markdown and docs/ whatever the status', () => {
    for (const p of ['README.md', 'apps/web/CHANGELOG.mdx', 'docs/plans/x.md', 'docs/img/a.png']) for (const st of ['A', 'M', 'D']) expect(isRisky(p, st), `${st} ${p}`).toBe(false);
  });
  it('exempts a newly ADDED test file', () => {
    for (const p of ['apps/api/src/refunds/refund.test.ts', 'apps/api/test/helpers.ts', 'packages/x/__tests__/a.ts', 'e2e/checkout.spec.ts']) expect(isRisky(p, 'A'), p).toBe(false);
  });
  it('a MODIFIED or DELETED existing test is risky: several safety guards are test files', () => {
    for (const p of ['tests/unit/across-stores-isolation.test.ts', 'tests/unit/no-rls-bypass-in-runtime.test.ts', 'tests/unit/no-raw-pii-in-logs.test.ts', 'tests/unit/ai-writers-guard.test.ts']) {
      expect(isRisky(p, 'M'), `M ${p}`).toBe(true);
      expect(isRisky(p, 'D'), `D ${p}`).toBe(true);
      expect(isRisky(p), `unknown status ${p}`).toBe(true);
    }
  });
  it('requires review for the data paths the first (word-list) classifier missed', () => {
    for (const p of ['packages/database/src/index.ts', 'packages/database/prisma/schema.prisma', 'apps/api/src/routes/order.routes.ts', 'apps/api/src/services/order.service.ts', 'apps/api/src/services/cross-store.service.ts', 'packages/database/migrations/002_rls.sql']) {
      expect(isRisky(p, 'A'), p).toBe(true);
    }
  });
  it('requires review for the gate itself, CI, scripts and configs, even when added', () => {
    for (const p of ['.github/ai-review/review.mjs', '.github/ai-review/prompt.md', '.github/workflows/ci.yml', 'scripts/ci/merge-gate.sh', 'package.json', 'eslint.slop.mjs', 'vitest.config.ts']) expect(isRisky(p, 'A'), p).toBe(true);
  });
  it('does not let a docs/ or test-looking name smuggle code through', () => {
    for (const p of ['docs/build.mjs', 'docs/../apps/api/src/x.ts', 'apps/api/src/contest.ts', 'apps/api/src/test-utils.ts', 'apps/api/src/readme.md.ts']) expect(isRisky(p, 'A'), p).toBe(true);
  });
  it('parses git --name-status lines; a bare path has unknown status and counts as modified', () => {
    expect(riskyPaths(['A\tREADME.md', 'A\ta.test.ts', ''])).toEqual([]);
    expect(riskyPaths(['A\tREADME.md', 'M\tapps/api/src/x.ts', 'M\ttests/guard.test.ts', 'A\ttests/new.test.ts', 'tests/bare.test.ts'])).toEqual(['apps/api/src/x.ts', 'tests/guard.test.ts', 'tests/bare.test.ts']);
  });
  it('CLI prints only the paths that need review', () => {
    const out = spawnSync('node', [join(__dirname, '../ci/ai-review/risky-paths.mjs')], { input: 'A\tREADME.md\nM\ttests/guard.test.ts\nA\ttests/new.test.ts\n', encoding: 'utf8' });
    expect(out.stdout).toBe('tests/guard.test.ts\n');
  });
});

describe('ai-review.yml keeps the gate out of the PR author\'s hands', () => {
  const wf = readFileSync(join(__dirname, '../.github/workflows/ai-review.yml'), 'utf8');
  it('checks out the BASE branch (scripts and prompt), never the PR head, in both checkout jobs', () => {
    expect((wf.match(/ref: \$\{\{ github\.event\.pull_request\.base\.ref \}\}/g) ?? []).length).toBe(2);
    expect(wf).not.toMatch(/ref: \$\{\{ github\.event\.pull_request\.head/);
  });
  it('fails closed on an oversized diff instead of reviewing part of it', () => {
    expect(wf).toMatch(/-ge 400000/);
    expect(wf).not.toMatch(/head -c/);
  });
  it('classifies with name-status so a modified test is not mistaken for a new one', () => {
    expect(wf).toMatch(/git diff --name-status --no-renames/);
  });
  it('has a fork-gate that is red until a maintainer labels, never skips forks, and never reads the secret', () => {
    const fork = wf.slice(wf.indexOf('  fork-gate:'));
    expect(fork).toMatch(/head\.repo\.full_name != github\.repository/);
    expect(fork).toMatch(/exit 1/);
    expect(fork).not.toMatch(/CLAUDE_CODE_OAUTH_TOKEN/);
  });
  it('re-runs on the labeled event so a manual label turns the check green', () => {
    expect(wf).toMatch(/github\.event\.action == 'labeled' && github\.event\.label\.name == 'ai-review-passed'/);
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
