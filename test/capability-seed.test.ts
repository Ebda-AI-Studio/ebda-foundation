import { describe, expect, it } from 'vitest';
import { existsSync, mkdtempSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
// @ts-expect-error plain .mjs without types
import { mapUndo, parseRoles, seed } from '../lib/capability-seed.mjs';
import { capabilitySchema } from '../packages/foundation/src/capability';

const FX = resolve(__dirname, 'fixtures/capability');
const run = (product: 'store' | 'chat', out = mkdtempSync(join(tmpdir(), 'cap-seed-'))) => ({ out, r: seed({ catalogue: join(FX, `${product}-mini.json`), product, out, today: '2026-11-14' }) });
const read = (out: string, id: string) => JSON.parse(readFileSync(join(out, `${id}.capability.json`), 'utf8'));

describe('seed: store', () => {
  const { out, r } = run('store');
  it('writes one schema-valid file per row, version 1 dated today', () => {
    expect(r.written).toHaveLength(8);
    for (const f of readdirSync(out)) expect(capabilitySchema.safeParse(JSON.parse(readFileSync(join(out, f), 'utf8'))).success).toBe(true);
    expect(read(out, 'onboarding.signup')).toMatchObject({ version: 1, versionDate: '2026-11-14', titleEn: expect.any(String) });
  });
  it('help/<slug> maps to the slug, a missing article stays null with no helpGap', () => {
    expect(read(out, 'onboarding.signup').helpArticle).toBe('create-your-store');
    expect(read(out, 'store.slug-redirects').helpArticle).toBeNull();
    expect(read(out, 'store.slug-redirects').helpGap).toBeUndefined();
  });
  it('page splits on ; and a route keeps only its path', () => {
    expect(read(out, 'onboarding.signup').screens).toEqual(['/signup']);
    expect(read(out, 'account.password').screens).toEqual(['/account/security', '/forgot-password', '/reset-password']);
  });
  it('pr_or_plan: ebda-store#NNN becomes pr, a path or text becomes plan', () => {
    expect(read(out, 'product.recommendations-auto')).toMatchObject({ pr: 'ebda-store#742' });
    expect(read(out, 'product.recommendations-auto').plan).toBeUndefined();
  });
  it('role keywords: staff cannot is not staff, super_admin only', () => {
    expect(read(out, 'store.slug-redirects').roles).toEqual(['owner', 'super_admin']);
    expect(read(out, 'platform.manual-payment').roles).toEqual(['super_admin']);
  });
  it('an unparseable role string becomes owner plus a gap and is reported', () => {
    expect(read(out, 'account.password').roles).toEqual(['owner']);
    expect(read(out, 'account.password').gaps).toContain('roles unverified');
    expect(r.report.unparsedRoles).toEqual(['account.password']);
  });
  it('the five undo branches', () => {
    expect(read(out, 'onboarding.signup').undo.class).toBe('none');
    expect(read(out, 'store.slug-redirects').undo.class).toBe('irreversible');
    expect(read(out, 'inventory.overview-adjust').undo.class).toBe('compensating');
    expect(read(out, 'product.recommendations-auto').undo.class).toBe('reversible');
    expect(read(out, 'marketing.loyalty').undo.class).toBe('unclassified');
    expect(read(out, 'marketing.loyalty').undo.note).toMatch(/clawback/);
    expect(r.report.unclassifiedUndo).toContain('marketing.loyalty');
  });
  it('operator reason keyword maps to a code and the invalid flag is kept', () => {
    expect(read(out, 'platform.manual-payment').operatorReason).toMatchObject({ code: 'money-dispute', validUnderRule: false });
    expect(read(out, 'platform.feature-overrides').operatorReason.code).toBeNull();
    expect(r.report.invalidOperatorReasons).toContain('platform.manual-payment');
  });
  it('a second run skips every id and leaves file bytes identical (review focus 5)', () => {
    const before = readdirSync(out).map((f) => readFileSync(join(out, f), 'utf8'));
    writeFileSync(join(out, 'inventory.overview-adjust.capability.json'), `${before[readdirSync(out).indexOf('inventory.overview-adjust.capability.json')]!.trim()}\n`);
    const again = seed({ catalogue: join(FX, 'store-mini.json'), product: 'store', out, today: '2030-01-01' });
    expect(again.written).toEqual([]);
    expect(again.skipped).toHaveLength(8);
    expect(readdirSync(out).map((f) => readFileSync(join(out, f), 'utf8'))).toEqual(before);
  });
});

describe('seed: chat', () => {
  const { out, r } = run('chat');
  it('both help doc formats map: docs/help/{ar,en}/NN-slug.md to whatsapp/slug, other docs to null plus helpGap', () => {
    expect(read(out, 'templates.list').helpArticle).toBe('whatsapp/templates-and-the-24-hour-window');
    expect(read(out, 'agent.connectors')).toMatchObject({ helpArticle: null, helpGap: 'docs/connectors.md (developer doc only)' });
  });
  it('web View names found in the screen text become view: screens', () => {
    expect(read(out, 'access.signin').screens).toContain('view:SignInGate');
  });
  it('undo: false on a GET-only entry is none, false on a write is irreversible, true is reversible', () => {
    expect(read(out, 'access.signin').undo.class).toBe('none');
    expect(read(out, 'templates.sync').undo.class).toBe('irreversible');
    expect(read(out, 'agent.connectors').undo.class).toBe('reversible');
  });
  it('plan and pr: planned keeps plan text, in-pr keeps the pr string', () => {
    expect(read(out, 'templates.create-submit').plan).toMatch(/self-service/);
    expect(read(out, 'agent.tone').pr).toMatch(/^ebda-whatsapp#79/);
  });
  it('an unknown system role becomes owner with a gap', () => {
    expect(read(out, 'templates.status-webhook').gaps).toContain('roles unverified');
    expect(r.report.unparsedRoles).toContain('templates.status-webhook');
  });
  it('operator_reason_valid gap becomes validUnderRule false', () => {
    expect(read(out, 'operator.instapay-review').operatorReason.validUnderRule).toBe(false);
  });
  it('chat steps arrays pass through and written files are schema-valid', () => {
    expect(Array.isArray(read(out, 'access.signin').steps)).toBe(true);
    for (const f of readdirSync(out)) expect(capabilitySchema.safeParse(JSON.parse(readFileSync(join(out, f), 'utf8'))).success).toBe(true);
  });
});

describe('mappers', () => {
  it('parseRoles keywords', () => {
    expect(parseRoles('any signed-in merchant user').roles).toEqual(['owner', 'staff']);
    expect(parseRoles('shopper').roles).toEqual(['customer']);
    expect(parseRoles(['owner (write)', 'staff (read)']).roles).toEqual(['owner', 'staff']);
  });
  it('mapUndo text branches', () => {
    expect(mapUndo('yes (edit back)', false).class).toBe('reversible');
    expect(mapUndo('yes (inverse adjustment)', false).class).toBe('compensating');
    expect(mapUndo('no (irreversible)', false).class).toBe('irreversible');
    expect(mapUndo('withdraw claim not documented', false).class).toBe('unclassified');
  });
});

describe.skipIf(!process.env.EBDA_CATALOGUE_DIR)('real catalogues', () => {
  const dir = process.env.EBDA_CATALOGUE_DIR ?? '';
  it('catalogue counts: store 71 and chat 23 need help', () => {
    const stOut = mkdtempSync(join(tmpdir(), 'cap-real-'));
    const st = seed({ catalogue: join(dir, '2026-11-14-store-capability-catalogue.json'), product: 'store', out: stOut, today: '2026-11-14' });
    const ch = seed({ catalogue: join(dir, '2026-11-14-chat-capability-catalogue.json'), product: 'chat', out: mkdtempSync(join(tmpdir(), 'cap-real-')), today: '2026-11-14' });
    for (const f of readdirSync(stOut)) expect(capabilitySchema.safeParse(JSON.parse(readFileSync(join(stOut, f), 'utf8'))).success).toBe(true);
    expect(st.written).toHaveLength(185);
    expect(ch.written).toHaveLength(172);
    expect(st.report.counts.needsHelp).toBe(71);
    expect(ch.report.counts.needsHelp).toBe(23);
  });
});
