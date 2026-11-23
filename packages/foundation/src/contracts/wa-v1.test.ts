import { describe, expect, it } from 'vitest';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { CONTRACT_VERSION, outboundStoreEventSchema, parseStoreEvent, storeEventSchema } from './wa-v1';
import { WA_V1_CONTRACT_SHA256, parseOutboundStoreEvent } from './wa-v1-verify';

const id = '3f2b8c1e-4a5d-4e6f-8a9b-0c1d2e3f4a5b';
const at = '2026-11-23T10:00:00.000Z';
const key = 'a'.repeat(64);
const env = (type: string, data: unknown) => ({ id, v: 1, storeId: 's1', occurredAt: at, type, data });
const phone = '+201001234567';

const INBOUND: Record<string, unknown> = {
  'store.plan_changed': { planCode: 'pro', includesWhatsApp: true, ownerUserId: 'u1', effectiveAt: at, status: 'past_due', periodEnd: at, pastDueSince: at },
  'store.linked': { ownerUserId: 'u1', storefrontOrigin: 'https://x.ebda.app' },
  'store.unlinked': { ownerUserId: 'u1' },
  'catalog.product_upserted': { productId: 'p', variantIds: ['v'], updatedAt: at },
  'catalog.product_deleted': { productId: 'p', variantIds: [], updatedAt: at },
  'order.created': { orderId: 'o', orderNumber: '1', buyerKey: key, phoneE164: phone, locale: 'ar', totalMinor: 100, currency: 'EGP', paymentMethod: 'cod', channel: 'web' },
  'order.cod_confirmation_requested': { orderId: 'o', buyerKey: key, phoneE164: phone, locale: 'ar', deadlineAt: at, itemCount: 2, storeName: 'S' },
  'order.status_changed': { orderId: 'o', status: 'shipped', updatedAt: at },
  'shipment.updated': { orderId: 'o', shipmentId: 's', status: 'delivered', updatedAt: at },
  'cart.abandoned': { cartId: 'c', buyerKey: key, phoneE164: phone, locale: 'ar', recoveryUrl: 'https://x.ebda.app/c' },
  'customer.erased': { buyerKey: key },
  'customer.consent_changed': { buyerKey: key, marketingOptIn: true, at, wording: { text: 'yes', locale: 'ar' } },
  'store.suspended': { reason: 'unpaid', at },
  'store.reactivated': { at },
  'store.deleted': { at },
};
const OUTBOUND: Record<string, unknown> = {
  'whatsapp.cod_outcome': { orderId: 'o', outcome: 'confirmed', source: 'whatsapp' },
  'whatsapp.order_after_erasure': { orderId: 'o', buyerKey: key },
  'whatsapp.opt_out_changed': { buyerKey: key, optedOut: true, at, version: 1 },
  'whatsapp.entitlement_changed': { packageId: 'p', automation: true, status: 'active', validUntil: at, version: 3 },
};

describe('wa-v1 contract (F5)', () => {
  it('bytes are unchanged since the products carried it (sha256 = the pin both repos used)', () => {
    expect(createHash('sha256').update(readFileSync(new URL('./wa-v1.ts', import.meta.url))).digest('hex')).toBe(WA_V1_CONTRACT_SHA256);
    expect(CONTRACT_VERSION).toBe('1.6');
  });
  it('every inbound event type has a round-trip sample (a new type must add one)', () => {
    const types = storeEventSchema.options.map((o) => o.shape.type.value).sort();
    expect(Object.keys(INBOUND).sort()).toEqual(types);
  });
  it('inbound events round-trip', () => {
    for (const [type, data] of Object.entries(INBOUND)) {
      const wire = JSON.parse(JSON.stringify(env(type, data)));
      const p = parseStoreEvent(wire);
      expect(p.ok, type).toBe(true);
      if (p.ok) expect(JSON.parse(JSON.stringify(p.event))).toEqual(wire);
    }
  });
  it('outbound events round-trip and cover every type', () => {
    expect(Object.keys(OUTBOUND).sort()).toEqual(outboundStoreEventSchema.options.map((o) => o.shape.type.value).sort());
    for (const [type, data] of Object.entries(OUTBOUND)) {
      const wire = JSON.parse(JSON.stringify(env(type, data)));
      const p = parseOutboundStoreEvent(wire);
      expect(p.ok, type).toBe(true);
      if (p.ok) expect(JSON.parse(JSON.stringify(p.event))).toEqual(wire);
    }
  });
  it('refuses by reason: invalid / unknown type / unsupported version', () => {
    expect(parseStoreEvent({})).toEqual({ ok: false, reason: 'invalid' });
    expect(parseStoreEvent(env('nope.x', {}))).toEqual({ ok: false, reason: 'unknown_type' });
    expect(parseStoreEvent({ ...env('store.deleted', { at }), v: 2 })).toEqual({ ok: false, reason: 'unsupported_version' });
    expect(parseStoreEvent(env('order.created', { orderId: 'o' }))).toEqual({ ok: false, reason: 'invalid' });
    expect(parseOutboundStoreEvent(env('store.deleted', { at }))).toEqual({ ok: false, reason: 'unknown_type' });
    expect(parseOutboundStoreEvent(env('whatsapp.cod_outcome', { orderId: 'o' }))).toEqual({ ok: false, reason: 'invalid' });
  });
});
