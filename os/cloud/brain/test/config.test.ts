// wrangler.jsonc is the deploy contract: crons match the code, no ids/secrets/account in the template, cron weekday trap.
import { describe, expect, it } from 'vitest';
import raw from '../wrangler.jsonc?raw';
import containersRaw from '../wrangler.containers.jsonc?raw';
import { HAIKU_KINDS, modelFor } from '../src/brain-do';
import { CRONS, cronName } from '../src/schedule';

const strip = (t: string) => JSON.parse(t.replace(/^\s*\/\/.*$/gm, '').replace(/,(\s*[}\]])/g, '$1')) as Record<string, any>;
const cfg = JSON.parse(raw.replace(/^\s*\/\/.*$/gm, '').replace(/,(\s*[}\]])/g, '$1')) as Record<string, any>;

describe('wrangler.jsonc', () => {
  it('declares exactly the crons the code handles', () => {
    expect([...cfg.triggers.crons].sort()).toEqual(Object.values(CRONS).sort());
    for (const c of cfg.triggers.crons) expect(cronName(c)).not.toBeNull();
  });
  it('no cron uses a weekday field (Cloudflare: 1 = Sunday, 0 rejected)', () => {
    for (const c of cfg.triggers.crons as string[]) expect(c.trim().split(/\s+/)[4]).toBe('*');
  });
  it('carries no account id, no real KV id and no secret values', () => {
    expect(cfg.account_id).toBeUndefined();
    expect(cfg.kv_namespaces[0].id).toBe('__BRAIN_KV_ID__');
    const names = Object.keys(cfg.vars);
    for (const s of ['GH_WEBHOOK_SECRET', 'RELAY_SECRET', 'GITHUB_TOKEN', 'TELEGRAM_BOT_TOKEN', 'TELEGRAM_CHAT_ID', 'TELEGRAM_WEBHOOK_SECRET', 'HANDS_TOKEN', 'INGEST_TOKEN']) expect(names).not.toContain(s);
    expect(cfg.vars.OS_ORGS).toBe('__OS_ORGS__');
    expect(cfg.vars.DEPLOYED_REPOS).toBe('__DEPLOYED_REPOS__');
  });
  it('the Durable Object is SQLite-backed and assets let machine paths reach the Worker first', () => {
    expect(cfg.migrations[0].new_sqlite_classes).toEqual(['BrainDO']);
    for (const p of ['/api/*', '/github/*', '/hands/*', '/pending', '/findings']) expect(cfg.assets.run_worker_first).toContain(p);
  });
});

// F-02 / F-18 / RR-hands-api-auth: the cost and abuse limits are a contract, tested before Task 7 enables anything.
describe('cost and abuse limits in the deploy config', () => {
  const frag = strip(containersRaw);
  const vars = cfg.vars as Record<string, string>;
  it('the containers block caps instances (<= 2) and the instance type (lite | basic | standard-1), for the HandsContainer class only', () => {
    expect(frag.containers).toHaveLength(1);
    const c = frag.containers[0];
    expect(c.class_name).toBe('HandsContainer');
    expect(Number.isInteger(c.max_instances) && c.max_instances >= 1 && c.max_instances <= 2).toBe(true);
    expect(['lite', 'basic', 'standard-1']).toContain(c.instance_type);
    expect(frag.durable_objects.bindings.map((b: { name: string }) => b.name)).toEqual(['BRAIN', 'HANDS_CONTAINER']);
    expect(frag.migrations.at(-1).new_sqlite_classes).toEqual(['HandsContainer']);
  });
  it('the base template does not enable containers (the vitest runtime must never build an image)', () => {
    expect(cfg.containers).toBeUndefined();
  });
  it('run lengths and counts are capped: nightly <= 120 min, urgent <= 45 min, urgent runs <= 5 a day, Mac <= 10 jobs a day', () => {
    expect(Number(vars.HANDS_NIGHTLY_RUN_CAP_MIN)).toBeLessThanOrEqual(120);
    expect(Number(vars.URGENT_RUN_CAP_MIN)).toBeLessThanOrEqual(45);
    expect(Number(vars.URGENT_RUNS_PER_DAY)).toBeLessThanOrEqual(5);
    expect(Number(vars.HANDS_MAC_JOBS_PER_DAY)).toBeLessThanOrEqual(10);
    expect(Number(vars.HANDS_NIGHTLY_RUN_CAP_MIN)).toBeGreaterThan(0);
  });
  it('the Worker has resource limits: cpu_ms <= 30000 and subrequests <= 500', () => {
    expect(cfg.limits.cpu_ms).toBeLessThanOrEqual(30000);
    expect(cfg.limits.subrequests).toBeLessThanOrEqual(500);
  });
  it('the hands start un-halted, on the API key, with the declared Console spend limit ($200) under which the monthly budget sits', () => {
    expect(vars.HANDS_HALT).toBe('0');
    expect(vars.HANDS_CLAUDE_AUTH).toBe('api');
    expect(Number(vars.HANDS_API_SPEND_LIMIT_USD)).toBe(200);
    expect(Number(vars.HANDS_MONTHLY_BUDGET_USD)).toBeLessThan(Number(vars.HANDS_API_SPEND_LIMIT_USD));
    expect(Object.keys(vars).filter((k) => /API_SPEND_LIMIT/.test(k))).toEqual(['HANDS_API_SPEND_LIMIT_USD']); // one env name
  });
  it('the brain\'s own Cloudflare stop is at or below Ahmad\'s $20 alert (and its warn at or below $10)', () => {
    expect(Number(vars.CF_STOP_USD)).toBeLessThanOrEqual(20);
    expect(Number(vars.CF_WARN_USD)).toBeLessThanOrEqual(10);
    expect(Number(vars.CF_WARN_USD)).toBeLessThanOrEqual(Number(vars.CF_STOP_USD));
  });
  it('the per-job budget and the pessimistic charge are set, ordered, and fit the daily budget', () => {
    const pess = Number(vars.HANDS_JOB_PESSIMISTIC_USD);
    const job = Number(vars.HANDS_JOB_BUDGET_USD);
    expect(pess > 0 && pess <= job).toBe(true);
    expect(job).toBeLessThanOrEqual(Number(vars.HANDS_DAILY_BUDGET_USD));
  });
  it('the monthly dollar budget is set and stays under the $200 credit (<= $190); the daily budget is set and below the monthly', () => {
    const monthly = Number(vars.HANDS_MONTHLY_BUDGET_USD);
    expect(Number.isFinite(monthly) && monthly > 0 && monthly <= 190).toBe(true);
    const daily = Number(vars.HANDS_DAILY_BUDGET_USD);
    expect(daily > 0 && daily < monthly).toBe(true);
  });
  it('no job kind routes to opus by default, and the configured default model is not opus; opus jobs are capped per day', () => {
    expect(vars.HANDS_DEFAULT_MODEL).not.toBe('opus');
    expect(['haiku', 'sonnet']).toContain(vars.HANDS_DEFAULT_MODEL);
    const kinds = ['docs', 'test', 'tests', 'dep-bump', 'dependency-advisory', 'cve-bump', 'lockfile-drift', 'ci-failure', 'prod-outage', 'money-path-broken', 'lint', 'format', 'flaky-test', 'pr-stuck', 'data-exposure', 'secret-leak', 'dream-improvement', 'anything-else'];
    for (const k of [...kinds, ...HAIKU_KINDS]) expect(modelFor({ source: 's', kind: k, key: 'k', title: 't' }, vars.HANDS_DEFAULT_MODEL)).not.toBe('opus');
    expect(Number(vars.HANDS_OPUS_JOBS_PER_DAY)).toBeGreaterThanOrEqual(0);
    expect(Number(vars.HANDS_OPUS_JOBS_PER_DAY)).toBeLessThanOrEqual(5);
  });
});
