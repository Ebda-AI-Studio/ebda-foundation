// The platform alert feed (Ahmad 2026-11-11: "why do I have to paste Telegram alerts?"). Every alert the Ebda platform sends to Telegram
// is also POSTed here (POST /alerts, Bearer INGEST_TOKEN), and every failed default-branch workflow run seen by the org webhook is
// recorded as one (ruling AIOS-8), because a Telegram bot cannot read its own outgoing messages. Stored with an id + timestamp,
// deduped, readable at GET /api/alerts?since=<id> (newest first), and P0/P1 alerts become findings the OS acts on.
export type AlertLevel = 'p0' | 'p1' | 'p2' | 'info';
export interface PlatformAlert {
  /** who sent it: ebda-store/api, ebda-store/status, github/<owner>/<repo>, ... */
  source: string;
  level: AlertLevel;
  title: string;
  /** the full text the platform sent to Telegram */
  text: string;
  url?: string;
  repo?: string;
  /** epoch ms the sender produced it (defaults to receipt time) */
  at?: number;
}
export const ALERT_LEVELS: ReadonlyArray<AlertLevel> = ['p0', 'p1', 'p2', 'info'];
/** the same alert (source + level + title + text) inside this window is one row with a count, not a new id */
export const ALERT_DEDUPE_MS = 10 * 60_000;

export function validateAlert(x: unknown): string | null {
  if (!x || typeof x !== 'object') return 'alert must be an object';
  const a = x as Record<string, unknown>;
  for (const k of ['source', 'title', 'text'] as const) {
    if (typeof a[k] !== 'string' || !(a[k] as string).trim()) return `${k} must be a non-empty string`;
  }
  if ((a.source as string).length > 100 || (a.title as string).length > 300) return 'source <= 100 and title <= 300 chars';
  if ((a.text as string).length > 4096) return 'text must be <= 4096 chars (a Telegram message)';
  if (!ALERT_LEVELS.includes(a.level as AlertLevel)) return `level must be one of ${ALERT_LEVELS.join('|')}`;
  if (a.url !== undefined && (typeof a.url !== 'string' || !/^https:\/\//.test(a.url) || a.url.length > 500)) return 'url must be an https URL';
  if (a.repo !== undefined && (typeof a.repo !== 'string' || !/^[\w.-]+\/[\w.-]+$/.test(a.repo))) return 'repo must be owner/name';
  if (a.at !== undefined && (typeof a.at !== 'number' || !Number.isFinite(a.at))) return 'at must be epoch ms';
  return null;
}
