import { describe, expect, it } from 'vitest';
import { listTextModels, restAiBinding } from './rest-ai';

describe('restAiBinding', () => {
  it('run posts to /ai/run/<model> with bearer and returns result', async () => {
    let seen: { url: string; auth: string | null; body: string } | undefined;
    const fetchStub = (async (url: string, init: RequestInit) => {
      seen = { url, auth: new Headers(init.headers).get('authorization'), body: String(init.body) };
      return new Response(JSON.stringify({ success: true, result: { response: 'hi' } }), { status: 200 });
    }) as unknown as typeof fetch;
    const out = await restAiBinding({ accountId: 'acc', apiToken: 'tok', fetch: fetchStub }).run('@cf/x', { prompt: 'p' });
    expect(out).toEqual({ response: 'hi' });
    expect(seen?.url).toBe('https://api.cloudflare.com/client/v4/accounts/acc/ai/run/@cf/x');
    expect(seen?.auth).toBe('Bearer tok');
    expect(JSON.parse(seen!.body)).toEqual({ prompt: 'p' });
  });
  it('non-2xx throws without echoing the body', async () => {
    const fetchStub = (async () => new Response('SECRET-ECHO prompt text', { status: 429 })) as unknown as typeof fetch;
    const err = await restAiBinding({ accountId: 'a', apiToken: 't', fetch: fetchStub }).run('@cf/x', {}).catch((e: Error) => e);
    expect((err as Error).message).toContain('429');
    expect((err as Error).message).not.toContain('SECRET-ECHO');
  });
});

describe('listTextModels', () => {
  it('maps function calling, deprecation and price properties', async () => {
    const result = [
      { name: '@cf/a/fc', properties: [{ property_id: 'function_calling', value: 'true' }, { property_id: 'price', value: [{ unit: 'per M input tokens', price: 0.1 }, { unit: 'per M output tokens', price: 0.3 }] }] },
      { name: '@cf/b/old', properties: [{ property_id: 'planned_deprecation_date', value: '2026-11-20' }] },
    ];
    const fetchStub = (async () => new Response(JSON.stringify({ result }), { status: 200 })) as unknown as typeof fetch;
    const models = await listTextModels({ accountId: 'a', apiToken: 't', fetch: fetchStub });
    expect(models[0]).toMatchObject({ id: '@cf/a/fc', functionCalling: true, pricePerMIn: 0.1, pricePerMOut: 0.3 });
    expect(models[1]).toMatchObject({ id: '@cf/b/old', functionCalling: false, deprecatedOn: '2026-11-20' });
  });
});
