// prod-watch on the brain's Cron Trigger (ruling AIOS-7, Ahmad 2026-11-11). GitHub ran the */10 schedule of
// .github/workflows/prod-watch.yml about once in ten hours, so the PRIMARY probe loop now runs here, every 10 min, with the same
// probe list (os/config/prod-watch.json) and the same alert rules (os/ops/lib/ebda-logs-core.mjs). The GitHub run stays as the
// SECONDARY heartbeat from outside Cloudflare: it still reads the R2 logs, sends the daily digest, and messages probe alerts
// itself whenever the brain does not answer (a Cloudflare-wide failure takes the brain down with what it watches).
import cfg from '../../../config/prod-watch.json';
import { brainListing, decide, evaluateProbeAlerts, LOG_ALERT_PREFIXES, type ProbeResult, type WatchState } from '../../../ops/lib/ebda-logs-core.mjs';
import { boundFetch } from './bound-fetch';
import type { Env } from './env';
import type { Finding } from './findings';
import { sendTelegram } from './telegram';

export const PROD_WATCH_INTERVAL_MS = 10 * 60_000;
const STATE_KEY = 'pw:state';
const LAST_KEY = 'pw:last';

interface ProbeCfg { name: string; url: string; expect?: number; contains?: string; fxMaxAgeHours?: number; fxNoDataUntil?: string }
interface Sink {
  ingestMany(fs: Finding[], now: number): Promise<unknown>;
  reconcileSource(source: string, openKeys: string[], keepPrefixes: string[], now: number, seenAs?: string): Promise<number>;
}

export async function probeOne(p: ProbeCfg, timeoutMs: number, fetchImpl: typeof fetch = boundFetch): Promise<ProbeResult> {
  const t0 = Date.now();
  try {
    const r = await fetchImpl(p.url, { redirect: 'manual', headers: { 'user-agent': 'ebda-prod-watch/1 (+brain-cron)' }, signal: AbortSignal.timeout(timeoutMs) });
    const body = await r.text();
    let ok = r.status === (p.expect ?? 200);
    let error = ok ? undefined : `HTTP ${r.status}`;
    if (ok && p.contains && !new RegExp(p.contains).test(body)) {
      ok = false;
      error = 'body check failed';
    }
    let fx: { ageHours: number | null; maxHours: number; noDataUntil?: string } | undefined;
    if (p.fxMaxAgeHours) {
      let json: { fxAgeHours?: number | null } | null = null;
      try { json = JSON.parse(body); } catch { /* not json: reads as no data */ }
      fx = { ageHours: json?.fxAgeHours ?? null, maxHours: p.fxMaxAgeHours, noDataUntil: p.fxNoDataUntil };
    }
    return { name: p.name, url: p.url, ok, status: r.status, ms: Date.now() - t0, ...(error ? { error } : {}), ...(fx ? { fx } : {}) };
  } catch (e) {
    return { name: p.name, url: p.url, ok: false, status: 0, ms: Date.now() - t0, error: (e as Error).name === 'TimeoutError' ? `timeout after ${timeoutMs}ms` : `network: ${(e as Error).message}` };
  }
}

/** One run when due (KV-gated to 10 min, so the 5-min tick runs it every other time). Returns null when not due. */
export async function runProdWatch(env: Env, sink: Sink, now: number, fetchImpl: typeof fetch = boundFetch): Promise<{ probes: number; failing: number; messages: number } | null> {
  if (String(env.PROD_WATCH_ON_BRAIN ?? '0') !== '1') return null;
  const last = Number((await env.EVENTS.get(LAST_KEY)) ?? 0);
  if (now - last < PROD_WATCH_INTERVAL_MS * 0.9) return null;
  await env.EVENTS.put(LAST_KEY, String(now));
  const probes = await Promise.all((cfg.probes as ProbeCfg[]).map((p) => probeOne(p, cfg.timeoutMs ?? 10000, fetchImpl)));
  const state = JSON.parse((await env.EVENTS.get(STATE_KEY)) ?? '{}') as WatchState;
  const pr = evaluateProbeAlerts(probes, state, 2, now);
  // the brain reads no logs: log-rule keys are owned by the GitHub run and never resolved from here
  const d = decide(pr.alerts, { ...state, streaks: pr.streaks }, now, { unknownPrefixes: LOG_ALERT_PREFIXES });
  for (const m of d.messages) {
    await sendTelegram(env.TELEGRAM_BOT_TOKEN, env.TELEGRAM_CHAT_ID, { dedupeKey: `pw:${m.slice(0, 60)}`, kind: 'p1-unhealed', text: `${m}\n(prod-watch, brain cron)` }, fetchImpl).catch(() => undefined);
  }
  await env.EVENTS.put(STATE_KEY, JSON.stringify({ ...d.state, streaks: pr.streaks, digest: (d.state.digest ?? []).slice(-50) }));
  const listing = brainListing(pr.alerts, { logsRead: false });
  if (listing.findings.length) await sink.ingestMany(listing.findings as Finding[], now);
  await sink.reconcileSource('prod-watch', listing.findings.map((f) => f.key), [...LOG_ALERT_PREFIXES, 'alert-drill:'], now, 'prod-watch-cf');
  return { probes: probes.length, failing: probes.filter((p) => !p.ok).length, messages: d.messages.length };
}
