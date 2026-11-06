// Ebda OS brain: the always-on part of the OS on Cloudflare Workers (Amendment A).
//
// Machine routes (no Access; each has its own secret):
//   POST /github/webhook  GitHub org webhook (X-Hub-Signature-256 / GH_WEBHOOK_SECRET). POST / is kept for the old URL.
//   GET  /pending         Mac fallback drain of signed relay events (Bearer RELAY_SECRET), wire format unchanged.
//   POST /findings        Mac watchers / dreaming cycle / self-heal report findings (Bearer INGEST_TOKEN).
//   GET  /hands/runs/:id  POST /hands/jobs/:id/outcome  POST /hands/usage  POST /hands/claim   (Bearer HANDS_TOKEN)
//   POST /telegram/webhook  inline-button answers (X-Telegram-Bot-Api-Secret-Token / TELEGRAM_WEBHOOK_SECRET)
//   GET  /health
// Human routes (behind Cloudflare Access at the edge AND verified here): GET /api/state, POST /api/questions/:id/answer,
// and the static dashboard at /dash/ (Workers Static Assets).
import type { BrainDO } from './brain-do';
import { verifyAccessJwt } from './access';
import { type Env } from './env';
import { validateFinding, type Finding } from './findings';
import { OUTCOME_STATUSES, type JobOutcome } from './hands';
import { checkBearerAuth, mapEvent, mapRunDetail, signEvent, timingSafeEqualStr, verifyGitHubSig, type RelayEvent } from './relay';
import { cronName } from './schedule';
import { validateUsage } from './usage';
import { watchAdvisories } from './watchers/advisories';
import { checkAll, parseTargets } from './watchers/health';
import { runWatchers } from './watchers/run';

export { BrainDO } from './brain-do';
export { HandsContainer } from './hands-container';

const MAX_BODY = 5 * 1024 * 1024;
const JSON_HEADERS = { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store', 'x-content-type-options': 'nosniff' };

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), { status, headers: JSON_HEADERS });
}

export function brainStub(env: Env): DurableObjectStub<BrainDO> {
  return env.BRAIN.get(env.BRAIN.idFromName('brain'));
}

async function readJson(request: Request): Promise<unknown> {
  const len = Number(request.headers.get('content-length') ?? 0);
  if (len > MAX_BODY) throw new Error('body too large');
  const t = await request.text();
  if (t.length > MAX_BODY) throw new Error('body too large');
  return JSON.parse(t);
}

async function handleGitHub(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
  const raw = await request.text();
  if (raw.length > MAX_BODY) return new Response('too large', { status: 413 });
  if (!(await verifyGitHubSig(raw, request.headers.get('X-Hub-Signature-256'), env.GH_WEBHOOK_SECRET))) return new Response('bad signature', { status: 401 });
  const ghEvent = request.headers.get('X-GitHub-Event') ?? '';
  const deliveryId = request.headers.get('X-GitHub-Delivery') ?? '';
  let payload: any;
  try {
    payload = JSON.parse(raw);
  } catch {
    return new Response('bad json', { status: 400 });
  }
  if (ghEvent === 'ping') return new Response(null, { status: 204 });
  // only completed workflow runs matter; requested/in_progress are dropped before any storage call (frugal)
  if (ghEvent !== 'workflow_run' || payload?.action !== 'completed') return new Response(null, { status: 204 });
  const detail = mapRunDetail(payload);
  const slug = String(payload?.repository?.full_name ?? '');
  if (payload?.workflow_run?.conclusion === 'success' && detail.branch === detail.defaultBranch) {
    // a green run on the default branch closes that workflow's open CI finding
    ctx.waitUntil(brainStub(env).resolveFinding({ source: 'ci', kind: 'ci-failure', key: `${slug}:${detail.workflow}` }, 'CI green again'));
    return new Response(null, { status: 204 });
  }
  const mapped = mapEvent(ghEvent, payload);
  if (!mapped || !deliveryId) return new Response(null, { status: 204 });
  const ts = Math.floor(Date.now() / 1000);
  // Mac fallback queue (wire format unchanged from the predecessor relay; RELAY_SECRET unset = brain-only)
  if (env.RELAY_SECRET) {
    const ev: RelayEvent = { id: deliveryId, kind: mapped.kind, ts, target: mapped.target, sig: await signEvent(deliveryId, mapped.kind, ts, mapped.target, env.RELAY_SECRET) };
    await env.EVENTS.put(`ev:${deliveryId}`, JSON.stringify(ev), { expirationTtl: 86400 });
  }
  await brainStub(env).ingestCiEvent({ id: deliveryId, slug: mapped.target.slug, sha: mapped.target.sha, ...detail, ts: ts * 1000 });
  return new Response(null, { status: 204 });
}

async function handlePending(request: Request, env: Env): Promise<Response> {
  if (!checkBearerAuth(request, env.RELAY_SECRET)) return new Response('unauthorized', { status: 401 });
  const list = await env.EVENTS.list({ prefix: 'ev:', limit: 100 });
  const events: unknown[] = [];
  for (const k of list.keys) {
    const v = await env.EVENTS.get(k.name);
    if (v) {
      try {
        events.push(JSON.parse(v));
      } catch {
        // malformed entry: drop it below
      }
    }
    await env.EVENTS.delete(k.name);
  }
  return json(events);
}

async function handleTelegram(request: Request, env: Env): Promise<Response> {
  const secret = request.headers.get('X-Telegram-Bot-Api-Secret-Token') ?? '';
  if (!env.TELEGRAM_WEBHOOK_SECRET || !timingSafeEqualStr(secret, env.TELEGRAM_WEBHOOK_SECRET)) return new Response('unauthorized', { status: 401 });
  let update: any;
  try {
    update = await readJson(request);
  } catch {
    return new Response('bad json', { status: 400 });
  }
  const cb = update?.callback_query;
  // only button answers from the configured chat are accepted; everything else is acknowledged and ignored
  if (!cb || String(cb?.message?.chat?.id ?? '') !== String(env.TELEGRAM_CHAT_ID ?? '')) return new Response(null, { status: 200 });
  const m = String(cb.data ?? '').match(/^q:([\w-]+):([\w-]+)$/);
  let text = 'not understood';
  if (m) {
    const r = await brainStub(env).answerQuestion(m[1]!, m[2]!);
    text = r.ok ? `recorded: ${m[2]}` : r.reason ?? 'refused';
  }
  if (env.TELEGRAM_BOT_TOKEN) {
    await fetch(`https://api.telegram.org/bot${env.TELEGRAM_BOT_TOKEN}/answerCallbackQuery`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ callback_query_id: cb.id, text }),
    }).catch(() => undefined);
  }
  return new Response(null, { status: 200 });
}

async function handleHands(request: Request, env: Env, path: string): Promise<Response> {
  if (!checkBearerAuth(request, env.HANDS_TOKEN)) return new Response('unauthorized', { status: 401 });
  const brain = brainStub(env);
  let m: RegExpMatchArray | null;
  if (request.method === 'GET' && (m = path.match(/^\/hands\/runs\/([\w-]+)$/))) {
    const run = await brain.getRun(m[1]!);
    return run ? json(run) : json({ error: 'no such run' }, 404);
  }
  if (request.method !== 'POST') return new Response('method not allowed', { status: 405 });
  let body: any;
  try {
    body = await readJson(request);
  } catch {
    return json({ error: 'bad json' }, 400);
  }
  if ((m = path.match(/^\/hands\/jobs\/([\w-]+)\/outcome$/))) {
    if (!OUTCOME_STATUSES.includes(body?.status)) return json({ error: `status must be one of ${OUTCOME_STATUSES.join('|')}` }, 400);
    const o: JobOutcome = { status: body.status, ...(typeof body.prUrl === 'string' ? { prUrl: body.prUrl.slice(0, 500) } : {}), ...(typeof body.note === 'string' ? { note: body.note.slice(0, 1000) } : {}), ...(body.drill === 'pass' || body.drill === 'fail' ? { drill: body.drill as 'pass' | 'fail' } : {}) };
    const r = await brain.recordOutcome(m[1]!, o);
    return json(r, r.ok ? 200 : 409);
  }
  if (path === '/hands/usage') {
    const err = validateUsage(body);
    if (err) return json({ error: err }, 400);
    await brain.reportUsage({ weeklyUsedPct: body.weeklyUsedPct, ...(typeof body.resetsAt === 'number' ? { resetsAt: body.resetsAt } : {}) });
    return json({ ok: true });
  }
  if (path === '/hands/claim') {
    const provider = typeof body?.provider === 'string' && /^[\w-]{1,40}$/.test(body.provider) ? body.provider : 'mac-local';
    const max = Number.isInteger(body?.max) ? body.max : 5;
    return json(await brain.claim(provider, max));
  }
  return json({ error: 'not found' }, 404);
}

async function handleApi(request: Request, env: Env, path: string): Promise<Response> {
  const auth = await verifyAccessJwt(request.headers.get('Cf-Access-Jwt-Assertion'), env.ACCESS_TEAM_DOMAIN, env.ACCESS_AUD, Date.now());
  if (!auth.ok) return json({ error: 'forbidden', reason: auth.reason }, auth.reason === 'access not configured' ? 503 : 403);
  const brain = brainStub(env);
  if (request.method === 'GET' && path === '/api/state') return json(await brain.state());
  const m = path.match(/^\/api\/questions\/([\w-]+)\/answer$/);
  if (request.method === 'POST' && m) {
    // same-origin only (defence in depth on top of Access + SameSite cookies)
    if (request.headers.get('Origin') !== new URL(request.url).origin) return json({ error: 'cross-origin' }, 403);
    let body: any;
    try {
      body = await readJson(request);
    } catch {
      return json({ error: 'bad json' }, 400);
    }
    if (typeof body?.option !== 'string') return json({ error: 'option required' }, 400);
    const r = await brain.answerQuestion(m[1]!, body.option);
    return json(r, r.ok ? 200 : 409);
  }
  return json({ error: 'not found' }, 404);
}

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(request.url);
    const path = url.pathname;
    try {
      if (path === '/health') return json({ ok: true, service: 'ebda-os-brain' });
      if (request.method === 'POST' && (path === '/github/webhook' || path === '/')) return await handleGitHub(request, env, ctx);
      if (request.method === 'GET' && path === '/pending') return await handlePending(request, env);
      if (path === '/telegram/webhook' && request.method === 'POST') return await handleTelegram(request, env);
      if (path.startsWith('/hands/')) return await handleHands(request, env, path);
      if (path === '/findings' && request.method === 'POST') {
        if (!checkBearerAuth(request, env.INGEST_TOKEN)) return new Response('unauthorized', { status: 401 });
        let body: unknown;
        try {
          body = await readJson(request);
        } catch {
          return json({ error: 'bad json' }, 400);
        }
        const list = Array.isArray(body) ? body : [body];
        if (list.length > 100) return json({ error: 'at most 100 findings per request' }, 400);
        for (const f of list) {
          const err = validateFinding(f);
          if (err) return json({ error: err }, 400);
        }
        return json(await brainStub(env).ingestMany(list as Finding[]));
      }
      if (path.startsWith('/api/')) return await handleApi(request, env, path);
      if (path === '/' && request.method === 'GET') return Response.redirect(new URL('/dash/', url).toString(), 302);
      return new Response('not found', { status: 404 });
    } catch (e) {
      console.error('brain fetch error', path, (e as Error).message);
      return json({ error: 'internal error' }, 500);
    }
  },

  async scheduled(controller: ScheduledController, env: Env, ctx: ExecutionContext): Promise<void> {
    const now = controller.scheduledTime || Date.now();
    const brain = brainStub(env);
    switch (cronName(controller.cron)) {
      case 'tick': {
        await brain.processCiEvents(now);
        const targets = parseTargets(env.HEALTH_TARGETS);
        if (targets.length) await brain.observeHealth(await checkAll(targets), now);
        await brain.tick(now);
        return;
      }
      case 'quarter':
        await runWatchers('quarter', env, brain, now);
        return;
      case 'hourly':
        await watchAdvisories(env, brain, now);
        await runWatchers('hourly', env, brain, now);
        return;
      case 'sixhourly':
        await runWatchers('sixhourly', env, brain, now);
        return;
      case 'nightly':
        await brain.runNightly(now);
        return;
      case 'digest':
        await brain.digest(now);
        return;
      default:
        // an unknown cron means wrangler.jsonc and src/schedule.ts drifted: loud, never silent
        console.error('unknown cron', controller.cron);
        ctx.waitUntil(Promise.resolve());
    }
  },
} satisfies ExportedHandler<Env>;
