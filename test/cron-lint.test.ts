import { describe, expect, it } from 'vitest';
import { spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
// @ts-expect-error plain .mjs without types
import { cronsFromWrangler, lintCron, lintWrangler } from '../ops/cron-lint.mjs';

const CLI = resolve(__dirname, '../ops/cron-lint.mjs');

describe('cron-lint', () => {
  it('accepts the schedules the Ebda Workers use today (weekdays as names or *)', () => {
    for (const c of ['23 * * * *', '*/5 * * * *', '2-59/15 * * * *', '17 */6 * * *', '30 21 * * *', '17 1 * * *', '0 5 * * MON', '0 9 * * MON-FRI', '0 9 * * MON,WED,FRI', '0 3 * * SUN', '0 0 1 1 SAT']) expect(lintCron(c)).toEqual([]);
  });
  it('rejects every numeric weekday (0 is invalid, 1 means Sunday), wrong names, out-of-range numbers and the wrong field count', () => {
    expect(lintCron('0 9 * * 0')[0]).toMatch(/write weekday names.*0 is rejected/);
    expect(lintCron('0 9 * * 1')[0]).toMatch(/1 means Sunday, not Monday/);
    expect(lintCron('0 9 * * 1-5')[0]).toMatch(/write weekday names/);
    expect(lintCron('0 9 * * 7')[0]).toMatch(/write weekday names/);
    expect(lintCron('0 9 * * MON,0')[0]).toMatch(/write weekday names/);
    expect(lintCron('0 9 * * MONDAY')[0]).toMatch(/only \* or the names/);
    expect(lintCron('0 9 * * mon')[0]).toMatch(/only \* or the names/);
    expect(lintCron('0 9 * * ?')[0]).toMatch(/only \* or the names/);
    expect(lintCron('60 * * * *')[0]).toMatch(/minute 60 is outside 0-59/);
    expect(lintCron('0 24 * * *')[0]).toMatch(/hour 24/);
    expect(lintCron('0 0 0 * *')[0]).toMatch(/day of month 0/);
    expect(lintCron('0 0 * 13 *')[0]).toMatch(/month 13/);
    expect(lintCron('* * * *')[0]).toMatch(/exactly 5 fields/);
    expect(lintCron('0 0 * JAN *')[0]).toMatch(/month "JAN"/);
    expect(lintCron('0 0 ? * *')[0]).toMatch(/day of month "\?": only digits/);
  });
  it('reads crons from jsonc (comments, trailing commas, env blocks) and toml', () => {
    const jsonc = `{\n // c\n "triggers": { "crons": ["1 * * * *", /* x */ "2 * * * *",], },\n "env": { "prod": { "triggers": { "crons": ["3 * * * *"] } } } }`;
    expect(cronsFromWrangler(jsonc, 'wrangler.jsonc')).toEqual(['1 * * * *', '2 * * * *', '3 * * * *']);
    expect(cronsFromWrangler('[triggers]\ncrons = ["4 * * * *", \'5 * * * *\']\n', 'wrangler.toml')).toEqual(['4 * * * *', '5 * * * *']);
    expect(lintWrangler('{"triggers":{"crons":["0 9 * * 0"]}}', 'w.jsonc')[0]).toMatch(/^w\.jsonc: "0 9 \* \* 0": /);
  });
  it('the CLI exits 1 on a bad schedule (naming file and expression), 0 when clean, 2 on a missing path', () => {
    const d = mkdtempSync(join(tmpdir(), 'cl-'));
    mkdirSync(join(d, 'apps/a'), { recursive: true });
    mkdirSync(join(d, 'node_modules/x'), { recursive: true });
    writeFileSync(join(d, 'node_modules/x/wrangler.jsonc'), '{"triggers":{"crons":["0 9 * * 0"]}}');
    writeFileSync(join(d, 'apps/a/wrangler.jsonc'), '{"triggers":{"crons":["0 9 * * MON"]}}');
    const ok = spawnSync('node', [CLI, d], { encoding: 'utf8' });
    expect(ok.status).toBe(0);
    expect(ok.stdout).toContain('1 wrangler file(s) checked');
    writeFileSync(join(d, 'apps/a/wrangler.jsonc'), '{"triggers":{"crons":["0 9 * * 0"]}}');
    const bad = spawnSync('node', [CLI, d], { encoding: 'utf8' });
    expect(bad.status).toBe(1);
    expect(bad.stderr).toContain('apps/a/wrangler.jsonc: "0 9 * * 0"');
    expect(spawnSync('node', [CLI, join(d, 'nope')], { encoding: 'utf8' }).status).toBe(2);
  });
});
