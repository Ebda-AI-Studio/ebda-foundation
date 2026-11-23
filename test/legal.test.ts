import { createHash } from 'node:crypto';
import { readdirSync, readFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { expect, it } from 'vitest';

// Counsel-approved legal text (Ahmad 2026-11-19, Ruling LEGAL-FINAL-1 follow-up; Store #966) lives here byte for byte and every product vendors it, so
// the consumer lock (sha256 per file) is the pin that replaced Chat's hand-kept LEGAL_PINS. Changing a file means a new pin HERE (the reminder), a new
// foundation tag, and a re-vendor in the Store and Chat; never a reworded clause. The Store publishes these on ebda.app.
const LEGAL = resolve(__dirname, '../legal');
const PINS: Record<string, string> = {
  'clauses/VAT-0-clause.md': '9e308d934800b655673aa0491ec88f822811e79bc01793d7ca43067fd22c50a0',
  'whatsapp/ar/whatsapp-dpa.md': 'f094e4603a11de5c9d72ea0f0dca59f8d7921e4e30af6b642c6efe3563d65231',
  'whatsapp/ar/whatsapp-privacy.md': '31ab82572623b3c2babf14894b46af9df9dc1d5aedc337c90ad1c4519b6f1e61',
  'whatsapp/ar/whatsapp-terms.md': 'c498024f8cc67030094f6a9c1a1e9b24f8e0aa9944125c5ecdc3ec8c07557f8c',
  'whatsapp/en/whatsapp-dpa.md': '80c68806be3e678bfb2234b6302b72ce9e0e803e561f005aad0dfee99fee9324',
  'whatsapp/en/whatsapp-privacy.md': 'db96a6070a6d183cc2b59a031b5ba99c52f6d0c9b5738f9723d0107d9478622e',
  'whatsapp/en/whatsapp-terms.md': '83163a51b281fc7d9f697bf49ffa9f169bb1a416a4e4bf5ca8945968cbc6ebcd',
};
const walk = (d: string): string[] => readdirSync(d, { withFileTypes: true }).flatMap((e) => (e.isDirectory() ? walk(join(d, e.name)) : [join(d, e.name)]));

it('legal/ holds exactly the pinned files, byte for byte', () => {
  const files = walk(LEGAL).map((f) => f.slice(LEGAL.length + 1)).sort();
  expect(files).toEqual(Object.keys(PINS).sort());
  for (const f of files) expect(createHash('sha256').update(readFileSync(join(LEGAL, f))).digest('hex'), f).toBe(PINS[f]);
});

it('the VAT-0 clause keeps its two paragraphs (English, Arabic) in the shape every consumer extracts', () => {
  const md = readFileSync(join(LEGAL, 'clauses/VAT-0-clause.md'), 'utf8');
  expect(/## English\n\n(.+)\n/.exec(md)?.[1]).toContain('We are not registered for value-added tax');
  expect(/## العربية\n\n(.+)\n/.exec(md)?.[1]).toContain('غير مسجّلين في ضريبة القيمة المضافة');
});
