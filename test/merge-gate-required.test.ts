import { spawnSync } from 'node:child_process';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
// @ts-expect-error plain ESM script without types
import { requiredChecks } from '../ops/merge-gate-required.mjs';

const GUARD = "github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository";
function wf(jobs: Record<string, string | null>): string {
  const body = Object.entries(jobs).map(([id, cond]) => `  ${id}:\n    name: Job ${id}\n${cond ? `    if: ${cond}\n` : ''}    runs-on: ubuntu-latest\n    steps:\n      - run: true\n`).join('');
  return `name: t\non:\n  pull_request:\njobs:\n${body}`;
}
function dir(text: string): string {
  const d = mkdtempSync(join(tmpdir(), 'mgr-'));
  writeFileSync(join(d, 'ci.yml'), text);
  return d;
}

describe('merge-gate-required', () => {
  it('a job whose if is exactly the fork guard is required', () => {
    expect(requiredChecks(dir(wf({ a: GUARD, b: null })))).toEqual(['Job a', 'Job b']);
  });
  it('a job with any other if stays non-required', () => {
    expect(requiredChecks(dir(wf({ a: "github.ref == 'refs/heads/main'", b: `${GUARD} && false`, c: null })))).toEqual(['Job c']);
  });
  it('merge-gate.sh refuses (exit 2, no GitHub call) when no job is required', () => {
    const none = requiredChecks(dir(wf({ a: "github.ref == 'x'" })));
    expect(none).toEqual([]);
    const r = spawnSync('bash', ['ops/merge-gate.sh', '1', 'abcdef1', '--repo', 'o/r'], { encoding: 'utf8', env: { ...process.env, MERGE_GATE_REQUIRED_JSON: JSON.stringify(none) } });
    expect(r.status).toBe(2);
    expect(r.stderr).toContain('could not derive the required checks');
  });

  // GitHub creates no check run for a PR outside a pull_request path filter, so such a workflow can never be required:
  // requiring it waits the full --max-wait-min for a check that will never exist (ebda-store PR 490, 2026-11-09).
  const JOB = (name: string) => `jobs:\n  j:\n    name: ${name}\n    runs-on: ubuntu-latest\n    steps:\n      - run: true\n`;
  function dirOf(files: Record<string, string>): string {
    const d = mkdtempSync(join(tmpdir(), 'mgr-'));
    for (const [f, text] of Object.entries(files)) writeFileSync(join(d, f), text);
    return d;
  }
  it('a workflow whose pull_request trigger is path-filtered contributes no required check', () => {
    const d = dirOf({
      'every.yml': `on:\n  pull_request:\n    branches: [main]\n${JOB('EveryPr')}`,
      'ignore.yml': `on:\n  pull_request:\n    branches: [main]\n    paths-ignore:\n      - 'docs/**'\n      - '*.md'\n  workflow_dispatch:\n${JOB('BlastRadius')}`,
      'paths.yml': `on:\n  pull_request:\n    paths:\n      - 'apps/**'\n${JOB('AppsOnly')}`,
      'inline.yml': `on:\n  pull_request: { paths: ['infra/**'] }\n${JOB('InfraInline')}`,
      'flow.yml': `on: { pull_request: { paths-ignore: ['docs/**'] }, push: { branches: [main] } }\n${JOB('FlowInline')}`,
    });
    expect(requiredChecks(d)).toEqual(['EveryPr']);
  });
  it('a path filter on push only changes nothing: the PR job is still required', () => {
    const d = dirOf({
      'a.yml': `on:\n  push:\n    branches: [main]\n    paths:\n      - 'apps/**'\n  pull_request:\n${JOB('PushFilteredOnly')}`,
      'b.yml': `on:\n  pull_request:\n    branches: [main]\n  push:\n    paths-ignore:\n      - 'docs/**'\n${JOB('PushFilteredOnly2')}`,
    });
    expect(requiredChecks(d)).toEqual(['PushFilteredOnly', 'PushFilteredOnly2']);
  });

  // The rollup keeps superseded runs of a same-name check on the same head. The LATEST run decides
  // (ebda-whatsapp PR 56, 2026-11-09: CANCELLED at 21:16:28Z, SUCCESS at 21:16:32Z, the gate refused twice).
  const SHA = 'abcdef1234567890';
  const T1 = '2026-11-09T21:16:28Z';
  const T2 = '2026-11-09T21:16:32Z';
  type Run = { __typename: 'CheckRun'; name: string; status: string; conclusion: string; startedAt: string; completedAt: string };
  const run = (name: string, status: string, conclusion: string, startedAt: string): Run =>
    ({ __typename: 'CheckRun', name, status, conclusion, startedAt, completedAt: status === 'COMPLETED' ? startedAt : '0001-01-01T00:00:00Z' });
  // Decisive cases get a long wall-clock budget: the gate's deadline is bash $SECONDS (whole seconds), so a 1 s budget is exceeded
  // whenever the first poll straddles a second boundary (ebda-foundation #23 CI, 2026-11-11: status 2 instead of 0). Only the cases that
  // EXPECT the gate to wait and give up pass maxWaitS '1' (the boundary can only make them finish sooner).
  function gate(rollup: unknown[], required: string[] = ['Lint'], maxWaitS = '120') {
    const d = mkdtempSync(join(tmpdir(), 'mg-'));
    writeFileSync(join(d, 'pr.json'), JSON.stringify({ headRefOid: SHA, mergeable: 'MERGEABLE', statusCheckRollup: rollup }));
    const r = spawnSync('bash', ['ops/merge-gate.sh', '1', 'abcdef1', '--repo', 'o/r', '--polls', '2', '--interval', '0'], {
      encoding: 'utf8',
      env: { ...process.env, MERGE_GATE_REQUIRED_JSON: JSON.stringify(required), MERGE_GATE_VIEW_CMD: `cat ${join(d, 'pr.json')}`, MERGE_GATE_MERGE_CMD: `echo merged > ${join(d, 'merged')}`, MERGE_GATE_MAX_WAIT_S: maxWaitS },
    });
    return { status: r.status, out: r.stdout + r.stderr, merged: spawnSync('test', ['-f', join(d, 'merged')]).status === 0 };
  }
  it('cancelled then success of the same name merges', () => {
    const r = gate([run('Lint', 'COMPLETED', 'CANCELLED', T1), run('Lint', 'COMPLETED', 'SUCCESS', T2)]);
    expect(r).toMatchObject({ status: 0, merged: true });
  });
  it('the timestamp decides, not the rollup order', () => {
    const r = gate([run('Lint', 'COMPLETED', 'SUCCESS', T2), run('Lint', 'COMPLETED', 'CANCELLED', T1)]);
    expect(r).toMatchObject({ status: 0, merged: true });
  });
  it('success then failure of the same name refuses and merges nothing', () => {
    for (const rollup of [
      [run('Lint', 'COMPLETED', 'SUCCESS', T1), run('Lint', 'COMPLETED', 'FAILURE', T2)],
      [run('Lint', 'COMPLETED', 'FAILURE', T2), run('Lint', 'COMPLETED', 'SUCCESS', T1)],
      [run('Lint', 'COMPLETED', 'SUCCESS', T1), run('Lint', 'COMPLETED', 'CANCELLED', T2)],
    ]) {
      const r = gate(rollup);
      expect(r).toMatchObject({ status: 1, merged: false });
      expect(r.out).toContain('REFUSED PR 1: failing check(s): Lint');
    }
  });
  it('a re-run that has not finished is waited on, whatever the older run said', () => {
    for (const older of ['SUCCESS', 'FAILURE']) {
      const r = gate([run('Lint', 'COMPLETED', older, T1), run('Lint', 'IN_PROGRESS', '', T2)], ['Lint'], '1');
      expect(r).toMatchObject({ status: 2, merged: false });
      expect(r.out).toContain('waiting (not finished: Lint)');
    }
    const queued = gate([run('Lint', 'QUEUED', '', '0001-01-01T00:00:00Z'), run('Lint', 'COMPLETED', 'SUCCESS', T1)], ['Lint'], '1');
    expect(queued).toMatchObject({ status: 2, merged: false });
  });
  it('the same timestamp keeps rollup order: the later entry wins', () => {
    expect(gate([run('Lint', 'COMPLETED', 'SUCCESS', T1), run('Lint', 'COMPLETED', 'FAILURE', T1)])).toMatchObject({ status: 1, merged: false });
    expect(gate([run('Lint', 'COMPLETED', 'FAILURE', T1), run('Lint', 'COMPLETED', 'SUCCESS', T1)])).toMatchObject({ status: 0, merged: true });
  });
  it('an old SUCCESS does not satisfy a required check whose latest run was SKIPPED', () => {
    const r = gate([run('Lint', 'COMPLETED', 'SUCCESS', T1), run('Lint', 'COMPLETED', 'SKIPPED', T2)], ['Lint'], '1');
    expect(r).toMatchObject({ status: 2, merged: false });
    expect(r.out).toContain('required check(s) without an explicit SUCCESS: Lint');
  });
  it('a check that is not required still refuses when its latest run failed', () => {
    const r = gate([run('Lint', 'COMPLETED', 'SUCCESS', T1), run('BlastRadius', 'COMPLETED', 'FAILURE', T1)]);
    expect(r).toMatchObject({ status: 1, merged: false });
    expect(r.out).toContain('failing check(s): BlastRadius');
  });
  it('zero checks is never green: nothing merges', () => {
    for (const rollup of [[], null]) {
      const d = mkdtempSync(join(tmpdir(), 'mg-'));
      writeFileSync(join(d, 'pr.json'), JSON.stringify({ headRefOid: SHA, mergeable: 'MERGEABLE', statusCheckRollup: rollup }));
      const r = spawnSync('bash', ['ops/merge-gate.sh', '1', 'abcdef1', '--repo', 'o/r', '--polls', '1', '--interval', '0'], {
        encoding: 'utf8',
        env: { ...process.env, MERGE_GATE_REQUIRED_JSON: '["Lint"]', MERGE_GATE_VIEW_CMD: `cat ${join(d, 'pr.json')}`, MERGE_GATE_MERGE_CMD: `echo merged > ${join(d, 'merged')}`, MERGE_GATE_MAX_WAIT_S: '1' },
      });
      expect(r.status).toBe(2);
      expect(r.stdout).toContain('waiting (no checks have reported yet)');
      expect(spawnSync('test', ['-f', join(d, 'merged')]).status).toBe(1);
    }
  });
});
