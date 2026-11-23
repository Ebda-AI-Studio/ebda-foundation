import { describe, expect, it } from 'vitest';
// @ts-expect-error plain ESM module without types
import { lintDir, lintWorkflow } from '../ops/workflow-lint.mjs';

const head = "on:\n  schedule:\n    - cron: '*/10 * * * *'\nconcurrency:\n  group: g\njobs:\n  x:\n";
describe('workflow-lint never allows a GitHub-hosted runner (Ruling NO-HOSTED-RUNNERS-1, Ahmad 2026-11-16)', () => {
  const mac = "    runs-on: ${{ fromJSON(vars.EBDA_RUNS_ON || '[\"ebda-mac-light\"]') }}\n    timeout-minutes: 5\n";
  it('accepts the Mac-fallback runs-on', () => {
    expect(lintWorkflow('w.yml', `${head}${mac}`)).toEqual([]);
  });
  it('rejects a bare ubuntu-latest, and a hosted fallback inside the expression', () => {
    expect(lintWorkflow('w.yml', `${head}    runs-on: ubuntu-latest\n    timeout-minutes: 5\n`).join('\n')).toMatch(/GitHub-hosted runner/);
    expect(lintWorkflow('w.yml', `${head}    runs-on: \${{ fromJSON(vars.EBDA_RUNS_ON || '"ubuntu-latest"') }}\n    timeout-minutes: 5\n`).join('\n')).toMatch(/GitHub-hosted runner/);
    expect(lintWorkflow('w.yml', `${head}    runs-on: macos-14\n    timeout-minutes: 5\n`).join('\n')).toMatch(/GitHub-hosted runner/);
  });
  it('the old `# hosted-only: <reason>` exception is gone', () => {
    expect(lintWorkflow('w.yml', `${head}    # hosted-only: outside-in production watch\n    runs-on: ubuntu-latest\n    timeout-minutes: 5\n`).join('\n')).toMatch(/GitHub-hosted runner/);
  });
  it('rejects a setup-node cache input (the remote Actions cache is never used)', () => {
    const step = "    steps:\n      - uses: actions/setup-node@949feb2413d6458794dcd2491c4babbbce0c15c1\n        with:\n          cache: npm\n";
    expect(lintWorkflow('w.yml', `${head}${mac}${step}`).join('\n')).toMatch(/setup-node must not set cache/);
  });
});

describe('workflow-lint fork-guard exemption', () => {
  const wf = (job: string) => `name: x\non:\n  pull_request:\nconcurrency:\n  group: g\njobs:\n  a:\n${job}    runs-on: \${{ fromJSON(vars.EBDA_RUNS_ON || '[\"ebda-mac-light\"]') }}\n    timeout-minutes: 5\n`;
  it('a pull_request job with neither the guard nor an exemption is flagged', () => {
    expect(lintWorkflow('w.yml', wf('')).join('\n')).toMatch(/without the fork guard/);
  });
  it('a `# fork-guard-exempt: <reason>` comment in the job clears it; a reasonless one does not', () => {
    expect(lintWorkflow('w.yml', wf('    # fork-guard-exempt: only labels the PR, never runs its content\n'))).toEqual([]);
    expect(lintWorkflow('w.yml', wf('    # fork-guard-exempt: x\n')).join('\n')).toMatch(/without the fork guard/);
  });
});

describe('workflow-lint plain run scalar', () => {
  const wf = (run: string) => `name: x\nconcurrency:\n  group: g\njobs:\n  a:\n    runs-on: \${{ fromJSON(vars.EBDA_RUNS_ON || '[\"ebda-mac-light\"]') }}\n    timeout-minutes: 5\n    steps:\n      - ${run}\n`;
  it('flags `run: echo "a (b): c"`, the form that made a whole workflow unparseable', () => {
    expect(lintWorkflow('w.yml', wf('run: echo "all-safe diff (docs): no review"')).join('\n')).toMatch(/invalid YAML/);
  });
  it('accepts a block scalar, a quoted scalar and a plain scalar without colon-space', () => {
    expect(lintWorkflow('w.yml', wf('run: |\n          echo "a: b"'))).toEqual([]);
    expect(lintWorkflow('w.yml', wf('run: "echo a: b"'))).toEqual([]);
    expect(lintWorkflow('w.yml', wf('run: echo a - b'))).toEqual([]);
  });
});


describe('workflow-lint short-job any-runner exception (RUNNER-ANY-1)', () => {
  const any = "    runs-on: ${{ fromJSON(vars.EBDA_ANY_RUNS_ON || vars.EBDA_RUNS_ON || '[\"ebda-mac-light\"]') }}\n    timeout-minutes: 5\n";
  it('accepts the any-runner runs-on under a # short-job: <reason> comment', () => {
    expect(lintWorkflow('w.yml', `${head}    # short-job: median 13 s over recent main runs\n${any}`)).toEqual([]);
  });
  it('rejects the any-runner runs-on with no short-job comment', () => {
    expect(lintWorkflow('w.yml', `${head}${any}`).join('\n')).toMatch(/needs a '# short-job: <measured reason>' comment/);
  });
  it('rejects a short-job comment with no reason', () => {
    expect(lintWorkflow('w.yml', `${head}    # short-job:\n${any}`).join('\n')).toMatch(/needs a '# short-job/);
  });
});

describe('the real workflows (Ruling NO-HOSTED-RUNNERS-1)', () => {
  it('lint clean, and no runs-on names a GitHub-hosted runner', () => {
    expect(lintDir(new URL('../.github/workflows', import.meta.url).pathname)).toEqual([]);
  });
});
