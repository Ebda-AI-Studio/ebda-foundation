// Social approvals on Telegram (RR-tg-send-only, superseded by RR-tg-brain-owns): the preview image, then the full text with three buttons.
// Buttons are signed URL buttons to the brain's own /social/d page (works without the tg-relay forwarding button presses); when
// SOCIAL_LINK_SECRET is unset they fall back to callback buttons `s:<id>:<a|e|k>` (answered through POST /telegram/webhook).
// These are NOT counted against MESSAGE_BUDGET_PER_DAY: Ahmad asked for one preview per post (ruling RR-social-budget).
import { BRAND_LABEL, type PostRow } from './types';

export async function hmacHex(secret: string, msg: string): Promise<string> {
  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const sig = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(msg));
  return [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

export function linkPayload(id: string, rev: number, exp: number): string {
  return `social|${id}|${rev}|${exp}`;
}

export async function decisionLink(base: string, secret: string, p: Pick<PostRow, 'id' | 'rev'>, exp: number): Promise<string> {
  const sig = await hmacHex(secret, linkPayload(p.id, p.rev, exp));
  return `${base.replace(/\/$/, '')}/social/d/${encodeURIComponent(p.id)}?r=${p.rev}&exp=${exp}&sig=${sig}`;
}

export function cairoTime(ms: number): string {
  return new Intl.DateTimeFormat('en-GB', { timeZone: 'Africa/Cairo', weekday: 'short', day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit' }).format(ms) + ' Cairo';
}

export function previewHeader(p: PostRow): string {
  return `${BRAND_LABEL[p.brand]} / ${p.network} / ${cairoTime(p.scheduled_at)}\n${p.id} rev ${p.rev}`;
}

type Btn = { text: string; url: string } | { text: string; callback_data: string };

async function tg(token: string, method: string, body: BodyInit, json: boolean, fetchImpl: typeof fetch): Promise<{ ok: boolean; reason?: string }> {
  try {
    const r = await fetchImpl(`https://api.telegram.org/bot${token}/${method}`, { method: 'POST', ...(json ? { headers: { 'content-type': 'application/json' } } : {}), body });
    if (!r.ok) return { ok: false, reason: `telegram ${method} HTTP ${r.status}` };
    const j = (await r.json().catch(() => null)) as { ok?: boolean } | null;
    return j?.ok === false ? { ok: false, reason: `telegram ${method} ok=false` } : { ok: true };
  } catch (e) {
    return { ok: false, reason: `telegram ${method} failed: ${(e as Error).message}` };
  }
}

export async function sendPreview(
  o: { token?: string; chatId?: string; post: PostRow; image: ArrayBuffer | null; buttons: Btn[]; fetchImpl: typeof fetch },
): Promise<{ ok: boolean; reason?: string }> {
  if (!o.token || !o.chatId) return { ok: false, reason: 'telegram not configured' };
  if (o.image) {
    const f = new FormData();
    f.append('chat_id', o.chatId);
    f.append('caption', previewHeader(o.post));
    f.append('photo', new Blob([o.image], { type: o.post.image_type }), 'preview');
    const r = await tg(o.token, 'sendPhoto', f, false, o.fetchImpl);
    if (!r.ok) return r;
  }
  const text = `${previewHeader(o.post)}\n\n${o.post.text}`.slice(0, 4000);
  return tg(o.token, 'sendMessage', JSON.stringify({ chat_id: o.chatId, text, disable_web_page_preview: true, reply_markup: { inline_keyboard: [o.buttons] } }), true, o.fetchImpl);
}

export async function sendText(token: string | undefined, chatId: string | undefined, text: string, fetchImpl: typeof fetch): Promise<{ ok: boolean; reason?: string }> {
  if (!token || !chatId) return { ok: false, reason: 'telegram not configured' };
  return tg(token, 'sendMessage', JSON.stringify({ chat_id: chatId, text: text.slice(0, 4000), disable_web_page_preview: true }), true, fetchImpl);
}
