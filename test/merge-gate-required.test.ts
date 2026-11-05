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
});
