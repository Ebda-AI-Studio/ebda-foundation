// The merge rule lives in the hands (4a carried requirement 2) and must not drift from the brain's classifier.
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { DESTRUCTIVE, mayAutoMerge, mayWork, PRE_APPROVED_KINDS, SENSITIVE } from '../lib/policy.mjs';

const job = (kind, x = {}) => ({ id: 'job_1', mergePolicy: 'auto-when-gate-green', finding: { kind, key: 'k', title: 't', repo: 'o/r', ...(x.finding ?? {}) }, ...x });

describe('mayAutoMerge', () => {
  it('allows every pre-approved class with the auto policy', () => {
    for (const k of ['dep-bump', 'dependency-advisory', 'cve-bump', 'docs', 'test', 'tests', 'lint', 'flaky-test']) expect(mayAutoMerge(job(k)).ok).toBe(true);
  });
  it('refuses any other class, the pr-and-question policy, and destructive/sensitive touches', () => {
    expect(mayAutoMerge(job('ci-failure')).ok).toBe(false);
    expect(mayAutoMerge(job('prod-outage')).ok).toBe(false);
    expect(mayAutoMerge(job('docs', { mergePolicy: 'pr-and-question' })).ok).toBe(false);
    expect(mayAutoMerge(job('dependency-advisory', { finding: { kind: 'dependency-advisory', touches: ['payment'] } })).ok).toBe(false);
    expect(mayAutoMerge(job('docs', { finding: { kind: 'docs', touches: ['secrets'] } })).ok).toBe(false);
  });
});

describe('mayWork', () => {
  it('destructive classes are never worked on unattended; only an explicit proceed answer unlocks them', () => {
    expect(mayWork(job('data-deletion')).ok).toBe(false);
    expect(mayWork(job('docs', { finding: { kind: 'docs', touches: ['billing'] } })).ok).toBe(false);
    expect(mayWork(job('data-deletion', { answer: 'proceed' })).ok).toBe(true);
    expect(mayWork(job('docs')).ok).toBe(true);
  });
});

describe('parity with the brain classifier', () => {
  it('PRE_APPROVED_KINDS, DESTRUCTIVE and SENSITIVE equal os/cloud/brain/src/classify.ts', () => {
    const src = readFileSync(join(import.meta.dirname, '..', '..', 'brain', 'src', 'classify.ts'), 'utf8');
    const set = src.match(/PRE_APPROVED_KINDS = new Set\(\[([^\]]*)\]\)/)[1].split(',').map((s) => s.trim().replace(/'/g, '')).filter(Boolean);
    expect([...PRE_APPROVED_KINDS].sort()).toEqual(set.sort());
    expect(src).toContain(`const DESTRUCTIVE = ${DESTRUCTIVE.toString()};`);
    expect(src).toContain(`const SENSITIVE = ${SENSITIVE.toString()};`);
  });
});
