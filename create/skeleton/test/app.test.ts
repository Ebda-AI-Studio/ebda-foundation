import { describe, expect, it } from 'vitest';
import app from '../src/index';

describe('{{name}}', () => {
  it('/health answers with the product, the company and a commit', async () => {
    const res = await app.request('/health', {}, { GIT_COMMIT: 'abc123' });
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ ok: true, product: '{{displayEn}}', company: 'Ebda AI Studio', commit: 'abc123' });
  });
  it('the product name is never a bare "Ebda"', () => {
    expect('{{displayEn}}').toMatch(/^Ebda \S/);
  });
});
