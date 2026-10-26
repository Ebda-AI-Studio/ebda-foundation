import { Hono } from 'hono';
import { BRAND, getProduct } from '@ebda/foundation/brand';

export interface Env {
  PRODUCT_ID: string;
  /** Set by the deploy workflow to the deployed commit; /health reports it so deploy-verify can compare. */
  GIT_COMMIT?: string;
  DB: D1Database;
  WORKSPACE: DurableObjectNamespace;
}

/** One Durable Object per workspace (tenant). Fill in with the product's state; migrations are assigned by the controller. */
export class Workspace implements DurableObject {
  constructor(private readonly state: DurableObjectState) {}
  async fetch(): Promise<Response> {
    const n = ((await this.state.storage.get<number>('hits')) ?? 0) + 1;
    await this.state.storage.put('hits', n);
    return Response.json({ hits: n });
  }
}

export const app = new Hono<{ Bindings: Env }>();

app.get('/health', (c) => {
  const product = getProduct(c.env.PRODUCT_ID);
  return c.json({ ok: true, product: product.nameEn, studio: BRAND.name, commit: c.env.GIT_COMMIT ?? 'dev' });
});

export default app;
