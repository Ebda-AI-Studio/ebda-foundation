import type { Capability, GuardConfig } from '../../packages/foundation/src/capability';

/** A valid live entry; override per test. Lives outside packages/ so it is never vendored. */
export function entry(over: Partial<Capability> = {}): Capability {
  return {
    id: 'orders.list',
    status: 'live',
    area: 'orders',
    version: 1,
    versionDate: '2026-11-14',
    titleAr: 'الطلبات',
    titleEn: 'Orders',
    screens: ['/stores/[id]/orders'],
    api: ['GET /stores/:id/orders'],
    mcpTool: null,
    planGate: null,
    roles: ['owner'],
    policy: 'free',
    undo: { class: 'none' },
    helpArticle: 'orders',
    questions: { ar: ['a', 'b', 'c'], en: ['a'] },
    steps: [],
    edgeCases: [],
    gaps: [],
    ...over,
  };
}

export const cfg: GuardConfig = { product: 'test', mustConfirm: [{ method: 'POST', pattern: '/refunds' }], routeKinds: [], helpExemptAreas: [], smartLayerPaths: [] };
