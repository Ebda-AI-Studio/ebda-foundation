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
  it('checks out the BASE branch (scripts and prompt), never the PR head, in every checkout job (classify, review, state-check)', () => {
    expect((wf.match(/ref: \$\{\{ github\.event\.pull_request\.base\.ref \}\}/g) ?? []).length).toBe(3);
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
  it('a label event gets its own concurrency group, so adding a label never cancels a running bot review', () => {
    const group = /^  group: (.*)$/m.exec(wf)?.[1] ?? '';
    expect(group).toMatch(/github\.event\.action == 'labeled' && 'label' \|\|/);
    expect(wf).toMatch(/cancel-in-progress: true/);
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

describe('approval is never carried across pushes by automation (Ruling AIR-6)', () => {
  const wf2 = readFileSync(join(__dirname, '../.github/workflows/ai-review.yml'), 'utf8');
  const classify2 = wf2.slice(wf2.indexOf('  classify:'), wf2.indexOf('  review:'));
  const fork2 = wf2.slice(wf2.indexOf('  fork-gate:'));
  const BASE_CHANGED = /github\.event\.action != 'edited' \|\| github\.event\.changes\.base\.ref\.from != null/;
  it('every non-label event strips ai-review-passed unconditionally in classify, with no marker or diff comparison', () => {
    expect(classify2).toMatch(/gh pr edit "\$PR" --remove-label ai-review-passed/);
    expect(wf2).not.toMatch(/pass-marker|patch-id|REVIEWED_DIFF/);
  });
  it('a base-branch change (edited event with changes.base) re-runs classify; a title/body edit does not strip', () => {
    expect(classify2).toMatch(BASE_CHANGED);
    expect(fork2).not.toMatch(BASE_CHANGED); // the fork gate runs on EVERY event and decides itself whether to strip
    expect(fork2).toMatch(/BASE_FROM: \$\{\{ github\.event\.changes\.base\.ref\.from \}\}/);
  });
  it('a non-base edit has its own concurrency group so it cannot cancel a running review', () => {
    expect(/^  group: (.*)$/m.exec(wf2)?.[1] ?? '').toMatch(/github\.event\.action == 'edited' && github\.event\.changes\.base\.ref\.from == null && 'edit'/);
  });
});

// ---- every subscribed event ends in a REAL "AI review" conclusion (a skipped required check can read as green) ----
type Ctx = { action: string; label?: string; draft: boolean; fork: boolean; baseFrom?: string };
function jobs(text: string) {
  const body = text.slice(text.indexOf('\njobs:\n') + 1);
  return body.split(/\n(?=  [a-z-]+:\n)/).slice(1).map((blk) => ({
    id: /^  ([a-z-]+):/.exec(blk)![1],
    name: /^    name: (.+)$/m.exec(blk)?.[1] ?? '',
    cond: /^    if: (.+)$/m.exec(blk)?.[1] ?? 'true',
    needs: /^    needs: (\w[\w-]*)$/m.exec(blk)?.[1],
  }));
}
function evalIf(cond: string, g: Record<string, unknown>): boolean {
  const lookup = (path: string) => path.split('.').reduce<any>((o, k) => (o == null ? undefined : o[k]), g);
  const js = cond.replace(/\b(?:github|needs)\.[A-Za-z0-9_.-]+/g, (m) => `__g(${JSON.stringify(m)})`);
  // eslint-disable-next-line no-new-func
  return Boolean(new Function('__g', `return (${js});`)((p: string) => lookup(p)));
}
function ghContext(c: Ctx, risky: '' | 'true' | 'false'): Record<string, unknown> {
  return {
    github: { repository: 'o/r', event: { action: c.action, label: c.label ? { name: c.label } : undefined, changes: c.baseFrom ? { base: { ref: { from: c.baseFrom } } } : undefined, pull_request: { draft: c.draft, head: { repo: { full_name: c.fork ? 'f/r' : 'o/r' } } } } },
    needs: { classify: { outputs: { risky } } },
  };
}
// the events the same-repo workflow subscribes to (the copy lists them in `types:`; the reusable file inherits them from its caller)
const EVENTS: Ctx[] = [
  ...['opened', 'synchronize', 'reopened', 'ready_for_review'].flatMap((action) => [false, true].flatMap((draft) => [false, true].map((fork) => ({ action, draft, fork })))),
  ...[false, true].flatMap((draft) => [false, true].flatMap((fork) => [
    { action: 'labeled', label: 'ai-review-passed', draft, fork }, { action: 'labeled', label: 'bug', draft, fork },
    { action: 'edited', baseFrom: 'main', draft, fork }, { action: 'edited', draft, fork },
  ])),
];

describe('every subscribed event yields a non-skipped "AI review" check', () => {
  const wf3 = readFileSync(join(__dirname, '../.github/workflows/ai-review.yml'), 'utf8');
  const all = jobs(wf3);
  const reviewJobs = all.filter((j) => j.name === 'AI review');
  it('finds the five jobs named "AI review" and the classify job', () => {
    expect(reviewJobs.map((j) => j.id).sort()).toEqual(['fork-gate', 'manual-pass', 'not-risky', 'review', 'state-check']);
    expect(all.find((j) => j.id === 'classify')).toBeTruthy();
  });
  it.each(EVENTS.map((e) => [JSON.stringify(e), e] as const))('%s', (_n, e) => {
    for (const risky of ['true', 'false'] as const) {
      const classify = all.find((j) => j.id === 'classify')!;
      const classifyRuns = evalIf(classify.cond, ghContext(e, ''));
      const outputs = classifyRuns ? risky : '';
      const ctx = ghContext(e, outputs as '' | 'true' | 'false');
      const running = reviewJobs.filter((j) => evalIf(j.cond, ctx)).map((j) => j.id);
      expect(running.length, `no "AI review" job runs for ${JSON.stringify(e)} (classify ${classifyRuns ? 'ran, risky=' + risky : 'skipped'})`).toBeGreaterThan(0);
    }
  });
  it('a title/body edit and an unrelated label never strip the label', () => {
    const classify = all.find((j) => j.id === 'classify')!;
    for (const e of EVENTS.filter((x) => (x.action === 'edited' && !x.baseFrom) || (x.action === 'labeled' && x.label !== 'ai-review-passed'))) {
      expect(evalIf(classify.cond, ghContext(e, '')), JSON.stringify(e)).toBe(false);
    }
    const fork = wf3.slice(wf3.indexOf('  fork-gate:'));
    expect(fork).toMatch(/\[ "\$ACTION" = edited \] && \[ -z "\$BASE_FROM" \] && strip=0/);
    expect(wf3.slice(wf3.indexOf('  state-check:'), wf3.indexOf('  # A same-repo PR a maintainer labelled')).includes('remove-label')).toBe(false);
  });
});
