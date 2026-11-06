// journey-monitor watcher (cron, every 15 min): synthetic guest journeys over plain HTTP, e.g. storefront home -> product
// page -> cart. Strictly read-only: every step is a GET, no cookies, no forms. A step whose URL path looks like checkout,
// payment or order creation is REFUSED at parse time (the journey is dropped and reported as a config error), so a typo in
// JOURNEY_CONFIG can never start a purchase. A step fails on non-2xx, timeout, or a missing `contains` text.
import { finding, isHttps, isObj, parseList, reportUnconfigured, settle, WatcherError, reportError, clearError, type WatchCtx } from './common';

export const ID = 'journey-monitor';
export const INTERVAL_MS = 15 * 60 * 1000;
const FORBIDDEN_PATH = /checkout|payment|\bpay\b|purchase|\border(s)?\b|place-order|confirm|webhook|login|signin|sign-in|register/i;

export interface JourneyStep {
  name: string;
  url: string;
  contains?: string;
}
export interface Journey {
  name: string;
  steps: JourneyStep[];
}

export function isStep(x: unknown): x is JourneyStep {
  if (!isObj(x) || !isHttps(x.url) || typeof x.name !== 'string' || !/^[\w .-]{1,40}$/.test(x.name)) return false;
  if (x.contains !== undefined && (typeof x.contains !== 'string' || x.contains.length > 200)) return false;
  try {
    return !FORBIDDEN_PATH.test(new URL(x.url).pathname);
  } catch {
    return false;
  }
}
const isJourney = (x: unknown): x is Journey => isObj(x) && typeof x.name === 'string' && /^[\w.-]{1,40}$/.test(x.name) && Array.isArray(x.steps) && x.steps.length >= 1 && x.steps.length <= 6 && x.steps.every(isStep);

async function runStep(ctx: WatchCtx, s: JourneyStep): Promise<string | null> {
  try {
    const r = await ctx.fetchImpl(s.url, { method: 'GET', redirect: 'follow', signal: AbortSignal.timeout(10000), headers: { 'user-agent': 'ebda-os-brain/journey' } });
    if (r.status < 200 || r.status > 299) {
      await r.body?.cancel();
      return `HTTP ${r.status}`;
    }
    const body = await r.text();
    if (s.contains && !body.includes(s.contains)) return 'expected text missing';
    return null;
  } catch {
    return 'no response';
  }
}

export async function watchJourneys(ctx: WatchCtx): Promise<{ journeys: number; failed: string[] }> {
  const raw = ctx.env.JOURNEY_CONFIG;
  const journeys = parseList(raw, isJourney, 5);
  if (journeys === null) {
    await reportUnconfigured(ctx, ID, 'JOURNEY_CONFIG (JSON list of {name,steps:[{name,url,contains?}]})');
    return { journeys: 0, failed: [] };
  }
  let declared = 0;
  try {
    declared = (JSON.parse(raw!) as unknown[]).length;
  } catch {
    /* parseList already returned [] */
  }
  if (journeys.length < declared || declared === 0) await reportError(ctx, ID, 'config', new WatcherError('JOURNEY_CONFIG has an invalid or non-read-only journey (checkout/payment/order/login paths are refused)'));
  else await clearError(ctx, ID, 'config');
  const current = [];
  const failed: string[] = [];
  for (const j of journeys) {
    for (const [i, s] of j.steps.entries()) {
      const why = await runStep(ctx, s);
      if (why) {
        failed.push(j.name);
        current.push(finding(ID, 'journey-failed', j.name, 'failed', `journey ${j.name} broke at step ${i + 1} (${s.name}): ${why}`, { url: s.url, severity: 'P2', detail: { step: s.name, reason: why } }));
        break; // later steps depend on this one
      }
    }
  }
  await settle(ctx, ID, 'journey-failed', current);
  return { journeys: journeys.length, failed };
}
