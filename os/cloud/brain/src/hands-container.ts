// HandsContainer: the Container-enabled Durable Object behind the `cloudflare-sandbox` hands provider
// (os/cloud/hands/providers/cloudflare-sandbox.mjs). One instance per lane (`hands-nightly`, `hands-urgent`), so at most
// one container per lane ever runs. It is configured only at Task 7 (wrangler.containers.jsonc: `containers` + DO binding
// HANDS_CONTAINER + migration); until then the binding is absent and the provider's start() throws, which the brain records
// as a failed run.
//
// POST /start {runId, kind, capMin, repos?}: refuses when halted (423, F-01), when containers are not configured (503), when
// required secrets are missing (503, names only), or when this lane's container is still running (409). Otherwise boots the image
// with the run's env (credentials from Worker secrets, never baked into the image; a PER-RUN bearer, F-06b; a 1 h GitHub App token
// when configured, F-12) and arms a 1-minute alarm.
// POST /stop {halt?}: destroys the container now (F-04, F-01); halt:true also refuses later starts until POST /resume.
//
// Lifetime (F-04): the container can outlive nothing. The alarm (a) destroys at deadline+5 min, (b) destroys a running container whose
// run state is missing (never re-arms on lost state), (c) enforces an absolute ceiling of CEILING_MIN from the recorded start whatever
// `deadline` says, and (d) arms its next alarm BEFORE it calls destroy(), so a throwing destroy is retried a minute later. The
// platform inactivity timeout is set as well, so a dead alarm chain does not leave a container running (UNCONFIRMED what the platform
// does for a raw ctx.container when its DO goes idle: ruling RR-container-lifetime).
import { DurableObject } from 'cloudflare:workers';
import { appConfigured, mintInstallationTokens } from './gh-app';
import { isPlaceholder, type Env } from './env';
import { runToken } from './runtoken';

const TICK_MS = 60_000;
const GRACE_MS = 5 * 60_000;
/** absolute container ceiling: the largest cap (240 min) + grace; no stored deadline can extend it */
export const CEILING_MIN = 245;

export type ClaudeAuth = 'max' | 'api';
/** Final decision (RR-hands-api-auth): the cloud hands use a Console API key; 'max' stays selectable. Anything but an explicit 'max' is api. */
export const authMode = (env: Partial<Env>): ClaudeAuth => (String(env.HANDS_CLAUDE_AUTH ?? 'api').toLowerCase() === 'max' ? 'max' : 'api');

/** Values the container needs at start, by auth mode; checked by name, never logged. */
export function containerEnvKeys(env: Partial<Env>): string[] {
  const claude = authMode(env) === 'api' ? ['HANDS_ANTHROPIC_API_KEY', 'HANDS_API_SPEND_LIMIT_USD'] : ['CLAUDE_CODE_OAUTH_TOKEN'];
  return ['HANDS_BRAIN_URL', 'HANDS_TOKEN', ...claude, ...(appConfigured(env) ? [] : ['HANDS_GH_TOKEN']), 'HANDS_CONFIG_JSON', 'HANDS_GIT_NAME', 'HANDS_GIT_EMAIL'];
}

export function missingContainerEnv(env: Partial<Env>): string[] {
  const missing = containerEnvKeys(env).filter((k) => isPlaceholder(env[k as keyof Env] as string | undefined));
  // api mode REQUIRES a configured spend limit marker (a positive number of USD): without it the key is an open tab
  if (authMode(env) === 'api' && !missing.includes('HANDS_API_SPEND_LIMIT_USD') && !(Number(env.HANDS_API_SPEND_LIMIT_USD) > 0)) missing.push('HANDS_API_SPEND_LIMIT_USD (a positive USD number)');
  return missing;
}

/** The container's env object: exactly these keys, nothing inherited. In max mode no billable key is in it (F-06). */
export async function buildContainerEnv(env: Partial<Env>, runId: string, ghTokens: Record<string, string> | null): Promise<Record<string, string>> {
  const out: Record<string, string> = {
    HANDS_RUN_ID: runId,
    BRAIN_URL: env.HANDS_BRAIN_URL!,
    // F-06b: the per-run bearer, not the shared secret
    HANDS_TOKEN: await runToken(env.HANDS_TOKEN!, runId),
    HANDS_CONFIG_JSON: env.HANDS_CONFIG_JSON!,
    HANDS_GIT_NAME: env.HANDS_GIT_NAME!,
    HANDS_GIT_EMAIL: env.HANDS_GIT_EMAIL!,
    HANDS_USAGE_THRESHOLD_PCT: String(env.USAGE_WEEKLY_THRESHOLD_PCT ?? '80'),
    HANDS_CLAUDE_AUTH: authMode(env),
  };
  if (authMode(env) === 'api') {
    out.ANTHROPIC_API_KEY = env.HANDS_ANTHROPIC_API_KEY!;
    out.HANDS_API_SPEND_LIMIT_USD = String(env.HANDS_API_SPEND_LIMIT_USD);
  } else out.CLAUDE_CODE_OAUTH_TOKEN = env.CLAUDE_CODE_OAUTH_TOKEN!;
  if (ghTokens) out.HANDS_GH_TOKENS = JSON.stringify(ghTokens);
  else out.GH_TOKEN = env.HANDS_GH_TOKEN!;
  return out;
}

interface RunState {
  runId: string;
  kind: string;
  deadline: number;
  startedAt: number;
}

/** The container lifecycle, free of the Durable Object base class so tests can drive it with a fake storage + container. */
export class HandsLifecycle {
  constructor(
    private readonly storage: Pick<DurableObjectStorage, 'get' | 'put' | 'delete' | 'setAlarm' | 'deleteAlarm'>,
    private readonly container: () => { running: boolean; start(o: unknown): void; destroy(e?: unknown): Promise<void> } | undefined,
    private readonly env: Env,
  ) {}

  private halted(stored: boolean): boolean {
    const v = String(this.env.HANDS_HALT ?? '0').toLowerCase();
    return v === '1' || v === 'true' || stored;
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    if (request.method === 'POST' && url.pathname === '/stop') return this.stop(request);
    if (request.method === 'POST' && url.pathname === '/resume') {
      await this.storage.delete('halt');
      return Response.json({ ok: true });
    }
    if (request.method !== 'POST' || url.pathname !== '/start') return new Response('not found', { status: 404 });
    const body = (await request.json().catch(() => null)) as { runId?: string; kind?: string; capMin?: number; repos?: string[] } | null;
    if (!body || typeof body.runId !== 'string' || !/^[\w-]{1,64}$/.test(body.runId) || !['urgent', 'nightly'].includes(String(body.kind)) || !Number.isInteger(body.capMin) || body.capMin! <= 0 || body.capMin! > 240) {
      return Response.json({ error: 'runId, kind (urgent|nightly) and capMin (1..240) required' }, { status: 400 });
    }
    if (this.halted((await this.storage.get<boolean>('halt')) === true)) return Response.json({ error: 'hands are halted (F-01)' }, { status: 423 });
    const c = this.container();
    if (!c) return Response.json({ error: 'containers are not configured for this Durable Object' }, { status: 503 });
    if (c.running) return Response.json({ error: `the ${body.kind} hands container is still running` }, { status: 409 });
    const missing = missingContainerEnv(this.env);
    if (missing.length) return Response.json({ error: `missing secrets/vars: ${missing.join(', ')}` }, { status: 503 });
    let ghTokens: Record<string, string> | null = null;
    if (appConfigured(this.env)) {
      try {
        ghTokens = await mintInstallationTokens(this.env, (body.repos ?? []).filter((r) => /^[\w.-]+\/[\w.-]+$/.test(r)));
      } catch (e) {
        return Response.json({ error: `GitHub App token: ${(e as Error).message}` }, { status: 502 });
      }
    }
    // cap state + alarm FIRST: if storage fails, no container is started without its cap (review M-5)
    const now = Date.now();
    await this.storage.put<RunState>('run', { runId: body.runId, kind: body.kind!, deadline: now + body.capMin! * 60_000 + GRACE_MS, startedAt: now });
    await this.storage.setAlarm(now + TICK_MS);
    c.start({ enableInternet: true, env: await buildContainerEnv(this.env, body.runId, ghTokens) });
    // platform-side backstop: stop the container after this long without activity even if our alarm chain dies
    try {
      await (c as unknown as { setInactivityTimeout?: (ms: number) => Promise<void> }).setInactivityTimeout?.(body.capMin! * 60_000 + 2 * GRACE_MS);
    } catch {
      // not available on this runtime: the alarm ceiling still holds
    }
    return Response.json({ externalId: `hands-${body.kind}:${body.runId}` }, { status: 202 });
  }

  /** Destroy now (a stuck-run sweep, the global halt). halt:true also refuses later starts until /resume. */
  private async stop(request: Request): Promise<Response> {
    const body = (await request.json().catch(() => null)) as { halt?: boolean } | null;
    if (body?.halt === true) await this.storage.put('halt', true);
    const c = this.container();
    let destroyed = false;
    if (c?.running) {
      await this.storage.setAlarm(Date.now() + TICK_MS); // retried by the alarm if destroy throws
      try {
        await c.destroy(new Error('hands run stopped'));
        destroyed = true;
      } catch (e) {
        console.error('hands container destroy failed on /stop', (e as Error).message);
      }
    } else destroyed = true;
    if (destroyed) {
      await this.storage.delete('run');
      await this.storage.deleteAlarm();
    }
    return Response.json({ ok: destroyed, running: !!c?.running && !destroyed }, { status: destroyed ? 200 : 202 });
  }

  async alarm(): Promise<void> {
    const run = await this.storage.get<RunState>('run');
    const c = this.container();
    if (!c?.running) {
      await this.storage.delete('run');
      return;
    }
    const now = Date.now();
    // lost state is not a licence to run: a running container with no run record, or past its deadline, or past the absolute ceiling, dies
    const ceiling = run?.startedAt ? run.startedAt + CEILING_MIN * 60_000 : 0;
    const due = !run || now >= Math.min(run.deadline, ceiling || Infinity);
    // F-04: the next alarm is armed BEFORE destroy(): a destroy() that throws is retried a minute later
    await this.storage.setAlarm(now + TICK_MS);
    if (!due) return;
    console.error('hands container past its cap (or no run state); destroying', run?.kind ?? 'unknown', run?.runId ?? 'unknown');
    try {
      await c.destroy(new Error('hands run cap reached'));
    } catch (e) {
      console.error('hands container destroy failed; retrying next minute', (e as Error).message);
      return;
    }
    await this.storage.delete('run');
    await this.storage.deleteAlarm();
  }
}

export class HandsContainer extends DurableObject<Env> {
  private lc: HandsLifecycle;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.lc = new HandsLifecycle(ctx.storage, () => ctx.container as never, env);
  }

  fetch(request: Request): Promise<Response> {
    return this.lc.fetch(request);
  }

  alarm(): Promise<void> {
    return this.lc.alarm();
  }
}
