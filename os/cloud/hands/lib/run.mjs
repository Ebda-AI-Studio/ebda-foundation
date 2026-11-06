// The run loop: sequential, one job at a time, usage guard before each job, a run-level wall-clock cap, every outcome
// reported to the brain, then exit. Pure orchestration; run-batch.mjs wires the real or dry-run leaves.
import { runJob } from './job.mjs';
import { validThreshold } from './usage-guard.mjs';

export async function runBatch(batch, { brain, cfg, exec, usage, log = () => {}, now = () => Date.now(), runCapMin, keepWorkdir = false, env, creds }) {
  const results = [];
  const capMin = runCapMin ?? (batch.kind === 'urgent' ? batch.perJobCapMin : cfg.runCapMin);
  const runDeadline = now() + capMin * 60_000;
  // the stricter of the two thresholds; a malformed value on either side makes the guard refuse (fail closed, I-1)
  if (batch.usageThresholdPct !== undefined) {
    const b = batch.usageThresholdPct;
    usage.thresholdPct = validThreshold(b) && validThreshold(usage.thresholdPct) ? Math.min(usage.thresholdPct, b) : Number.NaN;
  }
  const jobs = batch.jobs ?? [];
  for (let i = 0; i < jobs.length; i++) {
    const job = jobs[i];
    // run cap: whatever is left goes back to the queue (skipped_usage = "not attempted, requeue"), never a failure
    if (now() >= runDeadline) {
      for (const j of jobs.slice(i)) results.push(await report(brain, j, { status: 'skipped_usage', note: `run cap ${capMin} min reached before this job; back to the queue` }, log));
      break;
    }
    const g = await usage.check();
    if (!g.allowed) {
      log(`usage guard refused: ${g.reason}`);
      for (const j of jobs.slice(i)) results.push(await report(brain, j, { status: 'skipped_usage', note: g.reason }, log));
      break;
    }
    log(`job ${job.id} (${job.finding?.kind} ${job.finding?.repo ?? ''}): start, ${g.reason}`);
    let o;
    try {
      o = await runJob(job, { cfg, exec, usage, log, now, runDeadline, capMin: batch.perJobCapMin, keepWorkdir, env, creds });
    } catch (e) {
      o = { status: 'could_not_fix', note: `hands error: ${String(e?.message ?? e).slice(0, 300)}` };
    }
    results.push(await report(brain, job, o, log));
    // report the weekly usage the job's own Claude run showed (only a primary reading, never an echo)
    const u = usage.cli;
    if (u) await brain.usage({ weeklyUsedPct: u.pct, ...(u.resetsAt ? { resetsAt: u.resetsAt * 1000 } : {}) }).catch((e) => log(`usage report failed: ${e.message}`));
  }
  return results;
}

/**
 * A restore-drill job proves nothing by finishing: only the drill's own PASS (and no FAIL) in the outcome note marks it
 * fresh in the brain. Other jobs are returned unchanged. No note, or FAIL anywhere, means no 'pass' marker.
 */
export function withDrillMarker(job, o) {
  if (job.finding?.kind !== 'dr-drill') return o;
  const note = o.note ?? '';
  const ok = ['merged', 'pr_opened', 'fix_deployed'].includes(o.status) && /\bPASS\b/.test(note) && !/\bFAIL/.test(note);
  return { ...o, drill: ok ? 'pass' : 'fail' };
}

async function report(brain, job, o, log) {
  o = withDrillMarker(job, o);
  log(`job ${job.id}: ${o.status}${o.prUrl ? ` ${o.prUrl}` : ''}${o.note ? ` (${o.note})` : ''}`);
  try {
    await brain.outcome(job.id, o);
  } catch (e) {
    log(`job ${job.id}: outcome report FAILED: ${e.message}`);
  }
  return { jobId: job.id, ...o };
}
