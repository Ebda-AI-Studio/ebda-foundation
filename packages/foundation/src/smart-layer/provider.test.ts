import { describe, expect, it } from 'vitest';
import { WorkersAiProvider } from './provider';

describe('WorkersAiProvider wire format', () => {
  it('sends an empty string, never null, as the content of a tool-calling assistant turn (Workers AI rejects null with HTTP 400)', async () => {
    let sent: { messages: { role: string; content: unknown }[] } | undefined;
    const ai = { run: async (_m: string, input: Record<string, unknown>) => { sent = input as typeof sent; return { response: 'ok' }; } };
    await new WorkersAiProvider(ai, 'm').complete({
      system: 's',
      messages: [
        { role: 'user', content: 'hi' },
        { role: 'assistant', content: '', toolCalls: [{ id: 'c1', name: 'f', arguments: {} }] },
        { role: 'tool', content: '{}', toolCallId: 'c1', name: 'f' },
      ],
      tools: [{ name: 'f', description: 'd', parameters: { type: 'object', properties: {} } }],
      maxTokens: 10,
    } as never);
    const assistant = sent!.messages.find((m) => m.role === 'assistant')!;
    expect(assistant.content).toBe('');
    expect(sent!.messages.every((m) => typeof m.content === 'string')).toBe(true);
  });
});
