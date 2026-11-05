// wrangler.jsonc is the deploy contract: crons match the code, no ids/secrets/account in the template, cron weekday trap.
import { describe, expect, it } from 'vitest';
import raw from '../wrangler.jsonc?raw';
import { CRONS, cronName } from '../src/schedule';

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
  });
  it('the Durable Object is SQLite-backed and assets let machine paths reach the Worker first', () => {
    expect(cfg.migrations[0].new_sqlite_classes).toEqual(['BrainDO']);
    for (const p of ['/api/*', '/github/*', '/hands/*', '/pending', '/findings']) expect(cfg.assets.run_worker_first).toContain(p);
  });
});
