import { Hono } from 'hono';
import { EBDA } from '../foundation/src/brand';
import { WorkspaceDO } from './workspace-do';

export { WorkspaceDO };

export interface Env {
  DB: D1Database;
  WORKSPACE_DO: DurableObjectNamespace;
  GIT_COMMIT?: string;
}

const app = new Hono<{ Bindings: Env }>();

/** /health: the deploy-verify probe compares `commit` with the tip of main. */
app.get('/health', (c) => c.json({ ok: true, product: '{{displayEn}}', company: EBDA.name, commit: c.env.GIT_COMMIT ?? 'unknown' }));

export default app;
