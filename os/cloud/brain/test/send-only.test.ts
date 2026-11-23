// The brain is the SINGLE consumer of @EbdaAIStudiobot (Telegram allows one: a webhook XOR getUpdates). It registers its own webhook
// through the admin endpoint in src/tg-inbox.ts, and nothing in the brain may ever poll getUpdates (that would fight the webhook).
import { describe, expect, it } from 'vitest';
import { sendTelegram } from '../src/telegram';

const sources = import.meta.glob('../src/**/*.ts', { query: '?raw', import: 'default', eager: true }) as Record<string, string>;

describe('single-consumer Telegram', () => {
  it('finds the brain sources (guards the glob itself)', () => {
    expect(Object.keys(sources).length).toBeGreaterThan(10);
    expect(Object.keys(sources).some((k) => k.endsWith('telegram.ts'))).toBe(true);
  });
  it('no brain source calls getUpdates; webhook methods live only in tg-inbox.ts', () => {
    const poll = Object.entries(sources).flatMap(([file, text]) => [...text.matchAll(/getUpdates/gi)].map((m) => `${file}: ${m[0]}`));
    expect(poll.filter((h) => !h.includes('tg-inbox.ts'))).toEqual([]);
    const wh = Object.entries(sources).filter(([file, text]) => /setWebhook|deleteWebhook|getWebhookInfo/.test(text) && !file.endsWith('tg-inbox.ts'));
    expect(wh.map(([f]) => f)).toEqual([]);
  });
  it('the Telegram Bot API methods in the sources are a closed list', () => {
    const methods = new Set(Object.values(sources).flatMap((text) => [...text.matchAll(/api\.telegram\.org\/bot\$\{[^}]+\}\/(\w+)/g)].map((m) => m[1])));
    expect([...methods].sort()).toEqual(['answerCallbackQuery', 'editMessageText', 'sendMessage']);
  });
  it('sendTelegram talks to sendMessage only, with the bot token and chat id it was given', async () => {
    const urls: string[] = [];
    const r = await sendTelegram('TOKEN', '42', { dedupeKey: 'k', kind: 'digest', text: 'hi' }, (async (u: RequestInfo | URL) => (urls.push(String(u)), Response.json({ ok: true }))) as typeof fetch);
    expect(r.ok).toBe(true);
    expect(urls).toEqual(['https://api.telegram.org/botTOKEN/sendMessage']);
  });
});
