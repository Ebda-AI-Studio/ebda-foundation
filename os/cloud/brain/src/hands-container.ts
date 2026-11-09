// HandsContainer: the Container-enabled Durable Object behind the `cloudflare-sandbox` hands provider
// (os/cloud/hands/providers/cloudflare-sandbox.mjs). One instance per lane (`hands-nightly`, `hands-urgent`), so at most
// one container per lane ever runs. It is configured only at Task 7 (wrangler `containers` + DO binding HANDS_CONTAINER
// + migration); until then the binding is absent and the provider's start() throws, which the brain records as a failed
// run.
//
// POST /start {runId, kind, capMin}: refuses when containers are not configured (503), when required secrets are missing
// (503, names only), or when this lane's container is still running (409). Otherwise boots the image with the run's env
// (credentials from Worker secrets, never baked into the image) and arms a 1-minute alarm. The alarm keeps the instance
// alive while the batch works (Cloudflare stops an instance soon after its DO goes idle) and destroys the container once
// it passes capMin + 5 minutes. When the container exits on its own, the next alarm sees it stopped and ends the loop.
import { DurableObject } from 'cloudflare:workers';
import { isPlaceholder, type Env } from './env';

const TICK_MS = 60_000;
const GRACE_MS = 5 * 60_000;

/** Values the container needs at start; checked by name, never logged. */
export const CONTAINER_ENV_KEYS = ['HANDS_BRAIN_URL', 'HANDS_TOKEN', 'CLAUDE_CODE_OAUTH_TOKEN', 'HANDS_GH_TOKEN', 'HANDS_CONFIG_JSON', 'HANDS_GIT_NAME', 'HANDS_GIT_EMAIL'] as const;

/** The brain's own host joins the container's egress allowlist (ruling F-I8); the fixed hosts live in hands/lib/egress.mjs. */
export function egressHost(url: string | undefined): string {
  try {
    return new URL(String(url)).hostname;
  } catch {
    return '';
  }
}

export function missingContainerEnv(env: Partial<Env>): string[] {
  return CONTAINER_ENV_KEYS.filter((k) => isPlaceholder(env[k] as string | undefined));
}

interface RunState {
  runId: string;
  kind: string;
  deadline: number;
}

export class HandsContainer extends DurableObject<Env> {
  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    if (request.method !== 'POST' || url.pathname !== '/start') return new Response('not found', { status: 404 });
    const body = (await request.json().catch(() => null)) as { runId?: string; kind?: string; capMin?: number } | null;
    if (!body || typeof body.runId !== 'string' || !/^[\w-]{1,64}$/.test(body.runId) || !['urgent', 'nightly'].includes(String(body.kind)) || !Number.isInteger(body.capMin) || body.capMin! <= 0 || body.capMin! > 240) {
      return Response.json({ error: 'runId, kind (urgent|nightly) and capMin (1..240) required' }, { status: 400 });
    }
    const c = this.ctx.container;
    if (!c) return Response.json({ error: 'containers are not configured for this Durable Object' }, { status: 503 });
    if (c.running) return Response.json({ error: `the ${body.kind} hands container is still running` }, { status: 409 });
    const missing = missingContainerEnv(this.env);
    if (missing.length) return Response.json({ error: `missing secrets/vars: ${missing.join(', ')}` }, { status: 503 });
    // cap state + alarm FIRST: if storage fails, no container is started without its cap (review M-5)
    const now = Date.now();
    await this.ctx.storage.put<RunState>('run', { runId: body.runId, kind: body.kind!, deadline: now + body.capMin! * 60_000 + GRACE_MS });
    await this.ctx.storage.setAlarm(now + TICK_MS);
    c.start({
      enableInternet: true,
      env: {
        HANDS_RUN_ID: body.runId,
        BRAIN_URL: this.env.HANDS_BRAIN_URL!,
        HANDS_TOKEN: this.env.HANDS_TOKEN!,
        CLAUDE_CODE_OAUTH_TOKEN: this.env.CLAUDE_CODE_OAUTH_TOKEN!,
        GH_TOKEN: this.env.HANDS_GH_TOKEN!,
        HANDS_CONFIG_JSON: this.env.HANDS_CONFIG_JSON!,
        HANDS_GIT_NAME: this.env.HANDS_GIT_NAME!,
        HANDS_GIT_EMAIL: this.env.HANDS_GIT_EMAIL!,
        HANDS_EGRESS_ALLOW: egressHost(this.env.HANDS_BRAIN_URL),
        HANDS_USAGE_THRESHOLD_PCT: String(this.env.USAGE_WEEKLY_THRESHOLD_PCT ?? '80'),
      },
    });
    return Response.json({ externalId: `hands-${body.kind}:${body.runId}` }, { status: 202 });
  }

  async alarm(): Promise<void> {
    const run = await this.ctx.storage.get<RunState>('run');
    const c = this.ctx.container;
    if (!c?.running) {
      await this.ctx.storage.delete('run');
      return;
    }
    if (run && Date.now() >= run.deadline) {
      console.error('hands container passed its cap; destroying', run.kind, run.runId);
      await c.destroy(new Error('hands run cap reached'));
      await this.ctx.storage.delete('run');
      return;
    }
    await this.ctx.storage.setAlarm(Date.now() + TICK_MS);
  }
}
