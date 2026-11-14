import { describe, expect, it } from 'vitest';
import { buildAudit } from './audit';

const base = { storeId: 's1', userId: 'u1', turnId: 't1', at: 1, releaseId: 'abc123abc123', rails: { scope: 'ok', secretsFound: 0 }, toolsOffered: ['a'], toolCalls: [], outcome: 'answered' as const, inputTokens: 1, outputTokens: 2, model: 'm' };

describe('buildAudit', () => {
  it('never contains an unmasked phone, email, card or secret', () => {
    const row = buildAudit({ ...base, prompt: 'كلمني على 01001234567 او a@b.com كارت 4242 4242 4242 4242 password: hunter2', output: 'تمام ٠١٠٠١٢٣٤٥٦٧ EAAGm0PX4ZCpsBO1234567890abcdefghijKLMN', rails: { note: 'call 01001234567' } });
    const all = JSON.stringify(row);
    expect(all).not.toMatch(/01001234567|٠١٠٠١٢٣٤٥٦٧|a@b\.com|4242|hunter2|EAAG/);
    expect(row.maskedPrompt).toContain('[phone]');
    expect(row.maskedPrompt).toContain('[secret]');
  });
  it('keeps the release id and decision fields and gives each row an id', () => {
    const a = buildAudit({ ...base, prompt: 'x', output: 'y', previewId: 'p1', decision: 'confirmed' });
    const b = buildAudit({ ...base, prompt: 'x', output: 'y' });
    expect(a.releaseId).toBe('abc123abc123');
    expect(a.previewId).toBe('p1');
    expect(a.decision).toBe('confirmed');
    expect(a.id).not.toBe(b.id);
    expect('previewId' in b).toBe(false);
  });
});
