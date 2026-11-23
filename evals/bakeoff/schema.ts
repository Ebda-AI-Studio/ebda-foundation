/** Bake-off prompt set schema (plan 4 Task 0.1). Hand-written row check: no Zod in foundation. */
export type BakeoffLang = 'ar-EG' | 'franco' | 'en';
export type BakeoffJob = 'answer' | 'plan' | 'template' | 'safety';
export type ExpectedTool = { name: string; args?: Record<string, unknown> };
export type BakeoffPrompt = {
  id: string;
  lang: BakeoffLang;
  job: BakeoffJob;
  text: string;
  capabilityId?: string;
  /** Grounding excerpt shown to the model like the engine's help retrieval (answer + template-answer rows). */
  context?: string;
  /** Optional author tags: 'digits-ar' (Arabic-Indic digits), 'typo'. */
  tags?: string[];
  expect: {
    tools?: ExpectedTool[];
    mustRefuse?: boolean;
    mustConfirm?: boolean;
    facts?: string[];
    /** Strings that must never appear in the reply (pasted secrets, the system-prompt canary). */
    mustNotContain?: string[];
  };
};

const LANGS = ['ar-EG', 'franco', 'en'];
const JOBS = ['answer', 'plan', 'template', 'safety'];

export function parsePrompts(jsonl: string): BakeoffPrompt[] {
  const out: BakeoffPrompt[] = [];
  const lines = jsonl.split('\n');
  lines.forEach((raw, i) => {
    if (raw.trim() === '') return;
    const at = (m: string) => new Error(`line ${i + 1}: ${m}`);
    let r: any;
    try {
      r = JSON.parse(raw);
    } catch {
      throw at('not valid JSON');
    }
    if (!r || typeof r !== 'object') throw at('row is not an object');
    if (typeof r.id !== 'string' || !r.id) throw at('missing id');
    if (!LANGS.includes(r.lang)) throw at(`bad lang ${String(r.lang)}`);
    if (!JOBS.includes(r.job)) throw at(`bad job ${String(r.job)}`);
    if (typeof r.text !== 'string' || !r.text.trim()) throw at('missing text');
    if (!r.expect || typeof r.expect !== 'object') throw at('missing expect');
    if (r.expect.tools !== undefined && (!Array.isArray(r.expect.tools) || r.expect.tools.some((t: any) => typeof t?.name !== 'string'))) throw at('bad expect.tools');
    out.push(r as BakeoffPrompt);
  });
  return out;
}
