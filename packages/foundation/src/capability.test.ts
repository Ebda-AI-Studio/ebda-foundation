import { describe, expect, it } from 'vitest';
import { capabilitySchema, guardConfigSchema, helpUrl, normalizeApi, OPERATOR_REASONS, POLICIES, STATUSES, UNDO_CLASSES } from './capability';

export const minimal = {
  id: 'onboarding.signup',
  status: 'live',
  area: 'onboarding',
  version: 1,
  versionDate: '2026-11-14',
  titleAr: 'تسجيل',
  titleEn: 'Sign up',
  screens: ['/signup'],
  api: ['POST /auth/signup'],
  mcpTool: null,
  planGate: null,
  roles: ['public'],
  policy: 'confirm',
  undo: { class: 'irreversible' },
  helpArticle: null,
  questions: { ar: ['a', 'b', 'c'], en: ['a'] },
  steps: [],
  edgeCases: [],
  gaps: [],
};

describe('capabilitySchema', () => {
  it('parses a minimal valid entry', () => expect(capabilitySchema.safeParse(minimal).success).toBe(true));
  it('a live entry with no helpArticle and no helpGap still parses (the help rule is a guard)', () => {
    expect(capabilitySchema.safeParse({ ...minimal, helpArticle: null }).success).toBe(true);
  });
  it('rejects an unknown policy', () => expect(capabilitySchema.safeParse({ ...minimal, policy: 'maybe' }).success).toBe(false));
  it('rejects a bad id', () => expect(capabilitySchema.safeParse({ ...minimal, id: 'Bad Id' }).success).toBe(false));
  it('rejects a non-ISO versionDate', () => expect(capabilitySchema.safeParse({ ...minimal, versionDate: '14/11/2026' }).success).toBe(false));
  it('accepts a readOnlyPost flag with a reason', () => {
    expect(capabilitySchema.safeParse({ ...minimal, readOnlyPost: { reason: 'only pulls Meta state' } }).success).toBe(true);
    expect(capabilitySchema.safeParse({ ...minimal, readOnlyPost: {} }).success).toBe(false);
  });
});

describe('enums', () => {
  it('has the exact values', () => {
    expect(POLICIES).toEqual(['free', 'preview', 'confirm', 'forbidden']);
    expect(STATUSES).toEqual(['live', 'in-pr', 'planned']);
    expect(UNDO_CLASSES).toContain('unclassified');
    expect(OPERATOR_REASONS).toEqual(['abuse', 'legal', 'money-dispute', 'platform-config', 'critical']);
  });
});

describe('normalizeApi', () => {
  it('upper-cases, drops trailing slash, folds params', () => expect(normalizeApi('get /stores/:storeId/orders/')).toBe('GET /stores/:_/orders'));
  it('decodes percent escapes', () => expect(normalizeApi('GET /ord%65rs')).toBe('GET /orders'));
  it('collapses double slashes', () => expect(normalizeApi('POST //a//b')).toBe('POST /a/b'));
  it('leaves undecodable text as is', () => expect(normalizeApi('GET /a%zz')).toBe('GET /a%zz'));
});

describe('guardConfigSchema and helpUrl', () => {
  it('parses a config', () => {
    expect(guardConfigSchema.safeParse({ product: 'store', mustConfirm: [{ pattern: '^/pay' }], routeKinds: [{ match: '^/public', kind: 'public' }], helpExemptAreas: [], smartLayerPaths: [] }).success).toBe(true);
  });
  it('builds help urls', () => {
    expect(helpUrl('whatsapp/x', 'en')).toBe('https://help.ebda.app/en/whatsapp/x/');
    expect(helpUrl('x', 'ar')).toBe('https://help.ebda.app/x/');
  });
});
