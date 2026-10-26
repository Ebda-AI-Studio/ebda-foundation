import { describe, expect, it } from 'vitest';
import { app } from './index';

describe('health', () => {
  it('reports the product, the studio and the commit', async () => {
    const res = await app.request('/health', {}, { PRODUCT_ID: 'crm', GIT_COMMIT: 'abc123' });
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ ok: true, product: 'Ebda CRM', studio: 'Ebda AI Studio', commit: 'abc123' });
  });
  it('an unknown product id is a bug, never a default', async () => {
    const res = await app.request('/health', {}, { PRODUCT_ID: 'nope' });
    expect(res.status).toBe(500);
  });
});
