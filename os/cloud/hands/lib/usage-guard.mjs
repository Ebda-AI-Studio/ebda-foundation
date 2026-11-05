// Usage guard of the hands (Ruling I-4, 4a carried requirement 1): before EVERY job the hands read the weekly Claude
// usage and refuse when it is unknown or at/over the threshold. Unknown is never treated as low.
//
// Sources, newest fresh reading wins (rules ported from os/ops/lib/usage_sentinel.py):
//   1. claude-cli: the `rate_limit_event` the Claude Code CLI emits in `--output-format stream-json` (measured on 2.1.317,
//      2026-11-06: rate_limit_info.unifiedWindows.seven_day.utilization is a FRACTION, 0.96 = 96 %; resetsAt in epoch
//      seconds). Every job's own Claude run refreshes it; before the first job a one-turn probe reads it.
//   2. manual: <USAGE_STATE>/manual.json written by `usage-sentinel.sh calibrate <n>` (Mac only), max age 1 h.
//   3. snapshot: the statusline's ~/.claude/usage-snapshot.json (Mac only), max age 15 min.
// A reading is unusable when it is missing, out of 0-100, more than 5 min in the future, too old, or pre-reset.
// The brain's own last report is NOT a source: the hands report what they read, so echoing it back would refresh a
// stale number forever.
import { readFile } from 'node:fs/promises';

export const SNAPSHOT_MAX_AGE_S = 900;
export const MANUAL_MAX_AGE_S = 3600;
export const CLI_MAX_AGE_S = 3600;

function pctOf(v) {
  if (typeof v !== 'number' || !Number.isFinite(v)) return null;
  return v >= 0 && v <= 100 ? v : null;
}

/** Validate a candidate reading; returns {reading} or {why}. Times in epoch SECONDS like the sentinel. */
export function candidate(src, pct, t, resetsAt, maxAgeS, nowS) {
  if (pct === null || pct === undefined) return { why: `${src}: weekly percentage missing or outside 0-100` };
  if (typeof t !== 'number') return { why: `${src}: no timestamp` };
  const age = nowS - t;
  if (age < -300) return { why: `${src}: timestamp ${-age}s in the future` };
  if (age > maxAgeS) return { why: `${src}: ${Math.round(age)}s old (limit ${maxAgeS}s)` };
  if (typeof resetsAt === 'number' && nowS >= resetsAt) return { why: `${src}: weekly window reset at ${resetsAt}, reading is pre-reset` };
  return { reading: { src, pct, t, resetsAt: typeof resetsAt === 'number' ? resetsAt : undefined } };
}

/** A stream-json line object from `claude -p --output-format stream-json --verbose` -> reading or null. */
export function readingFromStreamEvent(ev, nowS) {
  if (!ev || ev.type !== 'rate_limit_event' || !ev.rate_limit_info) return null;
  const info = ev.rate_limit_info;
  let util;
  let resetsAt;
  const sd = info.unifiedWindows?.seven_day;
  if (sd && typeof sd.utilization === 'number') {
    util = sd.utilization;
    resetsAt = sd.resetsAt;
  } else if (info.rateLimitType === 'seven_day' && typeof info.utilization === 'number') {
    util = info.utilization;
    resetsAt = info.resetsAt;
  } else if (info.status === 'rejected' && info.rateLimitType === 'seven_day') {
    util = 1;
    resetsAt = info.resetsAt;
  } else {
    return null; // an event about another window says nothing about the weekly number
  }
  // utilization is a fraction (measured). A value above 1 is read as a percentage (defensive, never as "low").
  const pct = util <= 1 ? Math.round(util * 1000) / 10 : util;
  const c = candidate('claude-cli', pctOf(pct), nowS, typeof resetsAt === 'number' ? resetsAt : undefined, CLI_MAX_AGE_S, nowS);
  return c.reading ?? null;
}

/** Statusline snapshot shape: {t, rl:{seven_day:{used_percentage, resets_at}}} */
export function readingFromSnapshot(raw, nowS) {
  if (!raw) return { why: 'snapshot: missing or unreadable' };
  const sd = raw?.rl?.seven_day ?? {};
  return candidate('snapshot', pctOf(sd.used_percentage), typeof raw.t === 'number' ? raw.t : undefined, sd.resets_at, SNAPSHOT_MAX_AGE_S, nowS);
}

/** usage-sentinel manual calibration shape: {pct, t, resets_at?} */
export function readingFromManual(raw, nowS) {
  if (!raw) return { why: 'manual: missing or unreadable' };
  return candidate('manual', pctOf(raw.pct), typeof raw.t === 'number' ? raw.t : undefined, raw.resets_at, MANUAL_MAX_AGE_S, nowS);
}

export function validThreshold(t) {
  return typeof t === 'number' && Number.isFinite(t) && t >= 1 && t <= 100;
}

/** The decision. No reading = refuse. A threshold that is not a finite 1..100 number = refuse (fail closed). */
export function decide(reading, thresholdPct) {
  if (!validThreshold(thresholdPct)) return { allowed: false, reason: `invalid usage threshold (${String(thresholdPct)}): refusing every job (fail closed)` };
  if (!reading) return { allowed: false, reason: 'usage-unknown: no fresh weekly-usage reading (unknown is never treated as low)' };
  if (reading.pct >= thresholdPct) return { allowed: false, reason: `weekly usage ${reading.pct}% >= threshold ${thresholdPct}% (${reading.src})`, pct: reading.pct };
  return { allowed: true, reason: `weekly usage ${reading.pct}% < threshold ${thresholdPct}% (${reading.src})`, pct: reading.pct };
}

async function readJson(path) {
  if (!path) return null;
  try {
    return JSON.parse(await readFile(path, 'utf8'));
  } catch {
    return null;
  }
}

/**
 * Holds the freshest reading for one run. `probe()` runs one tiny Claude turn to read the CLI's rate-limit event; it
 * is injected so tests never call Claude.
 */
export class UsageGuard {
  constructor({ thresholdPct, manualPath, snapshotPath, probe, nowS = () => Date.now() / 1000, log = () => {} }) {
    this.thresholdPct = thresholdPct;
    this.manualPath = manualPath;
    this.snapshotPath = snapshotPath;
    this.probe = probe;
    this.nowS = nowS;
    this.log = log;
    this.cli = null;
    this.probed = false;
  }

  /** Feed a stream-json event seen during a job. Returns true when it carried a weekly reading. */
  observe(ev) {
    const r = readingFromStreamEvent(ev, this.nowS());
    if (r) this.cli = r;
    return !!r;
  }

  async best() {
    const now = this.nowS();
    const cands = [];
    const why = [];
    if (this.cli) {
      const c = candidate('claude-cli', this.cli.pct, this.cli.t, this.cli.resetsAt, CLI_MAX_AGE_S, now);
      c.reading ? cands.push(c.reading) : why.push(c.why);
    }
    for (const c of [readingFromManual(await readJson(this.manualPath), now), readingFromSnapshot(await readJson(this.snapshotPath), now)]) {
      c.reading ? cands.push(c.reading) : why.push(c.why);
    }
    cands.sort((a, b) => b.t - a.t);
    return { reading: cands[0] ?? null, why };
  }

  /** Check before a job. Probes the CLI once per run when nothing fresh is known. */
  async check() {
    if (!validThreshold(this.thresholdPct)) return { ...decide(null, this.thresholdPct), reading: null };
    let { reading, why } = await this.best();
    if (!reading && this.probe && !this.probed) {
      this.probed = true;
      let probeWhy = 'claude-cli probe: no weekly rate_limit_event';
      try {
        if ((await this.probe()).filter((ev) => this.observe(ev)).length) probeWhy = '';
      } catch (e) {
        probeWhy = `claude-cli probe failed: ${e?.message ?? e}`;
      }
      ({ reading, why } = await this.best());
      if (probeWhy) why.push(probeWhy);
    }
    const d = decide(reading, this.thresholdPct);
    if (!reading) d.reason += ` [${why.join('; ')}]`;
    return { ...d, reading };
  }
}
