// Ebda OS brain: the always-on part of the OS on Cloudflare Workers (Amendment A).
//
// Machine routes (no Access; each has its own secret):
//   POST /github/webhook  GitHub org webhook (X-Hub-Signature-256 / GH_WEBHOOK_SECRET). POST / is kept for the old URL.
//   GET  /pending         Mac fallback drain of signed relay events (Bearer RELAY_SECRET), wire format unchanged.
//   POST /findings        Mac watchers / dreaming cycle / self-heal report findings (Bearer INGEST_TOKEN).
//   POST /findings        also { findings, reconcile: { source, keep? } }: a monitor's complete listing; absent keys resolve (prod-watch).
//   POST|DELETE /leases   HANDS-COORD controller lease on a repo {repo, holder, ttlMin<=240, note?} (Bearer INGEST_TOKEN).
//   POST /drill           the Mac's weekly restore drill result {result:'pass'|'fail'} (Bearer INGEST_TOKEN, ruling F-I6).
//   GET  /hands/leases[?run=id]  live controller leases for the hands (run token or HANDS_MAC_TOKEN)
//   GET  /hands/runs/:id  POST /hands/jobs/:id/outcome  POST /hands/usage  POST /hands/claim  POST /hands/refused   (Bearer HANDS_TOKEN)
//   POST /telegram/webhook  inline-button answers FORWARDED BY THE tg-relay SESSION (it polls @EbdaAIStudiobot; the brain is send-only and
//                           never registers this URL with Telegram). Auth: X-Telegram-Bot-Api-Secret-Token = TELEGRAM_WEBHOOK_SECRET.
//   /social/*             social posting: drafts/edits/calendar (INGEST_TOKEN), decide/brands (SOCIAL_DECIDE_TOKEN), /social/d/:id signed
//                         decision page (src/social/routes.ts)
//   GET  /health
// Human routes: GET /api/state, POST /api/halt, POST /api/questions/:id/answer, and the static dashboard at /dash/ (Workers Static
// Assets, run Worker-first so the HTML/JS/CSS are never served before the gate). All of them go through gateHuman()
// (src/dash-auth.ts, ruling RR-dash-auth): the Cloudflare Access JWT when Access is configured, else the interim Basic Auth,
// else 503. /health stays public and carries no data.
import type { BrainDO } from './brain-do';
import { DASH_HEADERS, gateHuman } from './dash-auth';
import { type Env } from './env';
import { validateFinding, type Finding } from './findings';
import { OUTCOME_STATUSES, type JobOutcome, type JobUsage } from './hands';
import { runTokenValid } from './runtoken';
import { checkBearerAuth, mapEvent, mapRunDetail, signEvent, timingSafeEqualStr, verifyGitHubSig, type RelayEvent } from './relay';
import { cronName } from './schedule';
import { handleSocial } from './social/routes';
import { validateUsage } from './usage';
import { watchAdvisories } from './watchers/advisories';
import { checkAll, parseTargets } from './watchers/health';
import { runWatchers } from './watchers/run';
import { runProdWatch } from './prod-watch';

export { BrainDO } from './brain-do';
export { HandsContainer } from './hands-container';

const MAX_BODY = 5 * 1024 * 1024;
const JSON_HEADERS = { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store', 'x-content-type-options': 'nosniff' };

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), { status, headers: JSON_HEADERS });
}

/** Shape of the optional `reconcile` part of POST /findings; every listed finding must belong to the reconciled source. */
export function reconcileError(rec: unknown, list: unknown[]): string | null {
  if (!rec || typeof rec !== 'object') return 'reconcile must be an object';
  const r = rec as Record<string, unknown>;
  if (typeof r.source !== 'string' || !/^[\w.-]{1,64}$/.test(r.source)) return 'reconcile.source must be 1-64 chars of [A-Za-z0-9_.-]';
  if (r.keep !== undefined && (!Array.isArray(r.keep) || r.keep.length > 50 || r.keep.some((k) => typeof k !== 'string' || !k || k.length > 100))) return 'reconcile.keep must be <= 50 non-empty strings';
  if (list.some((f) => (f as { source?: unknown })?.source !== r.source)) return 'every finding in a reconciled listing must have source = reconcile.source';
  return null;
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
  // M-3: X-GitHub-Delivery is NOT covered by the HMAC, so a captured signed body replayed under a new delivery id would be
  // accepted. The signed run id + attempt is the dedupe identity, and a run last updated over an hour ago is not news.
  const run = payload?.workflow_run;
  const updated = Date.parse(String(run?.updated_at ?? ''));
  if (!Number.isFinite(updated) || Date.now() - updated > 3600_000 || !run?.id) return new Response(null, { status: 204 });
  const runKey = `${run.id}-${run.run_attempt ?? 1}`;
  if (run?.conclusion === 'success' && detail.branch === detail.defaultBranch) {
    // a green run on the default branch closes that workflow's open CI finding (and is remembered for M-4)
    ctx.waitUntil(brainStub(env).resolveCi(slug, detail.workflow, runKey));
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
  await brainStub(env).ingestCiEvent({ id: runKey, slug: mapped.target.slug, sha: mapped.target.sha, ...detail, ts: ts * 1000 });
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
  // M-2: in a group chat any member could press a button; the presser must be the owner (TELEGRAM_OWNER_ID, default the chat id,
  // which in a private chat IS the owner's user id and in a group is negative and so never matches: fail closed)
  if (String(cb?.from?.id ?? '') !== String(env.TELEGRAM_OWNER_ID || env.TELEGRAM_CHAT_ID || '')) return new Response(null, { status: 200 });
  const m = String(cb.data ?? '').match(/^q:([\w-]+):([\w-]+)$/);
  const sm = String(cb.data ?? '').match(/^s:([\w-]+):([aek])$/);
  let text = 'not understood';
  if (sm) {
    const decision = sm[2] === 'a' ? 'approve' : sm[2] === 'e' ? 'edit' : 'skip';
    const r = await brainStub(env).socialDecide(sm[1]!, decision, 'telegram-button');
    text = r.ok ? `recorded: ${r.status}` : r.reason ?? 'refused';
  } else if (m) {
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

/**
 * F-06b: hands routes are scoped. A container's bearer is HMAC(HANDS_TOKEN, runId): good for THAT run (its batch, its jobs' outcomes,
 * its refusal). The Mac's bearer is HANDS_MAC_TOKEN: it claims as `mac-local` (the provider comes from the token, never the body, so the
 * Mac's third-party-text filter cannot be skipped) and may read / report only Mac runs. HANDS_TOKEN itself is never a bearer.
 */
async function handsScope(request: Request, env: Env, runId: string | null, brain: DurableObjectStub<BrainDO>): Promise<'mac' | 'run' | null> {
  const h = request.headers.get('Authorization') ?? '';
  const presented = h.startsWith('Bearer ') ? h.slice(7) : '';
  if (!presented) return null;
  if (env.HANDS_MAC_TOKEN && timingSafeEqualStr(presented, env.HANDS_MAC_TOKEN)) {
    if (runId === null) return 'mac';
    const info = await brain.runInfo(runId);
    return info && info.provider.startsWith('mac') ? 'mac' : null;
  }
  if (runId && (await runTokenValid(env.HANDS_TOKEN, runId, presented))) return 'run';
  return null;
}

async function handleHands(request: Request, env: Env, path: string): Promise<Response> {
  const brain = brainStub(env);
  let m: RegExpMatchArray | null;
  const denied = () => new Response('unauthorized', { status: 401 });
  if (request.method === 'GET' && (m = path.match(/^\/hands\/runs\/([\w-]+)$/))) {
    if (!(await handsScope(request, env, m[1]!, brain))) return denied();
    const run = await brain.getRun(m[1]!);
    return run ? json(run) : json({ error: 'no such run' }, 404);
  }
  if (request.method === 'GET' && path === '/hands/leases') {
    // HANDS-COORD: the hands re-check the controller leases right before they touch a repo (run token with ?run=, or the Mac token)
    const runId = new URL(request.url).searchParams.get('run');
    if (runId !== null && !/^[\w-]{1,64}$/.test(runId)) return json({ error: 'bad run id' }, 400);
    if (!(await handsScope(request, env, runId, brain))) return denied();
    return json({ leases: await brain.activeLeases() });
  }
  if (request.method !== 'POST') return new Response('method not allowed', { status: 405 });
  let body: any;
  try {
    body = await readJson(request);
  } catch {
    return json({ error: 'bad json' }, 400);
  }
  if ((m = path.match(/^\/hands\/jobs\/([\w-]+)\/outcome$/))) {
    const owner = await brain.runOfJob(m[1]!);
    if (!owner || !(await handsScope(request, env, owner.runId, brain))) return denied();
    if (!OUTCOME_STATUSES.includes(body?.status)) return json({ error: `status must be one of ${OUTCOME_STATUSES.join('|')}` }, 400);
    const usage = validateJobUsage(body?.usage);
    if (body?.usage !== undefined && !usage) return json({ error: 'usage must be {model, inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens, costUsd} (finite numbers >= 0)' }, 400);
    const o: JobOutcome = { status: body.status, ...(typeof body.prUrl === 'string' ? { prUrl: body.prUrl.slice(0, 500) } : {}), ...(typeof body.note === 'string' ? { note: body.note.slice(0, 1000) } : {}), ...(usage ? { usage } : {}), ...(body.claudeRan === true ? { claudeRan: true } : {}), ...(body.metered === true ? { metered: true } : {}) };
    const r = await brain.recordOutcome(m[1]!, o);
    return json(r, r.ok ? 200 : 409);
  }
  if (path === '/hands/meter') {
    // the forwarder's meter (money re-review C1): one API response's usage, or a job-start beacon, scoped to the run by its token
    if (typeof body?.runId !== 'string' || !/^[\w-]{1,64}$/.test(body.runId) || typeof body?.jobId !== 'string' || !/^[\w-]{1,64}$/.test(body.jobId)) return json({ error: 'runId and jobId required' }, 400);
    if (!(await handsScope(request, env, body.runId, brain))) return denied();
    if (body.started === true) return json(await brain.recordMeter(body.runId, { jobId: body.jobId, started: true }));
    const usage = validateJobUsage({ model: body.model, inputTokens: body.inputTokens, outputTokens: body.outputTokens, cacheReadTokens: body.cacheReadTokens, cacheWriteTokens: body.cacheWriteTokens, costUsd: body.costUsd });
    if (!usage) return json({ error: 'usage must be finite numbers >= 0 and a short model id' }, 400);
    return json(await brain.recordMeter(body.runId, { jobId: body.jobId, ...usage }));
  }
  if (path === '/hands/refused') {
    if (!request.headers.get('Authorization')) return denied();
    if (typeof body?.runId !== 'string' || !/^[\w-]{1,64}$/.test(body.runId)) return json({ error: 'runId required' }, 400);
    if (!(await handsScope(request, env, body.runId, brain))) return denied();
    return json(await brain.handsRefused(body.runId, typeof body?.reason === 'string' ? body.reason : 'unknown reason'));
  }
  if (path === '/hands/usage') {
    const claimed = request.headers.get('X-Hands-Run');
    if (!(await handsScope(request, env, claimed && /^[\w-]{1,64}$/.test(claimed) ? claimed : null, brain))) return denied();
    const err = validateUsage(body);
    if (err) return json({ error: err }, 400);
    await brain.reportUsage({ weeklyUsedPct: body.weeklyUsedPct, ...(typeof body.resetsAt === 'number' ? { resetsAt: body.resetsAt } : {}) });
    return json({ ok: true });
  }
  if (path === '/hands/claim') {
    if ((await handsScope(request, env, null, brain)) !== 'mac') return denied();
    const max = Number.isInteger(body?.max) ? body.max : 5;
    return json(await brain.claim('mac-local', max)); // the provider name is the token's, never the body's
  }
  return json({ error: 'not found' }, 404);
}

/** The usage block of an outcome: finite non-negative numbers, a short model alias. */
export function validateJobUsage(u: any): JobUsage | null {
  if (!u || typeof u !== 'object' || typeof u.model !== 'string' || !/^[\w.-]{1,40}$/.test(u.model)) return null;
  const nums = ['inputTokens', 'outputTokens', 'cacheReadTokens', 'cacheWriteTokens', 'costUsd'] as const;
  for (const k of nums) if (typeof u[k] !== 'number' || !Number.isFinite(u[k]) || u[k] < 0 || u[k] > 1e9) return null;
  return { model: u.model, inputTokens: u.inputTokens, outputTokens: u.outputTokens, cacheReadTokens: u.cacheReadTokens, cacheWriteTokens: u.cacheWriteTokens, costUsd: u.costUsd };
}

async function handleDash(request: Request, env: Env, url: URL): Promise<Response> {
  const refused = await gateHuman(request, env, () => brainStub(env));
  if (refused) return refused;
  if (request.method !== 'GET' && request.method !== 'HEAD') return new Response(null, { status: 405, headers: DASH_HEADERS });
  if (url.pathname === '/dash') return Response.redirect(new URL('/dash/', url).toString(), 302);
  if (!env.ASSETS) return new Response(null, { status: 404, headers: DASH_HEADERS });
  const asset = await env.ASSETS.fetch(request);
  const res = new Response(asset.body, asset);
  for (const [k, v] of Object.entries(DASH_HEADERS)) res.headers.set(k, v);
  return res;
}

async function handleApi(request: Request, env: Env, path: string): Promise<Response> {
  const brain = brainStub(env);
  const refused = await gateHuman(request, env, () => brain);
  if (refused) return refused;
  if (request.method === 'GET' && path === '/api/state') return json(await brain.state());
  // F-01: the global kill switch. POST /api/halt {on: boolean, reason?: string}; same-origin like the question answers. Clearing is manual only.
  if (request.method === 'POST' && path === '/api/halt') {
    if (request.headers.get('Origin') !== new URL(request.url).origin) return json({ error: 'cross-origin' }, 403);
    let body: any;
    try {
      body = await readJson(request);
    } catch {
      return json({ error: 'bad json' }, 400);
    }
    if (typeof body?.on !== 'boolean') return json({ error: 'on (boolean) required' }, 400);
    if (body.on) await brain.setHalt(typeof body.reason === 'string' && body.reason ? body.reason.slice(0, 200) : 'halted from the dashboard');
    else await brain.clearHalt();
    return json({ ok: true, halt: await brain.state().then((s) => s.halt) });
  }
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
        // { findings, reconcile }: a monitor's COMPLETE current listing (prod-watch). Findings of reconcile.source that are not in the
        // listing are resolved, except keys under reconcile.keep (the monitor could not evaluate them this run: unknown is not clear).
        const snap = body && typeof body === 'object' && !Array.isArray(body) && Array.isArray((body as any).findings) ? (body as any) : null;
        const list = snap ? (snap.findings as unknown[]) : Array.isArray(body) ? body : [body];
        if (list.length > 100) return json({ error: 'at most 100 findings per request' }, 400);
        const rec = snap?.reconcile;
        const recErr = rec === undefined ? null : reconcileError(rec, list);
        if (recErr) return json({ error: recErr }, 400);
        if (list.length && !(await brainStub(env).admitIngest(list.length))) return json({ error: 'daily ingest limit reached' }, 429);
        for (const f of list) {
          const err = validateFinding(f);
          if (err) return json({ error: err }, 400);
        }
        const out = list.length ? await brainStub(env).ingestMany(list as Finding[]) : { raised: 0, deduped: 0 };
        if (!rec) return json(out);
        const resolved = await brainStub(env).reconcileSource(rec.source, (list as Finding[]).map((f) => f.key), rec.keep ?? []);
        return json({ ...out, resolved });
      }
      if (path === '/leases' && (request.method === 'POST' || request.method === 'DELETE')) {
        // HANDS-COORD: a controller (Claude session / Ahmad) claims or releases a repo; the hands never touch a leased repo
        if (!checkBearerAuth(request, env.INGEST_TOKEN)) return new Response('unauthorized', { status: 401 });
        let b: any;
        try {
          b = await readJson(request);
        } catch {
          return json({ error: 'bad json' }, 400);
        }
        const repo = typeof b?.repo === 'string' ? b.repo.trim() : '';
        const holder = typeof b?.holder === 'string' ? b.holder.trim() : '';
        if (!/^[\w.-]{1,100}\/[\w.-]{1,100}$/.test(repo)) return json({ error: 'repo must be owner/name' }, 400);
        if (!/^[\w.@:-]{1,100}$/.test(holder)) return json({ error: 'holder must be 1-100 chars of [A-Za-z0-9_.@:-]' }, 400);
        if (request.method === 'DELETE') return json({ released: await brainStub(env).releaseLease(repo, holder) });
        const ttl = Number(b?.ttlMin ?? 120);
        if (!Number.isFinite(ttl) || ttl <= 0) return json({ error: 'ttlMin must be a positive number' }, 400);
        const r = await brainStub(env).claimLease(repo, holder, ttl, typeof b?.note === 'string' ? b.note : undefined);
        return json(r, r.ok ? 200 : 409);
      }
      if (path === '/drill' && request.method === 'POST') {
        if (!checkBearerAuth(request, env.INGEST_TOKEN)) return new Response('unauthorized', { status: 401 });
        let body: any;
        try {
          body = await readJson(request);
        } catch {
          return json({ error: 'bad json' }, 400);
        }
        if (body?.result !== 'pass' && body?.result !== 'fail') return json({ error: "result must be 'pass' or 'fail'" }, 400);
        await brainStub(env).recordDrill(body.result, typeof body.note === 'string' ? body.note : undefined);
        return json({ ok: true });
      }
      if (path.startsWith('/social/')) return await handleSocial(request, env, path, brainStub(env));
      if (path.startsWith('/api/')) return await handleApi(request, env, path);
      if (path === '/dash' || path.startsWith('/dash/')) return await handleDash(request, env, url);
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
        // primary production probes (ruling AIOS-7): every other tick; a failure never blocks the OS tick
        await runProdWatch(env, brain, now).catch((e: Error) => console.error('prod-watch', e.message));
        await brain.tick(now);
        // social: previews a day ahead, the approval gate, publishing at the slot (a social failure never blocks the OS tick)
        await brain.socialTick(now).catch((e: Error) => console.error('social tick', e.message));
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
        await brain.digest(now); // the social block rides inside it: one message, not two
        return;
      default:
        // an unknown cron means wrangler.jsonc and src/schedule.ts drifted: loud, never silent
        console.error('unknown cron', controller.cron);
        ctx.waitUntil(Promise.resolve());
    }
  },
} satisfies ExportedHandler<Env>;
