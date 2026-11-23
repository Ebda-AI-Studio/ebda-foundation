import { describe, expect, it } from 'vitest';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, writeFileSync, existsSync, readFileSync, readdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

// Ported from ebda-store tests/unit/ops/merge-gate.test.ts (F10): the SAME cases run against ops/merge-gate.sh here and, through the
// thin wrapper, against the vendored copy in the Store. Cases that read the Store's own workflows stay in the Store.
const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const GATE = join(ROOT, 'ops/merge-gate.sh');
const REQ = [
  'API Worker boots on workerd',
  'App builds (affected)',
  'Deploy workflow changes need the deploy-change label',
  'Detect affected workspaces',
  'Repo guards',
  'Scan for leaked secrets',
  // MERGE-QUEUE-1 part B: always reports on a pull request (skip=false at once), so the drain waits for it like any always-on check
  'Tested tree check',
  'Unit Tests (affected)',
];
// The gate is bounded by POLL COUNT here, never by wall clock: under host load a wall-clock budget made merge
// cases refuse (240 s runs at load 22). Merge cases need 3 polls; waiting cases give up after MAX_POLLS.
const MAX_POLLS = 8;
const SHA = 'abcdef1234567890abcdef1234567890abcdef12';

type Check = {
  name: string;
  status?: string;
  conclusion?: string | null;
  startedAt?: string;
  completedAt?: string;
};
const run = (
  checks: Check[],
  over: {
    head?: string;
    mergeable?: string;
    want?: string;
    polls?: string;
    state?: string;
  } = {}
) => {
  const dir = mkdtempSync(join(tmpdir(), 'mg-'));
  const view = join(dir, 'view.json');
  writeFileSync(
    view,
    JSON.stringify({
      ...(over.state ? { state: over.state } : {}),
      headRefOid: over.head ?? SHA,
      mergeable: over.mergeable ?? 'MERGEABLE',
      statusCheckRollup: checks.map(c => ({
        __typename: 'CheckRun',
        status: 'COMPLETED',
        conclusion: 'SUCCESS',
        ...c,
      })),
    })
  );
  const merged = join(dir, 'merged');
  const r = spawnSync(
    'bash',
    [
      GATE,
      '1',
      over.want ?? SHA.slice(0, 9),
      '--polls',
      over.polls ?? '3',
      '--interval',
      '0',
      '--dry-run',
    ],
    {
      env: {
        ...process.env,
        MERGE_GATE_VIEW_CMD: `cat ${view}`,
        MERGE_GATE_REQUIRED_JSON: JSON.stringify(REQ),
        MERGE_GATE_MAX_WAIT_S: '86400',
        MERGE_GATE_MAX_TICKS: String(MAX_POLLS),
      },
      encoding: 'utf8',
    }
  );
  // second run WITHOUT --dry-run through the merge seam, to prove the real merge call happens (and only when green)
  const r2 = spawnSync(
    'bash',
    [GATE, '1', over.want ?? SHA.slice(0, 9), '--polls', over.polls ?? '3', '--interval', '0'],
    {
      env: {
        ...process.env,
        MERGE_GATE_VIEW_CMD: `cat ${view}`,
        MERGE_GATE_REQUIRED_JSON: JSON.stringify(REQ),
        MERGE_GATE_MAX_WAIT_S: '86400',
        MERGE_GATE_MAX_TICKS: String(MAX_POLLS),
        MERGE_GATE_MERGE_CMD: `echo "$sha" > ${merged}`,
      },
      encoding: 'utf8',
    }
  );
  return {
    dry: r,
    status: r2.status,
    out: r2.stdout + r2.stderr,
    merged: existsSync(merged) ? readFileSync(merged, 'utf8').trim() : null,
  };
};
const green = REQ.map(name => ({ name }));

describe('merge-gate.sh', () => {
  it('no checks at all -> refuses (never merges "nothing reported yet")', () => {
    const r = run([]);
    expect(r.status).toBe(2);
    expect(r.merged).toBeNull();
    expect(r.out).toContain('no checks have reported yet');
  });
  it('a queued / in-progress check -> refuses', () => {
    const r = run([
      ...green,
      { name: 'Unit Tests (affected)', status: 'QUEUED', conclusion: null },
    ]);
    expect(r.status).toBe(2);
    expect(r.merged).toBeNull();
    expect(r.out).toContain('Unit Tests (affected)');
  });
  it('a failed required check -> refuses at once (exit 1)', () => {
    const r = run(green.map(c => (c.name === 'Repo guards' ? { ...c, conclusion: 'FAILURE' } : c)));
    expect(r.status).toBe(1);
    expect(r.merged).toBeNull();
    expect(r.out).toContain('failing check(s): Repo guards');
  });
  it('a failed non-required check -> refuses too (any failure blocks)', () => {
    const r = run([...green, { name: 'Lint', conclusion: 'FAILURE' }]);
    expect(r.status).toBe(1);
    expect(r.merged).toBeNull();
  });
  it('a required check that is SKIPPED (no explicit SUCCESS) -> refuses', () => {
    const r = run(green.map(c => (c.name === 'Repo guards' ? { ...c, conclusion: 'SKIPPED' } : c)));
    expect(r.status).toBe(2);
    expect(r.merged).toBeNull();
    expect(r.out).toContain('without an explicit SUCCESS: Repo guards');
  });
  it('blast-radius, when it does run and FAILS, still refuses (not required is not ignored)', () => {
    const r = run([...green, { name: 'blast-radius', conclusion: 'FAILURE' }]);
    expect(r.status).toBe(1);
    expect(r.merged).toBeNull();
  });
  it('an OLD failed run of a check followed by a NEWER passing run of the same name -> merges (latest run wins)', () => {
    const r = run([
      {
        name: 'Deploy workflow changes need the deploy-change label',
        conclusion: 'FAILURE',
        startedAt: '2026-10-29T10:00:00Z',
        completedAt: '2026-10-29T10:01:00Z',
      },
      ...green.filter(c => c.name !== 'Deploy workflow changes need the deploy-change label'),
      {
        name: 'Deploy workflow changes need the deploy-change label',
        conclusion: 'SUCCESS',
        startedAt: '2026-10-29T10:30:00Z',
        completedAt: '2026-10-29T10:31:00Z',
      },
    ]);
    expect(r.status).toBe(0);
    expect(r.merged).toBe(SHA);
  });
  it('the latest run wins whatever order the rollup lists them in', () => {
    const r = run(
      ([
        ...green,
        {
          name: 'Repo guards',
          conclusion: 'FAILURE',
          startedAt: '2026-10-29T10:00:00Z',
          completedAt: '2026-10-29T10:01:00Z',
        },
      ] as Check[]).map(c =>
        c.name === 'Repo guards' && !c.startedAt ? { ...c, startedAt: '2026-10-29T11:00:00Z' } : c
      )
    );
    expect(r.status).toBe(0);
  });
  it('a NEWER failed run after an older passing run of the same name -> still refuses', () => {
    const r = run([
      ...green.filter(c => c.name !== 'Repo guards'),
      {
        name: 'Repo guards',
        conclusion: 'SUCCESS',
        startedAt: '2026-10-29T10:00:00Z',
        completedAt: '2026-10-29T10:01:00Z',
      },
      {
        name: 'Repo guards',
        conclusion: 'FAILURE',
        startedAt: '2026-10-29T10:30:00Z',
        completedAt: '2026-10-29T10:31:00Z',
      },
    ]);
    expect(r.status).toBe(1);
    expect(r.merged).toBeNull();
    expect(r.out).toContain('failing check(s): Repo guards');
  });
  it('a newer in-progress rerun after an old failure -> waits, never merges', () => {
    const r = run([
      ...green.filter(c => c.name !== 'Repo guards'),
      {
        name: 'Repo guards',
        conclusion: 'FAILURE',
        startedAt: '2026-10-29T10:00:00Z',
        completedAt: '2026-10-29T10:01:00Z',
      },
      {
        name: 'Repo guards',
        status: 'IN_PROGRESS',
        conclusion: null,
        startedAt: '2026-10-29T10:30:00Z',
      },
    ]);
    expect(r.status).toBe(2);
    expect(r.merged).toBeNull();
  });
  it('PR already MERGED by someone else -> exit 0 "already merged", never polls to the deadline, never merges again', () => {
    const r = run([], { state: 'MERGED' });
    expect(r.status).toBe(0);
    expect(r.out).toContain('already merged');
    expect(r.merged).toBeNull();
  });
  it('PR CLOSED without merging -> refuses at once (non-zero), no merge', () => {
    const r = run(green, { state: 'CLOSED' });
    expect(r.status).toBe(1);
    expect(r.out).toContain('closed without merging');
    expect(r.merged).toBeNull();
  });
  it('head moved since review -> refuses at once', () => {
    const r = run(green, { head: 'ffffff1234567890ffffff1234567890ffffff12' });
    expect(r.status).toBe(1);
    expect(r.out).toContain('head moved');
    expect(r.merged).toBeNull();
  });
  it('mergeable UNKNOWN or CONFLICTING -> does not merge', () => {
    expect(run(green, { mergeable: 'UNKNOWN' }).merged).toBeNull();
    expect(run(green, { mergeable: 'CONFLICTING' }).merged).toBeNull();
  });
  it('optional skipped checks are fine: all required SUCCESS + skipped others -> merges at the pinned sha', () => {
    const r = run([
      ...green,
      { name: 'Lint', conclusion: 'SKIPPED' },
      { name: 'Mutation tests', conclusion: 'NEUTRAL' },
    ]);
    expect(r.status).toBe(0);
    expect(r.merged).toBe(SHA);
    expect(r.out).toContain('green poll 3/3');
    expect(r.dry.stdout).toContain('DRY RUN');
  });
  it('needs the full streak: --polls 3 does not merge on the first green poll', () => {
    const r = run(green);
    expect(r.out.match(/green poll/g)?.length).toBe(3);
  });
});

describe('merge-gate.sh safety rails in the script itself', () => {
  it('the real merge is pinned to the reviewed commit and squash-deletes the branch', () => {
    const src = readFileSync(GATE, 'utf8');
    expect(src).toContain('--match-head-commit "$sha"');
    expect(src).toContain('--squash --delete-branch');
  });
});
