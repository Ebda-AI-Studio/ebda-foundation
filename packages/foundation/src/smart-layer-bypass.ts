import { createHash } from 'node:crypto';
import type { GuardConfig, Violation } from './capability';
import { stripComments } from './guards';

// Written so no regex source matches itself: this file is vendored into products and scanned there.
export const MODEL_CALL_PATTERNS: readonly { name: string; re: RegExp }[] = [
  { name: 'workers-ai', re: /\benv\.AI\b|\.AI\.run\(/ },
  { name: 'google-genai-sdk', re: /@google\/genai/ },
  { name: 'google-generative-ai-sdk', re: /@google\/generative-ai/ },
  { name: 'gemini-rest', re: /generativelanguage\.googleapis\.com/ },
  { name: 'openai-rest', re: /api\.openai\.com/ },
  { name: 'anthropic-rest', re: /api\.anthropic\.com/ },
  { name: 'anthropic-sdk', re: /@anthropic-ai\/sdk/ },
  { name: 'openai-sdk', re: /from\s+['"]openai['"]/ },
];
const WRANGLER_AI = { name: 'wrangler-ai-binding', re: /"ai"\s*:\s*\{/ };

const skipped = (p: string): boolean => /\.d\.ts$/.test(p) || /\.(?:test|spec)\.[cm]?[jt]sx?$/.test(p) || /(?:^|\/)(?:__tests__|tests?|e2e|__mocks__|fixtures)\//.test(p);
const sha = (s: string) => createHash('sha1').update(s).digest('hex').slice(0, 10);

/** Direct model calls outside the Smart Layer (192.6). Keys are content hashes, never line numbers, so unrelated edits do not churn the baseline. */
export function checkModelBypass(files: { path: string; src: string }[], cfg: Pick<GuardConfig, 'smartLayerPaths'>): Violation[] {
  const out: Violation[] = [];
  for (const f of files) {
    if (skipped(f.path) || cfg.smartLayerPaths.some((p) => f.path.startsWith(p))) continue;
    const patterns = /(?:^|\/)wrangler\.jsonc?$/.test(f.path) ? [...MODEL_CALL_PATTERNS, WRANGLER_AI] : MODEL_CALL_PATTERNS;
    const seen = new Map<string, number>();
    for (const line of stripComments(f.src).split('\n')) {
      const t = line.trim();
      if (!t) continue;
      for (const p of patterns) {
        if (!p.re.test(t)) continue;
        const base = `${f.path}|${p.name}|${sha(t)}`;
        const n = seen.get(base) ?? 0;
        seen.set(base, n + 1);
        out.push({ rule: 'model-call-outside-smart-layer', key: `${base}|${n}`, message: `${f.path}: direct model call (${p.name}) outside the Smart Layer` });
      }
    }
  }
  return out;
}
