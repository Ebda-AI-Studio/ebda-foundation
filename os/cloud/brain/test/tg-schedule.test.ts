// Scheduled Telegram sends on workerd: the real BrainDO (SQLite), Telegram mocked at the fetch boundary.
import { env, SELF } from 'cloudflare:test';
import { runInDurableObject } from 'cloudflare:test';
import { describe, expect, it } from 'vitest';
import type { BrainDO } from '../src/brain-do';
import { splitText } from '../src/tg-schedule';

const T0 = Date.UTC(2026, 10, 12, 7, 0, 0);
const iso = (ms: number) => new Date(ms).toISOString();

async function harness(reply: () => Response | Promise<Response> = () => Response.json({ ok: true, result: {} })) {
  const stub = env.BRAIN.get(env.BRAIN.idFromName(crypto.randomUUID()));
  const sent: { text: string; markup?: unknown }[] = [];
  const run = <R>(fn: (b: BrainDO) => R | Promise<R>) => runInDurableObject(stub, (b: BrainDO) => fn(b));
  await run((b) => {
    (b as any).env = { ...b['env'], TELEGRAM_BOT_TOKEN: 'tok', TELEGRAM_CHAT_ID: '1' };
    b.fetchImpl = (async (_u: RequestInfo | URL, init?: RequestInit) => {
      const body = JSON.parse(String(init?.body));
      sent.push({ text: body.text, markup: body.reply_markup });
      return reply();
    }) as typeof fetch;
  });
  return { sent, run };
}

describe('scheduled telegram', () => {
  it('due -> sent once; a tick replay does not resend', async () => {
    const h = await harness();
    await h.run((b) => b.tgScheduleAdd({ id: 'p1', sendAt: iso(T0 + 3_600_000), text: 'hello' }, T0));
    expect(await h.run((b) => b.tgScheduleTick(T0 + 3_600_000))).toMatchObject({ sent: 1 });
    expect(await h.run((b) => b.tgScheduleTick(T0 + 3_600_000))).toMatchObject({ sent: 0 });
    expect(await h.run((b) => b.tgScheduleTick(T0 + 7_200_000))).toMatchObject({ sent: 0 });
    expect(h.sent.map((s) => s.text)).toEqual(['hello']);
    expect((await h.run((b) => b.tgScheduleList('sent'))) as any[]).toHaveLength(1);
  });

  it('not due -> held', async () => {
    const h = await harness();
    await h.run((b) => b.tgScheduleAdd({ id: 'p1', sendAt: iso(T0 + 3_600_000), text: 'later' }, T0));
    expect(await h.run((b) => b.tgScheduleTick(T0 + 3_599_000))).toMatchObject({ sent: 0 });
    expect(h.sent).toHaveLength(0);
    expect((await h.run((b) => b.tgScheduleList('pending'))) as any[]).toHaveLength(1);
  });

  it('duplicate id is rejected, also after it was sent', async () => {
    const h = await harness();
    const add = () => h.run((b) => b.tgScheduleAdd({ id: 'p1', sendAt: iso(T0 + 60_000), text: 'x' }, T0));
    expect(await add()).toMatchObject({ ok: true });
    expect(await add()).toMatchObject({ ok: false, code: 409 });
    await h.run((b) => b.tgScheduleTick(T0 + 60_000));
    expect(await add()).toMatchObject({ ok: false, code: 409 });
  });

  it('a crash between send and mark never resends (claim before send)', async () => {
    const h = await harness();
    await h.run((b) => b.tgScheduleAdd({ id: 'p1', sendAt: iso(T0), text: 'once' }, T0));
    // simulate: the part was claimed and sent, then the DO died before the 'sent' mark
    await h.run((b) => b['sql'].exec(`UPDATE tg_scheduled SET parts_done = 1 WHERE id = 'p1'`));
    await h.run((b) => b.tgScheduleTick(T0 + 60_000));
    expect(h.sent).toHaveLength(0);
    expect((await h.run((b) => b.tgScheduleList())) as any[]).toMatchObject([{ status: 'sent' }]);
  });

  it('a lost answer is uncertain and never retried; a definite refusal retries with backoff', async () => {
    const lost = await harness(() => {
      throw new Error('boom');
    });
    await lost.run((b) => b.tgScheduleAdd({ id: 'a', sendAt: iso(T0), text: 'x' }, T0));
    expect(await lost.run((b) => b.tgScheduleTick(T0))).toMatchObject({ uncertain: 1 });
    await lost.run((b) => b.tgScheduleTick(T0 + 3_600_000));
    expect(lost.sent).toHaveLength(1);

    let n = 0;
    const flaky = await harness(() => (n++ === 0 ? new Response('{}', { status: 500 }) : Response.json({ ok: true })));
    await flaky.run((b) => b.tgScheduleAdd({ id: 'b', sendAt: iso(T0), text: 'y' }, T0));
    await flaky.run((b) => b.tgScheduleTick(T0));
    expect(await flaky.run((b) => b.tgScheduleTick(T0 + 60_000))).toMatchObject({ sent: 0 }); // backoff not over
    expect(await flaky.run((b) => b.tgScheduleTick(T0 + 6 * 60_000))).toMatchObject({ sent: 1 });
    expect(flaky.sent).toHaveLength(2);
  });

  it('never stores or returns the bot token from a fetch error', async () => {
    const TOKEN = '123456789:AAFakeTokenValue_abc-DEF';
    const h = await harness(() => {
      throw new Error(`fetch failed for https://api.telegram.org/bot${TOKEN}/sendMessage`);
    });
    await h.run((b) => {
      (b as any).env = { ...b['env'], TELEGRAM_BOT_TOKEN: TOKEN };
      return b.tgScheduleAdd({ id: 'leak', sendAt: iso(T0), text: 'x' }, T0);
    });
    await h.run((b) => b.tgScheduleTick(T0));
    const raw = await h.run((b) => JSON.stringify(b['sql'].exec('SELECT last_error FROM tg_scheduled').toArray()));
    const listed = await h.run((b) => JSON.stringify(b.tgScheduleList()));
    for (const out of [raw, listed]) {
      expect(out).not.toContain(TOKEN);
      expect(out).not.toContain('AAFakeToken');
    }
    expect(listed).toContain('uncertain');
    // a legacy row written before the fix is redacted on read too
    await h.run((b) => b['sql'].exec(`UPDATE tg_scheduled SET last_error = ? WHERE id = 'leak'`, `x https://api.telegram.org/bot${TOKEN}/y`));
    expect(await h.run((b) => JSON.stringify(b.tgScheduleList()))).not.toContain('AAFakeToken');
  });

  it('splits over 4096 chars in order, buttons on the last part, resumes without resending parts', async () => {
    const long = Array.from({ length: 9 }, (_, i) => `${i}`.repeat(1000)).join('\n');
    const parts = splitText(long);
    expect(parts.length).toBeGreaterThan(1);
    expect(parts.every((p) => p.length <= 4096)).toBe(true);
    expect(parts.join('\n')).toBe(long);
    const h = await harness();
    await h.run((b) => b.tgScheduleAdd({ id: 'p', sendAt: iso(T0), text: long, buttons: [{ text: 'Open', url: 'https://www.linkedin.com/company/ebda-ai-studio' }] }, T0));
    await h.run((b) => b.tgScheduleTick(T0));
    expect(h.sent.map((s) => s.text)).toEqual(parts);
    expect(h.sent.slice(0, -1).every((s) => !s.markup)).toBe(true);
    expect(h.sent.at(-1)!.markup).toBeTruthy();
  });

  it('delete only removes a pending row', async () => {
    const h = await harness();
    await h.run((b) => b.tgScheduleAdd({ id: 'p1', sendAt: iso(T0 + 60_000), text: 'x' }, T0));
    expect(await h.run((b) => b.tgScheduleRemove('p1'))).toMatchObject({ ok: true });
    expect(await h.run((b) => b.tgScheduleRemove('p1'))).toMatchObject({ code: 404 });
    await h.run((b) => b.tgScheduleAdd({ id: 'p2', sendAt: iso(T0), text: 'x' }, T0));
    await h.run((b) => b.tgScheduleTick(T0));
    expect(await h.run((b) => b.tgScheduleRemove('p2'))).toMatchObject({ code: 409 });
  });

  it('HTTP edge: auth, Zod validation, GET list, DELETE', async () => {
    const auth = { authorization: `Bearer ${env.INGEST_TOKEN}`, 'content-type': 'application/json' };
    const post = (b: unknown, headers: Record<string, string> = auth) => SELF.fetch('https://x/api/telegram/schedule', { method: 'POST', headers, body: JSON.stringify(b) });
    const id = `t-${crypto.randomUUID()}`;
    const ok = { id, sendAt: iso(Date.now() + 86_400_000), text: 'hi' };
    expect((await post(ok, { 'content-type': 'application/json' })).status).toBe(401);
    expect((await post({ ...ok, id: 'bad id!' })).status).toBe(400);
    expect((await post({ ...ok, sendAt: 'tomorrow' })).status).toBe(400);
    expect((await post({ ...ok, text: '' })).status).toBe(400);
    expect((await post({ ...ok, buttons: [{ text: 'x', url: 'http://insecure.example' }] })).status).toBe(400);
    expect((await post(ok)).status).toBe(200);
    expect((await post(ok)).status).toBe(409);
    const list = (await (await SELF.fetch('https://x/api/telegram/schedule?status=pending', { headers: auth })).json()) as { items: { id: string }[] };
    expect(list.items.some((i) => i.id === id)).toBe(true);
    expect((await SELF.fetch(`https://x/api/telegram/schedule/${id}`, { method: 'DELETE', headers: auth })).status).toBe(200);
  });
});
