// Scheduled Telegram sends: POST /api/telegram/schedule {id, sendAt, text, buttons?}, GET (list), DELETE /:id (Bearer INGEST_TOKEN).
// Rows live in the BrainDO's SQLite (single-threaded, so a claim is never raced) and are sent by the existing 5-minute `tick`:
// no new cron, no always-on compute. Safety properties (each has a test in test/tg-schedule.test.ts):
//  - EXACTLY ONCE per id: a duplicate id is refused (even after it was sent); the part counter is advanced (durable) BEFORE the network
//    call, so a crash between send and mark never resends. A definite Telegram refusal rolls the counter back and retries with backoff;
//    a lost answer (exception) becomes 'uncertain' and is never retried.
//  - Text over 4096 chars is split on a newline/space boundary; parts go in order, buttons ride on the last part.
import { z } from 'zod';
import type { Env } from './env';
import { scrub } from './tg-inbox';

export const MAX_PART = 4096;
export const MAX_PENDING = 500;
export const MAX_SENDS_PER_TICK = 10;
export const BACKOFF_MS = [5 * 60_000, 15 * 60_000];
const STALE_PAST_MS = 5 * 60_000;
const MAX_TEXT = 20_000;

export const ScheduleBody = z.object({
  id: z.string().regex(/^[\w.-]{1,80}$/),
  sendAt: z.iso.datetime({ offset: true }),
  text: z.string().min(1).max(MAX_TEXT),
  buttons: z.array(z.object({ text: z.string().min(1).max(64), url: z.url().refine((u) => u.startsWith('https://'), 'https only') })).max(4).optional(),
});
export type ScheduleInput = z.infer<typeof ScheduleBody>;

export function splitText(text: string, max = MAX_PART): string[] {
  const out: string[] = [];
  let rest = text;
  while (rest.length > max) {
    let cut = rest.lastIndexOf('\n', max);
    if (cut < max / 2) cut = rest.lastIndexOf(' ', max);
    if (cut < max / 2) cut = max;
    out.push(rest.slice(0, cut));
    rest = rest.slice(cut).replace(/^[\n ]/, '');
  }
  out.push(rest);
  return out;
}

/** Strip the bot token (and any `bot<digits>:<secret>` URL fragment) from anything stored or returned: a fetch error can carry the request URL. */
export function redact(env: Env, reason: string): string {
  const t = env.TELEGRAM_BOT_TOKEN;
  let r = t ? reason.split(t).join('[redacted]') : reason;
  r = r.replace(/bot\d+:[\w-]+/g, 'bot[redacted]');
  return String(scrub(env, r)).slice(0, 300);
}

type Row = Record<string, SqlStorageValue>;
export type SchedStatus = 'pending' | 'sent' | 'failed' | 'uncertain';

export class TgScheduler {
  constructor(
    private sql: SqlStorage,
    private env: Env,
    private fetchImpl: () => typeof fetch,
  ) {}

  static migrate(sql: SqlStorage): void {
    sql.exec(`
      CREATE TABLE IF NOT EXISTS tg_scheduled (
        id TEXT PRIMARY KEY, send_at INTEGER NOT NULL, text TEXT NOT NULL, buttons TEXT, status TEXT NOT NULL,
        parts_done INTEGER NOT NULL DEFAULT 0, attempts INTEGER NOT NULL DEFAULT 0, next_at INTEGER, last_error TEXT,
        created_at INTEGER NOT NULL, sent_at INTEGER);
      CREATE INDEX IF NOT EXISTS tg_scheduled_due ON tg_scheduled (status, send_at);
    `);
  }

  private rows(q: string, ...b: unknown[]): Row[] {
    return this.sql.exec(q, ...b).toArray() as Row[];
  }

  add(input: ScheduleInput, now: number): { ok: true; id: string; sendAt: number; parts: number } | { ok: false; code: number; error: string } {
    const sendAt = Date.parse(input.sendAt);
    if (sendAt < now - STALE_PAST_MS) return { ok: false, code: 400, error: 'sendAt is in the past' };
    if (this.rows('SELECT 1 FROM tg_scheduled WHERE id = ?', input.id).length) return { ok: false, code: 409, error: 'id already exists' };
    if (Number(this.rows(`SELECT COUNT(*) AS n FROM tg_scheduled WHERE status = 'pending'`)[0]!.n) >= MAX_PENDING) return { ok: false, code: 429, error: 'too many pending' };
    this.sql.exec(`INSERT INTO tg_scheduled (id, send_at, text, buttons, status, created_at) VALUES (?, ?, ?, ?, 'pending', ?)`, input.id, sendAt, input.text, input.buttons ? JSON.stringify(input.buttons) : null, now);
    return { ok: true, id: input.id, sendAt, parts: splitText(input.text).length };
  }

  list(status?: string): Record<string, unknown>[] {
    const q = `SELECT id, send_at, status, parts_done, attempts, next_at, last_error, sent_at, length(text) AS chars, substr(text, 1, 80) AS preview FROM tg_scheduled`;
    const r = status ? this.rows(`${q} WHERE status = ? ORDER BY send_at LIMIT 500`, status) : this.rows(`${q} ORDER BY send_at LIMIT 500`);
    return r.map((x) => ({ ...x, last_error: x.last_error == null ? null : redact(this.env, String(x.last_error)), sendAt: new Date(Number(x.send_at)).toISOString() }));
  }

  /** Only a row that has not started sending can be removed. */
  remove(id: string): { ok: boolean; code: number; error?: string } {
    const r = this.rows('SELECT status, parts_done FROM tg_scheduled WHERE id = ?', id)[0];
    if (!r) return { ok: false, code: 404, error: 'no such id' };
    if (r.status !== 'pending' || Number(r.parts_done) > 0) return { ok: false, code: 409, error: `already ${r.status}` };
    this.sql.exec('DELETE FROM tg_scheduled WHERE id = ?', id);
    return { ok: true, code: 200 };
  }

  async tick(now: number): Promise<{ sent: number; failed: number; uncertain: number }> {
    const out = { sent: 0, failed: 0, uncertain: 0 };
    const due = this.rows(`SELECT * FROM tg_scheduled WHERE status = 'pending' AND send_at <= ? AND (next_at IS NULL OR next_at <= ?) ORDER BY send_at LIMIT ?`, now, now, MAX_SENDS_PER_TICK);
    for (const row of due) {
      const id = String(row.id);
      const parts = splitText(String(row.text));
      const buttons = row.buttons ? (JSON.parse(String(row.buttons)) as { text: string; url: string }[]) : [];
      let done = Number(row.parts_done);
      let attempts = Number(row.attempts);
      let state: SchedStatus = 'pending';
      while (done < parts.length) {
        // CLAIM FIRST: the part is counted as sent before the call, so no crash window can resend it
        this.sql.exec('UPDATE tg_scheduled SET parts_done = ? WHERE id = ?', done + 1, id);
        const r = await this.send(parts[done]!, done === parts.length - 1 ? buttons : []);
        if (r.kind === 'ok') {
          done++;
          continue;
        }
        if (r.kind === 'lost') {
          this.sql.exec(`UPDATE tg_scheduled SET status = 'uncertain', last_error = ? WHERE id = ?`, redact(this.env, r.reason), id);
          out.uncertain++;
          state = 'uncertain';
          break;
        }
        attempts++;
        const exhausted = attempts > BACKOFF_MS.length;
        this.sql.exec(`UPDATE tg_scheduled SET parts_done = ?, attempts = ?, status = ?, next_at = ?, last_error = ? WHERE id = ?`, done, attempts, exhausted ? 'failed' : 'pending', exhausted ? null : now + (r.retryAfterMs ?? BACKOFF_MS[attempts - 1]!), redact(this.env, r.reason), id);
        if (exhausted) out.failed++;
        state = exhausted ? 'failed' : 'pending';
        break;
      }
      if (done >= parts.length && state === 'pending') {
        this.sql.exec(`UPDATE tg_scheduled SET status = 'sent', sent_at = ?, next_at = NULL, last_error = NULL WHERE id = ?`, now, id);
        out.sent++;
      }
    }
    return out;
  }

  private async send(text: string, buttons: { text: string; url: string }[]): Promise<{ kind: 'ok' } | { kind: 'refused' | 'lost'; reason: string; retryAfterMs?: number }> {
    const { TELEGRAM_BOT_TOKEN: token, TELEGRAM_CHAT_ID: chat } = this.env;
    if (!token || !chat) return { kind: 'refused', reason: 'telegram not configured' };
    const body: Record<string, unknown> = { chat_id: chat, text, disable_web_page_preview: true };
    if (buttons.length) body.reply_markup = { inline_keyboard: [buttons.map((b) => ({ text: b.text, url: b.url }))] };
    try {
      const r = await this.fetchImpl()(`https://api.telegram.org/bot${token}/sendMessage`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) });
      const j = (await r.json().catch(() => null)) as { ok?: boolean; parameters?: { retry_after?: number } } | null;
      if (r.ok && j?.ok !== false) return { kind: 'ok' };
      const ra = Number(j?.parameters?.retry_after);
      return { kind: 'refused', reason: `telegram HTTP ${r.status}`, ...(r.status === 429 && ra > 0 ? { retryAfterMs: Math.min(ra, 3600) * 1000 } : {}) };
    } catch (e) {
      return { kind: 'lost', reason: `no answer from telegram: ${(e as Error).message}` };
    }
  }
}

const json = (b: unknown, status = 200) => Response.json(b, { status });

/** Worker edge: Zod-validates, then hands to the DO. `path` starts with /api/telegram/schedule. Auth is already checked by the caller. */
export async function handleSchedule(
  request: Request,
  path: string,
  brain: { tgScheduleAdd(i: ScheduleInput, now?: number): unknown; tgScheduleList(status?: string): unknown; tgScheduleRemove(id: string): unknown },
): Promise<Response> {
  if (path === '/api/telegram/schedule') {
    if (request.method === 'GET') {
      const s = new URL(request.url).searchParams.get('status') ?? undefined;
      if (s && !['pending', 'sent', 'failed', 'uncertain'].includes(s)) return json({ error: 'status must be pending|sent|failed|uncertain' }, 400);
      return json({ items: await brain.tgScheduleList(s) });
    }
    if (request.method !== 'POST') return new Response('method not allowed', { status: 405 });
    if (Number(request.headers.get('content-length') ?? 0) > 64 * 1024) return json({ error: 'body too large' }, 413);
    let raw: unknown;
    try {
      const t = await request.text();
      if (t.length > 64 * 1024) return json({ error: 'body too large' }, 413);
      raw = JSON.parse(t);
    } catch {
      return json({ error: 'bad json' }, 400);
    }
    const p = ScheduleBody.safeParse(raw);
    if (!p.success) return json({ error: 'invalid body', issues: p.error.issues.map((i) => `${i.path.join('.')}: ${i.message}`) }, 400);
    const r = (await brain.tgScheduleAdd(p.data)) as { ok: boolean; code?: number };
    return json(r, r.ok ? 200 : (r.code ?? 400));
  }
  const m = path.match(/^\/api\/telegram\/schedule\/([\w.-]{1,80})$/);
  if (m && request.method === 'DELETE') {
    const r = (await brain.tgScheduleRemove(m[1]!)) as { ok: boolean; code: number };
    return json(r, r.code);
  }
  return new Response('not found', { status: 404 });
}
