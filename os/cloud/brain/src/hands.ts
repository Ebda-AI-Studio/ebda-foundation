// The brain decides; the hands (Task 4b: os/cloud/hands/) write the fixes. This file is the contract between them.
//
// Flow: the brain builds a HandsBatch (urgent: exactly one job, 30-minute cap; nightly: the whole day's queue) and calls
// HandsProvider.start(batch). The provider starts ONE run (a Cloudflare Container/Sandbox by default, the Mac when awake)
// that pulls the batch from GET /hands/runs/:runId (Bearer HANDS_TOKEN), works each job in its own worktree, and posts
// back POST /hands/jobs/:jobId/outcome and POST /hands/usage. Nothing else in the brain starts a run.
import type { Finding, MergePolicy } from './findings';

export type RunKind = 'urgent' | 'nightly';

export interface HandsJob {
  id: string;
  fingerprint: string;
  lane: 'urgent' | 'nightly';
  mergePolicy: MergePolicy;
  finding: Finding;
  /** set when the job came out of an answered question */
  answer?: string;
}

export interface HandsBatch {
  runId: string;
  kind: RunKind;
  jobs: HandsJob[];
  /** per-job wall-clock cap in minutes (urgent: URGENT_RUN_CAP_MIN) */
  perJobCapMin: number;
  /** the usage threshold the hands must also enforce between jobs */
  usageThresholdPct: number;
  createdAt: number;
}

export interface RunRef {
  runId: string;
  provider: string;
  /** provider-side handle (container id, sandbox id, mac session) when known */
  externalId?: string;
  startedAt: number;
}

export interface HandsProvider {
  readonly name: string;
  start(batch: HandsBatch): Promise<RunRef>;
}

/** Outcome a hands run writes back per job. */
export interface JobOutcome {
  status: 'merged' | 'pr_opened' | 'fix_deployed' | 'could_not_fix' | 'skipped_usage' | 'timed_out';
  prUrl?: string;
  note?: string;
}

export const OUTCOME_STATUSES: ReadonlyArray<JobOutcome['status']> = ['merged', 'pr_opened', 'fix_deployed', 'could_not_fix', 'skipped_usage', 'timed_out'];

/** Usage report the hands send back after every job (Claude weekly usage, percent of the plan). */
export interface UsageReport {
  weeklyUsedPct: number;
  /** epoch ms when the weekly window resets, if the hands know it */
  resetsAt?: number;
  reportedAt: number;
}

/**
 * Stub provider (4a): records the batch and returns a RunRef; starts nothing. The brain persists every RunRef in its
 * `runs` table, so "recording" is the whole job. 4b replaces it with cloudflare-sandbox / mac-local providers.
 */
export class StubHandsProvider implements HandsProvider {
  readonly name = 'stub';
  readonly started: HandsBatch[] = [];
  async start(batch: HandsBatch): Promise<RunRef> {
    this.started.push(batch);
    return { runId: batch.runId, provider: this.name, startedAt: batch.createdAt };
  }
}

export function providerFor(name: string): HandsProvider {
  // 4b registers 'cloudflare-sandbox' and 'mac-local' here. Unknown names fall back to the stub (records only),
  // so a typo in HANDS_PROVIDER can never start an unexpected runner.
  switch (name) {
    default:
      return new StubHandsProvider();
  }
}
