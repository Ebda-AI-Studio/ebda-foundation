import { describe, expect, it } from 'vitest';
// @ts-expect-error plain ESM module without types
import { lintWorkflow } from '../ops/workflow-lint.mjs';

const head = "on:\n  schedule:\n    - cron: '*/10 * * * *'\nconcurrency:\n  group: g\njobs:\n  x:\n";
describe('workflow-lint hosted-only exception', () => {
  it('accepts runs-on: ubuntu-latest under a # hosted-only: <reason> comment', () => {
    expect(lintWorkflow('w.yml', `${head}    # hosted-only: outside-in production watch\n    runs-on: ubuntu-latest\n    timeout-minutes: 5\n`)).toEqual([]);
  });
  it('still rejects a bare ubuntu-latest', () => {
    expect(lintWorkflow('w.yml', `${head}    runs-on: ubuntu-latest\n    timeout-minutes: 5\n`).join('\n')).toMatch(/runs-on must be exactly/);
  });
  it('rejects a hosted-only comment with no reason', () => {
    expect(lintWorkflow('w.yml', `${head}    # hosted-only:\n    runs-on: ubuntu-latest\n    timeout-minutes: 5\n`).join('\n')).toMatch(/runs-on must be exactly/);
  });
  it('rejects a hosted-only job on pull_request', () => {
    const pr = head.replace("on:\n", 'on:\n  pull_request:\n');
    expect(lintWorkflow('w.yml', `${pr}    # hosted-only: outside-in production watch\n    runs-on: ubuntu-latest\n    timeout-minutes: 5\n`).join('\n')).toMatch(/may not run on pull_request/);
  });
});

describe('workflow-lint fork-guard exemption', () => {
  const wf = (job: string) => `name: x\non:\n  pull_request:\nconcurrency:\n  group: g\njobs:\n  a:\n${job}    runs-on: \${{ fromJSON(vars.EBDA_RUNS_ON || '"ubuntu-latest"') }}\n    timeout-minutes: 5\n`;
  it('a pull_request job with neither the guard nor an exemption is flagged', () => {
    expect(lintWorkflow('w.yml', wf('')).join('\n')).toMatch(/without the fork guard/);
  });
  it('a `# fork-guard-exempt: <reason>` comment in the job clears it; a reasonless one does not', () => {
    expect(lintWorkflow('w.yml', wf('    # fork-guard-exempt: only labels the PR, never runs its content\n'))).toEqual([]);
    expect(lintWorkflow('w.yml', wf('    # fork-guard-exempt: x\n')).join('\n')).toMatch(/without the fork guard/);
  });
});

describe('workflow-lint plain run scalar', () => {
  const wf = (run: string) => `name: x\nconcurrency:\n  group: g\njobs:\n  a:\n    runs-on: \${{ fromJSON(vars.EBDA_RUNS_ON || '"ubuntu-latest"') }}\n    timeout-minutes: 5\n    steps:\n      - ${run}\n`;
  it('flags `run: echo "a (b): c"`, the form that made a whole workflow unparseable', () => {
    expect(lintWorkflow('w.yml', wf('run: echo "all-safe diff (docs): no review"')).join('\n')).toMatch(/invalid YAML/);
  });
  it('accepts a block scalar, a quoted scalar and a plain scalar without colon-space', () => {
    expect(lintWorkflow('w.yml', wf('run: |\n          echo "a: b"'))).toEqual([]);
    expect(lintWorkflow('w.yml', wf('run: "echo a: b"'))).toEqual([]);
    expect(lintWorkflow('w.yml', wf('run: echo a - b'))).toEqual([]);
  });
});

