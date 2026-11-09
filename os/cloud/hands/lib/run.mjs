// The run loop: sequential, one job at a time, usage guard before each job, a run-level wall-clock cap, every outcome
// reported to the brain, then exit. Pure orchestration; run-batch.mjs wires the real or dry-run leaves.
import { runJob } from './job.mjs';
import { validThreshold } from './usage-guard.mjs';

export async function runBatch(batch, { brain, cfg, exec, usage, log = () => {}, now = () => Date.now(), runCapMin, keepWorkdir = false, env, creds, meter }) {
  const results = [];
  const capMin = runCapMin ?? (batch.kind === 'urgent' ? batch.perJobCapMin : cfg.runCapMin);
  const runDeadline = now() + capMin * 60_000;
  // the stricter of the two thresholds; a malformed value on either side makes the guard refuse (fail closed, I-1)
  if (batch.usageThresholdPct !== undefined) {
    const b = batch.usageThresholdPct;
    usage.thresholdPct = validThreshold(b) && validThreshold(usage.thresholdPct) ? Math.min(usage.thresholdPct, b) : Number.NaN;
  }
  const jobs = batch.jobs ?? [];
  let spent = 0;
  for (let i = 0; i < jobs.length; i++) {
    const job = jobs[i];
    // run cap: whatever is left goes back to the queue (skipped_usage = "not attempted, requeue"), never a failure
    if (now() >= runDeadline) {
      for (const j of jobs.slice(i)) results.push(await report(brain, j, { status: 'skipped_usage', note: `run cap ${capMin} min reached before this job; back to the queue` }, log));
      break;
    }
    // RR-hands-api-auth: past the dollar budget the brain handed out with this batch, the rest goes back to the queue (not a failure)
    if (typeof batch.budgetUsd === 'number' && spent >= batch.budgetUsd) {
      for (const j of jobs.slice(i)) results.push(await report(brain, j, { status: 'skipped_usage', note: `run budget $${batch.budgetUsd.toFixed(2)} spent ($${spent.toFixed(2)}); back to the queue` }, log));
      break;
    }
    const g = await usage.check();
    if (!g.allowed) {
      log(`usage guard refused: ${g.reason}`);
      // C-1: the reading that caused the refusal is the most important one; the brain must learn it
      if (g.reading) await brain.usage({ weeklyUsedPct: g.reading.pct, ...(g.reading.resetsAt ? { resetsAt: g.reading.resetsAt * 1000 } : {}) }).catch((e) => log(`usage report failed: ${e.message}`));
      for (const j of jobs.slice(i)) results.push(await report(brain, j, { status: 'skipped_usage', note: g.reason }, log));
      break;
    }
    log(`job ${job.id} (${job.finding?.kind} ${job.finding?.repo ?? ''}): start, ${g.reason}`);
    let o;
    try {
      // I2: a hard dollar cap for THIS job at the forwarder: the per-job config cap, and never more than what the run has left
      const jobBudgetUsd = typeof batch.budgetUsd === 'number' ? Math.max(0.01, Math.min(cfg.jobBudgetUsd ?? 5, batch.budgetUsd - spent)) : cfg.jobBudgetUsd;
      o = await runJob(job, { cfg, exec, usage, log, now, runDeadline, capMin: batch.perJobCapMin, keepWorkdir, env, creds, meter, jobBudgetUsd });
    } catch (e) {
      o = { status: 'could_not_fix', note: `hands error: ${String(e?.message ?? e).slice(0, 300)}` };
    }
    spent += o.usage?.costUsd ?? 0;
    results.push(await report(brain, job, o, log));
    // report the weekly usage the job's own Claude run showed (only a primary reading, never an echo)
    const u = usage.cli;
    if (u) await brain.usage({ weeklyUsedPct: u.pct, ...(u.resetsAt ? { resetsAt: u.resetsAt * 1000 } : {}) }).catch((e) => log(`usage report failed: ${e.message}`));
  }
  return results;
}

async function report(brain, job, o, log) {
  log(`job ${job.id}: ${o.status}${o.prUrl ? ` ${o.prUrl}` : ''}${o.note ? ` (${o.note})` : ''}`);
  try {
    await brain.outcome(job.id, o);
  } catch (e) {
    log(`job ${job.id}: outcome report FAILED: ${e.message}`);
  }
  return { jobId: job.id, ...o };
}
