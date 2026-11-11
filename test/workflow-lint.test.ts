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
