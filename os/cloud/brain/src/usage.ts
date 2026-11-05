// Usage guard: the brain refuses to start hands work once the weekly Claude usage the hands last reported is at or
// above USAGE_WEEKLY_THRESHOLD_PCT. The value comes from the hands (POST /hands/usage) because only they can read it.
//
// Rules: no report yet, or a report older than 7 days -> allowed, flagged 'usage-unknown' (the hands enforce the same
// threshold between jobs in 4b, so unknown is never unguarded). A report past its resetsAt -> allowed (new week).
import type { UsageReport } from './hands';

export const WEEK_MS = 7 * 24 * 3600 * 1000;

export interface UsageDecision {
  allowed: boolean;
  reason: string;
}

export function usageGuard(report: UsageReport | null, thresholdPct: number, now: number): UsageDecision {
  if (!report) return { allowed: true, reason: 'usage-unknown: no report from the hands yet' };
  if (now - report.reportedAt > WEEK_MS) return { allowed: true, reason: 'usage-unknown: last report older than 7 days' };
  if (typeof report.resetsAt === 'number' && now >= report.resetsAt) return { allowed: true, reason: 'weekly window has reset' };
  if (report.weeklyUsedPct >= thresholdPct) {
    return { allowed: false, reason: `weekly usage ${report.weeklyUsedPct}% >= threshold ${thresholdPct}%` };
  }
  return { allowed: true, reason: `weekly usage ${report.weeklyUsedPct}% < threshold ${thresholdPct}%` };
}

export function validateUsage(x: unknown): string | null {
  if (!x || typeof x !== 'object') return 'usage must be an object';
  const u = x as Record<string, unknown>;
  if (typeof u.weeklyUsedPct !== 'number' || u.weeklyUsedPct < 0 || u.weeklyUsedPct > 1000) return 'weeklyUsedPct must be a number';
  if (u.resetsAt !== undefined && typeof u.resetsAt !== 'number') return 'resetsAt must be epoch ms';
  return null;
}
