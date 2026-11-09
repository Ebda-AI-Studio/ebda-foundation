// Dollar accounting for the API-key hands (RR-hands-api-auth). The meter sits at the forwarder (lib/egress.mjs): every API response's REAL
// `usage` is priced per request with the table below and reported to the brain as it happens, so a job that is killed, times out or is swept
// still has its spend recorded. The Claude `result` event is only a fallback when the forwarder is off.
//
// PRICES: USD per million tokens, pinned to explicit model IDs (an alias can move to a model with another rate; the table must match what is
// billed). Source: Anthropic pricing page https://www.anthropic.com/pricing, rates given by Ahmad's coordinator on 2026-11-09 (NOT re-read from the
// page by this code; re-check the page and update the table + this date when it changes, or override with HANDS_PRICES_JSON):
//   claude-opus-5-5    in $4    out $20   cache read $0.20
//   claude-sonnet-5-5  in $2    out $10   cache read $0.10
//   claude-haiku-5-5   in $0.10 out $0.50 cache read $0.01   while the request's context is <= 100k tokens
//                      in $0.50 out $2.50 cache read $0.05   (0.1 x input) above 100k tokens
// Cache writes: 5-minute = 1.25 x input, 1-hour = 2 x input. inference_geo "us" would be 1.1 x: the forwarder REFUSES any request that sets
// inference_geo, so the multiplier never applies (a test pins the refusal). An unknown model is priced as the dearest entry, never as free.
export const MODEL_IDS = { haiku: 'claude-haiku-5-5', sonnet: 'claude-sonnet-5-5', opus: 'claude-opus-5-5' };
export const ROUTED_ALIASES = Object.keys(MODEL_IDS);

/** model id -> rates; `tiers` = ascending context thresholds (tokens) with their own rates. */
export const DEFAULT_PRICES = {
  'claude-opus-5-5': { in: 4, out: 20, cacheRead: 0.2 },
  'claude-sonnet-5-5': { in: 2, out: 10, cacheRead: 0.1 },
  'claude-haiku-5-5': { in: 0.1, out: 0.5, cacheRead: 0.01, over: { threshold: 100_000, in: 0.5, out: 2.5, cacheRead: 0.05 } },
};

export function priceTable(env = {}) {
  let extra = {};
  try {
    extra = env.HANDS_PRICES_JSON ? JSON.parse(env.HANDS_PRICES_JSON) : {};
  } catch {
    extra = {};
  }
  const out = { ...DEFAULT_PRICES };
  for (const [k, v] of Object.entries(extra)) if (v && Number(v.in) >= 0 && Number(v.out) >= 0) out[k] = { ...v, in: Number(v.in), out: Number(v.out) };
  return out;
}

/** The table entry for a model id (exact, then by family name); an unknown model gets the dearest entry. */
export function modelKey(model, table) {
  const m = String(model ?? '').toLowerCase();
  if (table[m]) return m;
  for (const k of Object.keys(table)) if (m.includes(k)) return k;
  for (const alias of ROUTED_ALIASES) if (m.includes(alias) && table[MODEL_IDS[alias]]) return MODEL_IDS[alias];
  return Object.entries(table).sort((a, b) => b[1].out - a[1].out)[0][0];
}

const n = (x) => (Number.isFinite(Number(x)) && Number(x) > 0 ? Number(x) : 0);

/**
 * One API response's usage -> dollars. usage = the API `usage` object: input_tokens, output_tokens, cache_read_input_tokens,
 * cache_creation_input_tokens and, when present, cache_creation: {ephemeral_5m_input_tokens, ephemeral_1h_input_tokens} (the split decides
 * 1.25 x vs 2 x; an unsplit cache_creation total is priced as 1-hour, the dearer one).
 */
export function costOf(usage, model, table) {
  const key = modelKey(model, table);
  const base = table[key];
  const inT = n(usage?.input_tokens);
  const outT = n(usage?.output_tokens);
  const cr = n(usage?.cache_read_input_tokens);
  const split = usage?.cache_creation;
  const w5 = split ? n(split.ephemeral_5m_input_tokens) : 0;
  const w1 = split ? n(split.ephemeral_1h_input_tokens) : n(usage?.cache_creation_input_tokens);
  const context = inT + cr + w5 + w1;
  const p = base.over && context > base.over.threshold ? { ...base, ...base.over } : base;
  const usd = (inT * p.in + outT * p.out + cr * (p.cacheRead ?? p.in * 0.1) + w5 * (p.cacheWrite5m ?? p.in * 1.25) + w1 * (p.cacheWrite1h ?? p.in * 2)) / 1e6;
  return { model: key, inputTokens: inT, outputTokens: outT, cacheReadTokens: cr, cacheWriteTokens: w5 + w1, costUsd: Math.round(usd * 1e8) / 1e8 };
}
