// Dollar accounting for the API-key hands (RR-hands-api-auth). The cost of a job is computed here from the token counts of the Claude
// result event (usage: input / output / cache read / cache creation) x a PRICE TABLE kept in config, and reported to the brain with the
// outcome; the brain keeps the daily and monthly totals and halts at the budget. The defaults below are ESTIMATES of Anthropic's list
// prices (USD per million tokens) and must be checked against https://www.anthropic.com/pricing; override with HANDS_PRICES_JSON, e.g.
// {"sonnet":{"in":3,"out":15}}. An unknown model is priced as the most expensive one (never as free). Cache reads cost 0.1 x input and cache
// writes 1.25 x input unless the table says otherwise. Prompt caching itself is Claude Code's default: nothing here may disable it.
export const DEFAULT_PRICES = {
  haiku: { in: 1, out: 5 },
  sonnet: { in: 3, out: 15 },
  opus: { in: 5, out: 25 },
};

export function priceTable(env = {}) {
  let extra = {};
  try {
    extra = env.HANDS_PRICES_JSON ? JSON.parse(env.HANDS_PRICES_JSON) : {};
  } catch {
    extra = {};
  }
  const out = { ...DEFAULT_PRICES };
  for (const [k, v] of Object.entries(extra)) if (v && Number(v.in) >= 0 && Number(v.out) >= 0) out[k] = { in: Number(v.in), out: Number(v.out), ...(v.cacheRead !== undefined ? { cacheRead: Number(v.cacheRead) } : {}), ...(v.cacheWrite !== undefined ? { cacheWrite: Number(v.cacheWrite) } : {}) };
  return out;
}

/** 'claude-sonnet-4-5-...' / 'sonnet' -> 'sonnet'; anything unrecognised -> the dearest model in the table. */
export function modelKey(model, table) {
  const m = String(model ?? '').toLowerCase();
  for (const k of Object.keys(table)) if (m.includes(k)) return k;
  return Object.entries(table).sort((a, b) => b[1].out - a[1].out)[0][0];
}

/** usage = the Claude result event's `usage` ({input_tokens, output_tokens, cache_read_input_tokens, cache_creation_input_tokens}). */
export function costOf(usage, model, table) {
  const key = modelKey(model, table);
  const p = table[key];
  const n = (x) => (Number.isFinite(Number(x)) && Number(x) > 0 ? Number(x) : 0);
  const inT = n(usage?.input_tokens);
  const outT = n(usage?.output_tokens);
  const cr = n(usage?.cache_read_input_tokens);
  const cw = n(usage?.cache_creation_input_tokens);
  const usd = (inT * p.in + outT * p.out + cr * (p.cacheRead ?? p.in * 0.1) + cw * (p.cacheWrite ?? p.in * 1.25)) / 1e6;
  return { model: key, inputTokens: inT, outputTokens: outT, cacheReadTokens: cr, cacheWriteTokens: cw, costUsd: Math.round(usd * 1e6) / 1e6 };
}
