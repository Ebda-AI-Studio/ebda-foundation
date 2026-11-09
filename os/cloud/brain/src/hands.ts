// The brain decides; the hands (Task 4b: os/cloud/hands/) write the fixes. This file is the contract between them.
//
// Flow: the brain builds a HandsBatch (urgent: exactly one job, 30-minute cap; nightly: the whole day's queue) and calls
// HandsProvider.start(batch). The provider starts ONE run (a Cloudflare Container/Sandbox by default, the Mac when awake)
// that pulls the batch from GET /hands/runs/:runId (Bearer HANDS_TOKEN), works each job in its own worktree, and posts
// back POST /hands/jobs/:jobId/outcome and POST /hands/usage. Nothing else in the brain starts a run.
import { selectProvider } from '../../hands/providers/index.mjs';
import type { Env } from './env';
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
  /** model alias the hands pass to `claude --model` (routing, final decision): haiku | sonnet | opus */
  model?: 'haiku' | 'sonnet' | 'opus';
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
  /** dollars the run may still spend today / this month (the smaller one); the hands stop between jobs past it */
  budgetUsd?: number;
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
  /** pull-only providers (mac-local) are never started by the brain: the Mac claims queued work itself */
  readonly pullOnly?: boolean;
  /** a throw is recorded as a failed run (the jobs stay queued); it never aborts the brain tick */
  start(batch: HandsBatch): Promise<RunRef>;
  /** F-04 / F-01: stop the lane's container now; halt:true also refuses later starts until resume(). Never throws. */
  stop?(kind: RunKind, opts?: { halt?: boolean }): Promise<{ ok: boolean; note?: string }>;
  resume?(kind: RunKind): Promise<{ ok: boolean }>;
}

/** Outcome a hands run writes back per job. */
export interface JobOutcome {
  status: 'merged' | 'pr_opened' | 'fix_deployed' | 'could_not_fix' | 'skipped_usage' | 'timed_out';
  prUrl?: string;
  note?: string;
  /** what the job cost, computed by the hands from the API response usage x the price table */
  usage?: JobUsage;
  /** the hands ran Claude for this job (even if nothing else is known): a run with no spend reading is then charged the pessimistic amount, never $0 */
  claudeRan?: boolean;
  /** the usage above came from the forwarder meter (every API response), not the result-event fallback */
  metered?: boolean;
}

export interface JobUsage {
  model: string;
  inputTokens: number;
  outputTokens: number;
  cacheReadTokens: number;
  cacheWriteTokens: number;
  costUsd: number;
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

/**
 * Provider by config (HANDS_PROVIDER). The real providers live in os/cloud/hands/providers/ (Worker-compatible ESM):
 * cloudflare-sandbox (default from Task 7), mac-local (pull-only), github-actions (selectable only when explicitly
 * enabled and configured). Unknown or not-configured names fall back to the stub (records only), so a typo in
 * HANDS_PROVIDER can never start an unexpected runner.
 */
export function providerFor(name: string, env: Partial<Env> = {}): HandsProvider {
  const { provider } = selectProvider(name, env as Record<string, unknown>);
  return (provider as HandsProvider | null) ?? new StubHandsProvider();
}
