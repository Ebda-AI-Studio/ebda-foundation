// Shared plumbing of the cloud watchers (services, page-load, journey-monitor, deploy-drift, pr-shepherd, cf-workers,
// sentry-stale, cost-guard, world-watch, dr-drill). Every watcher is a function of (env, sink, now, fetch): no globals,
// so tests inject a fake fetch and an in-memory sink. They run from the Worker cron, never inside the Durable Object.
//
// Contract every watcher keeps:
//  - findings carry source 'watcher' and a stable key `<watcher>:<subject>:<state>`; the classifier picks the lane;
//  - a missing config var skips the work and raises ONE deduped `monitor-unconfigured` finding (a silent watcher is visible);
//  - an API failure (non-2xx, timeout, unparsable JSON, GraphQL 200 + errors) is a `watcher-error` finding, never "all clear";
//  - tokens come from env bindings and are never logged or copied into a finding.
import type { Env } from '../env';
import { isPlaceholder } from '../env';
import type { Finding } from '../findings';

export const WATCHER_SOURCE = 'watcher';
export const FETCH_TIMEOUT_MS = 10000;

/** The slice of BrainDO the watchers need (a DurableObjectStub satisfies it; tests pass a fake). */
export interface Sink {
  ingestMany(fs: Finding[], now?: number): Promise<{ raised: number; deduped: number }>;
  resolveFinding(f: Pick<Finding, 'source' | 'kind' | 'key'>, outcome: string, now?: number): Promise<boolean>;
  reconcile(source: string, kind: string, keyPrefix: string, openKeys: string[], now?: number): Promise<number>;
  /** newest finish time of a hands job for this finding class whose outcome has the explicit drill:'pass' marker, or null */
  lastPassAt(source: string, kind: string): Promise<number | null>;
}

export interface WatchCtx {
  env: Env;
  sink: Sink;
  now: number;
  fetchImpl: typeof fetch;
}

export class WatcherError extends Error {}

/** True when a config var is usable (set, not an unrendered template placeholder). */
export function isSet(v: string | undefined): v is string {
  return !isPlaceholder(v) && v!.trim() !== '';
}

/** Parse a JSON-array var and keep the items `guard` accepts. null = var unset (unconfigured); [] = set but nothing valid. */
export function parseList<T>(raw: string | undefined, guard: (x: unknown) => x is T, max = 20): T[] | null {
  if (!isSet(raw)) return null;
  try {
    const v = JSON.parse(raw) as unknown;
    return Array.isArray(v) ? v.filter(guard).slice(0, max) : [];
  } catch {
    return [];
  }
}

export const isHttps = (u: unknown): u is string => typeof u === 'string' && /^https:\/\/[^\s]+$/.test(u);
export const isObj = (x: unknown): x is Record<string, unknown> => !!x && typeof x === 'object' && !Array.isArray(x);

export function numVar(v: string | undefined, fallback: number): number {
  const n = Number(v);
  return isSet(v) && Number.isFinite(n) && n > 0 ? n : fallback;
}

/** KV gate so a cron that fires more often than a watcher's cadence (or is retried) does the work once per interval. */
export async function due(ctx: WatchCtx, id: string, intervalMs: number): Promise<boolean> {
  const k = `wd:last:${id}`;
  const last = Number((await ctx.env.EVENTS.get(k)) ?? 0);
  // 10% slack: a cron fired a few seconds early must not skip a whole interval
  if (ctx.now - last < intervalMs * 0.9) return false;
  await ctx.env.EVENTS.put(k, String(ctx.now));
  return true;
}

/** GET/POST and parse JSON. Anything but a 2xx with a JSON body throws: an HTTP 200 alone is not health. */
export async function httpJson(ctx: WatchCtx, url: string, init: RequestInit = {}, timeoutMs = FETCH_TIMEOUT_MS): Promise<unknown> {
  let r: Response;
  try {
    r = await ctx.fetchImpl(url, { ...init, signal: AbortSignal.timeout(timeoutMs), headers: { 'user-agent': 'ebda-os-brain/watcher', accept: 'application/json', ...(init.headers as Record<string, string> | undefined) } });
  } catch (e) {
    throw new WatcherError(`request failed: ${(e as Error).name === 'TimeoutError' ? 'timeout' : 'network error'}`);
  }
  if (r.status < 200 || r.status > 299) {
    await r.body?.cancel();
    throw new WatcherError(`HTTP ${r.status}`);
  }
  try {
    return (await r.json()) as unknown;
  } catch {
    throw new WatcherError('response is not JSON');
  }
}

/** GraphQL: HTTP 200 with an `errors` array is a failure, not an empty result. */
export async function graphql(ctx: WatchCtx, url: string, token: string, query: string, variables: Record<string, unknown>): Promise<Record<string, any>> {
  const j = (await httpJson(ctx, url, { method: 'POST', headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' }, body: JSON.stringify({ query, variables }) })) as { data?: unknown; errors?: unknown } | null;
  if (!j || (Array.isArray(j.errors) && j.errors.length) || !isObj(j.data)) {
    const first = Array.isArray(j?.errors) ? (j!.errors as Array<{ message?: unknown }>)[0]?.message : undefined;
    throw new WatcherError(`GraphQL error${typeof first === 'string' ? `: ${first.slice(0, 120)}` : ''}`);
  }
  return j.data as Record<string, any>;
}

export function finding(id: string, kind: string, subject: string, state: string, title: string, extra: Partial<Finding> = {}): Finding {
  return { source: WATCHER_SOURCE, kind, key: `${id}:${subject}:${state}`, title: title.slice(0, 200), ...extra };
}

/** One deduped finding saying a watcher cannot run because its config is missing. */
export async function reportUnconfigured(ctx: WatchCtx, id: string, what: string): Promise<void> {
  await ctx.sink.ingestMany([finding(id, 'monitor-unconfigured', 'config', 'unconfigured', `watcher ${id} is not running: ${what} is not set`, { severity: 'P3' })], ctx.now);
}

export async function reportError(ctx: WatchCtx, id: string, subject: string, e: unknown): Promise<void> {
  const msg = e instanceof WatcherError ? e.message : (e as Error)?.message ?? 'unknown error';
  await ctx.sink.ingestMany([finding(id, 'watcher-error', subject, 'error', `watcher ${id} (${subject}) could not read its source: ${msg}`.slice(0, 200), { severity: 'P3' })], ctx.now);
}

export async function clearError(ctx: WatchCtx, id: string, subject: string): Promise<void> {
  await ctx.sink.resolveFinding({ source: WATCHER_SOURCE, kind: 'watcher-error', key: `${id}:${subject}:error` }, 'source readable again', ctx.now);
}

/** Raise the current findings of one kind and resolve earlier ones of that watcher that are gone (only when the read was complete). */
export async function settle(ctx: WatchCtx, id: string, kind: string, current: Finding[], complete = true): Promise<void> {
  if (current.length) await ctx.sink.ingestMany(current, ctx.now);
  if (complete) await ctx.sink.reconcile(WATCHER_SOURCE, kind, `${id}:`, current.map((f) => f.key), ctx.now);
}
