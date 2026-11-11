// /social/* machine routes and the signed decision page.
//   POST /social/drafts          one draft per request (Bearer INGEST_TOKEN: the Mac content job). Body <= 6 MB (image base64).
//   GET  /social/edits           revisions Ahmad asked for (Bearer INGEST_TOKEN)
//   GET  /social/calendar?from=&to=  the calendar without images (Bearer INGEST_TOKEN)
//   POST /social/decide          {id, decision, note?} (Bearer SOCIAL_DECIDE_TOKEN: the controller forwarding Ahmad's Telegram text)
//   POST /social/brands/:brand   {paused?, keepApproval?} (Bearer SOCIAL_DECIDE_TOKEN)
//   GET|POST /social/d/:id       the page behind the Telegram buttons: HMAC(SOCIAL_LINK_SECRET, id|rev|exp). GET only RENDERS (link
//                                previews and prefetchers must never decide); the POST from its form decides.
import type { BrainDO } from '../brain-do';
import type { Env } from '../env';
import { checkBearerAuth, timingSafeEqualStr } from '../relay';
import { hmacHex, linkPayload, previewHeader } from './telegram';
import { BRANDS, type Brand, type Decision } from './types';

const MAX_DRAFT_BODY = 6 * 1024 * 1024;
const HDR = { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store', 'x-content-type-options': 'nosniff' };
const PAGE_HDR = {
  'content-type': 'text/html; charset=utf-8',
  'cache-control': 'no-store',
  'x-content-type-options': 'nosniff',
  'referrer-policy': 'no-referrer',
  'x-frame-options': 'DENY',
  'content-security-policy': "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'",
};
const json = (d: unknown, s = 200) => new Response(JSON.stringify(d), { status: s, headers: HDR });
const esc = (s: string) => s.replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);

async function body(request: Request, max: number): Promise<unknown> {
  const len = Number(request.headers.get('content-length') ?? 0);
  if (len > max) throw new Error('body too large');
  const t = await request.text();
  if (t.length > max) throw new Error('body too large');
  return JSON.parse(t);
}

export async function linkValid(env: Env, id: string, rev: number, exp: number, sig: string, now: number): Promise<boolean> {
  if (!env.SOCIAL_LINK_SECRET || !Number.isFinite(rev) || !Number.isFinite(exp) || exp * 1000 < now || !/^[0-9a-f]{64}$/.test(sig)) return false;
  return timingSafeEqualStr(await hmacHex(env.SOCIAL_LINK_SECRET, linkPayload(id, rev, exp)), sig);
}

function page(title: string, inner: string, status = 200): Response {
  return new Response(
    `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${esc(title)}</title>` +
      `<style>body{font:16px/1.5 system-ui,sans-serif;background:#0d0f14;color:#eee;margin:0;padding:16px;max-width:640px}pre{white-space:pre-wrap;background:#171a22;padding:12px;border-radius:8px}` +
      `button{font:inherit;padding:10px 16px;margin:4px 8px 4px 0;border-radius:8px;border:1px solid #B08D57;background:#171a22;color:#eee}textarea{width:100%;min-height:90px;font:inherit}</style></head><body>${inner}</body></html>`,
    { status, headers: PAGE_HDR },
  );
}

export async function handleSocial(request: Request, env: Env, path: string, brain: DurableObjectStub<BrainDO>, now = Date.now()): Promise<Response> {
  const m = path.match(/^\/social\/d\/([\w-]{1,80})$/);
  if (m) return decisionPage(request, env, m[1]!, brain, now);

  if (path === '/social/decide' || path.startsWith('/social/brands/')) {
    if (request.method !== 'POST') return new Response('method not allowed', { status: 405 });
    if (!env.SOCIAL_DECIDE_TOKEN || !checkBearerAuth(request, env.SOCIAL_DECIDE_TOKEN)) return new Response('unauthorized', { status: 401 });
    let b: any;
    try {
      b = await body(request, 16 * 1024);
    } catch {
      return json({ error: 'bad json' }, 400);
    }
    if (path === '/social/decide') {
      if (typeof b?.id !== 'string' || !['approve', 'edit', 'skip'].includes(b?.decision)) return json({ error: 'need {id, decision: approve|edit|skip}' }, 400);
      const r = await brain.socialDecide(b.id, b.decision as Decision, 'controller', now, { note: typeof b.note === 'string' ? b.note : undefined, rev: typeof b.rev === 'number' ? b.rev : undefined });
      return json(r, r.ok ? 200 : 409);
    }
    const brand = path.slice('/social/brands/'.length);
    if (!BRANDS.includes(brand as Brand)) return json({ error: 'unknown brand' }, 404);
    const patch: { paused?: boolean; keepApproval?: boolean } = {};
    if (typeof b?.paused === 'boolean') patch.paused = b.paused;
    if (typeof b?.keepApproval === 'boolean') patch.keepApproval = b.keepApproval;
    return json(await brain.socialSetBrand(brand as Brand, patch));
  }

  if (!checkBearerAuth(request, env.INGEST_TOKEN)) return new Response('unauthorized', { status: 401 });
  if (path === '/social/drafts' && request.method === 'POST') {
    let d: unknown;
    try {
      d = await body(request, MAX_DRAFT_BODY);
    } catch (e) {
      return json({ error: (e as Error).message === 'body too large' ? 'body too large' : 'bad json' }, (e as Error).message === 'body too large' ? 413 : 400);
    }
    const r = await brain.socialIngest(d, now);
    return json(r, r.ok ? 200 : r.code);
  }
  if (path === '/social/edits' && request.method === 'GET') return json(await brain.socialEdits());
  if (path === '/social/calendar' && request.method === 'GET') {
    const u = new URL(request.url);
    const from = Number(u.searchParams.get('from') ?? now - 7 * 86_400_000);
    const to = Number(u.searchParams.get('to') ?? now + 30 * 86_400_000);
    if (!Number.isFinite(from) || !Number.isFinite(to)) return json({ error: 'from/to must be epoch ms' }, 400);
    return json(await brain.socialCalendar(from, to));
  }
  return new Response('not found', { status: 404 });
}

async function decisionPage(request: Request, env: Env, id: string, brain: DurableObjectStub<BrainDO>, now: number): Promise<Response> {
  let rev: number, exp: number, sig: string, decision: string, note: string | undefined;
  if (request.method === 'GET') {
    const u = new URL(request.url);
    rev = Number(u.searchParams.get('r'));
    exp = Number(u.searchParams.get('exp'));
    sig = u.searchParams.get('sig') ?? '';
    decision = u.searchParams.get('d') ?? '';
  } else if (request.method === 'POST') {
    const f = await request.formData().catch(() => null);
    if (!f) return page('Bad request', '<p>Bad request.</p>', 400);
    rev = Number(f.get('r'));
    exp = Number(f.get('exp'));
    sig = String(f.get('sig') ?? '');
    decision = String(f.get('d') ?? '');
    note = typeof f.get('note') === 'string' ? String(f.get('note')).slice(0, 1000) : undefined;
  } else return new Response('method not allowed', { status: 405 });
  if (!(await linkValid(env, id, rev, exp, sig, now))) return page('Link not valid', '<p>This link is not valid or has expired.</p>', 403);
  if (!['approve', 'edit', 'skip'].includes(decision)) return page('Bad request', '<p>Unknown decision.</p>', 400);
  const post = await brain.socialPost(id);
  if (!post) return page('Not found', '<p>No such post.</p>', 404);
  if (request.method === 'POST') {
    const r = await brain.socialDecide(id, decision as Decision, 'link', now, { rev, note });
    return page('Done', r.ok ? `<p>Recorded: <b>${esc(r.status ?? decision)}</b> for ${esc(id)}.</p>` : `<p>Not recorded: ${esc(r.reason ?? 'refused')}.</p>`, r.ok ? 200 : 409);
  }
  const hidden = `<input type="hidden" name="r" value="${rev}"><input type="hidden" name="exp" value="${exp}"><input type="hidden" name="sig" value="${esc(sig)}"><input type="hidden" name="d" value="${esc(decision)}">`;
  const noteField = decision === 'edit' ? '<p><label>What should change?<br><textarea name="note" required maxlength="1000"></textarea></label></p>' : '';
  const label = decision === 'approve' ? 'Approve this post' : decision === 'edit' ? 'Ask for this edit' : 'Skip this post';
  return page(
    'Social post',
    `<h1>${esc(label)}</h1><pre>${esc(previewHeader(post))}\nstatus: ${esc(post.status)}\n\n${esc(post.text)}</pre>` +
      `<form method="post" action="/social/d/${encodeURIComponent(id)}">${hidden}${noteField}<button type="submit">${esc(label)}</button></form>`,
  );
}
