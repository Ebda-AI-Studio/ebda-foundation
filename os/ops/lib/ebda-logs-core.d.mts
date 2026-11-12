// Types for the parts of ebda-logs-core.mjs the brain Worker imports (os/cloud/brain/src/prod-watch.ts). The module itself is plain
// ESM shared with the GitHub-hosted prod-watch run, so the same alert rules run in both places.
export interface ProbeFx { ageHours: number | null; maxHours: number; noDataUntil?: string }
export interface ProbeResult { name: string; url: string; ok: boolean; status: number; ms: number; error?: string; fx?: ProbeFx }
export interface Alert { key: string; severity: 'P1' | 'P2' | 'P3'; title: string; detail?: string }
export interface WatchState { streaks?: Record<string, number>; sent?: Record<string, { first: number; last: number; n: number }>; day?: { date?: string; count?: number }; open?: string[]; digest?: Array<{ key: string; title: string; at: number }> }
export const LOG_ALERT_PREFIXES: string[];
export function evaluateProbeAlerts(probes: ProbeResult[], state: WatchState, failBudget?: number, nowMs?: number): { alerts: Alert[]; streaks: Record<string, number>; unknownKeys: string[] };
export function decide(alerts: Alert[], state: WatchState, nowMs: number, opts?: { repeatMs?: number; dailyBudget?: number; unknownPrefixes?: string[]; unknownKeys?: string[]; keyRepeatMs?: Record<string, number> }): { messages: string[]; state: WatchState };
export function brainListing(alerts: Alert[], opts: { logsRead: boolean }): { findings: Array<{ source: string; kind: string; key: string; title: string; severity?: 'P1' | 'P2' | 'P3'; detail?: Record<string, unknown> }>; reconcile: { source: string; keep?: string[] } };
export function messageScope(alerts: Alert[], opts: { brainUp: boolean; logsRead: boolean }): { alerts: Alert[]; unknownPrefixes: string[] };
export function fxStaleAlert(p: ProbeResult, nowMs: number): Alert | null;
export const KEY_REPEAT_MS: Record<string, number>;
