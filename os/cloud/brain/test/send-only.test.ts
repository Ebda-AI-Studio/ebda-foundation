// The brain REUSES @EbdaAIStudiobot, which the tg-relay session already polls with getUpdates. Telegram allows ONE consumer per bot:
// a setWebhook or a second getUpdates from the brain would silently break the relay. So the brain is SEND-ONLY: sendMessage (alerts,
// questions, the daily digest) and answerCallbackQuery (acknowledge a button the relay forwarded). Inbound button answers reach it
// through POST /telegram/webhook, an authenticated brain endpoint the relay calls; the brain never registers it with Telegram.
import { describe, expect, it } from 'vitest';
import { sendTelegram } from '../src/telegram';

const sources = import.meta.glob('../src/**/*.ts', { query: '?raw', import: 'default', eager: true }) as Record<string, string>;

describe('send-only Telegram', () => {
  it('finds the brain sources (guards the glob itself)', () => {
    expect(Object.keys(sources).length).toBeGreaterThan(10);
    expect(Object.keys(sources).some((k) => k.endsWith('telegram.ts'))).toBe(true);
  });
  it('no brain source calls setWebhook, deleteWebhook, getUpdates or getWebhookInfo', () => {
    const hits = Object.entries(sources).flatMap(([file, text]) => [...text.matchAll(/setWebhook|deleteWebhook|getUpdates|getWebhookInfo/gi)].map((m) => `${file}: ${m[0]}`));
    expect(hits).toEqual([]);
  });
  it('the only Telegram Bot API methods in the sources are sendMessage, editMessageText and answerCallbackQuery', () => {
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
