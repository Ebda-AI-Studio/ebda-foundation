// Bindings, vars and secrets of the brain Worker. Vars come from wrangler.jsonc (rendered by scripts/deploy.sh);
// secrets are set with `wrangler secret put` and never appear in the repo.
import type { BrainDO } from './brain-do';

export interface Env {
  BRAIN: DurableObjectNamespace<BrainDO>;
  EVENTS: KVNamespace;
  ASSETS?: Fetcher;
  // vars
  OS_ORGS: string;
  HEALTH_TARGETS: string;
  HEALTH_FAIL_BUDGET: string;
  MESSAGE_BUDGET_PER_DAY: string;
  URGENT_RUNS_PER_DAY: string;
  URGENT_RUN_CAP_MIN: string;
  QUESTION_DEADLINE_HOURS: string;
  USAGE_WEEKLY_THRESHOLD_PCT: string;
  HANDS_PROVIDER: string;
  ACCESS_TEAM_DOMAIN: string;
  ACCESS_AUD: string;
  // secrets
  GH_WEBHOOK_SECRET?: string;
  RELAY_SECRET?: string;
  GITHUB_TOKEN?: string;
  TELEGRAM_BOT_TOKEN?: string;
  TELEGRAM_CHAT_ID?: string;
  TELEGRAM_WEBHOOK_SECRET?: string;
  HANDS_TOKEN?: string;
  INGEST_TOKEN?: string;
}

/** Integer var with a fallback; a malformed value never becomes NaN or 0 silently. */
export function intVar(v: string | undefined, fallback: number): number {
  const n = Number.parseInt(String(v ?? ''), 10);
  return Number.isFinite(n) && n >= 0 ? n : fallback;
}

/** True when a var still carries the template placeholder (deploy.sh did not render it). */
export function isPlaceholder(v: string | undefined): boolean {
  return !v || /^__[A-Z0-9_]+__$/.test(v);
}

export interface Policy {
  messageBudgetPerDay: number;
  urgentRunsPerDay: number;
  urgentRunCapMin: number;
  questionDeadlineHours: number;
  usageThresholdPct: number;
  healthFailBudget: number;
}

export function policyFrom(env: Partial<Env>): Policy {
  return {
    messageBudgetPerDay: intVar(env.MESSAGE_BUDGET_PER_DAY, 3),
    urgentRunsPerDay: intVar(env.URGENT_RUNS_PER_DAY, 3),
    urgentRunCapMin: intVar(env.URGENT_RUN_CAP_MIN, 30),
    questionDeadlineHours: intVar(env.QUESTION_DEADLINE_HOURS, 24),
    usageThresholdPct: intVar(env.USAGE_WEEKLY_THRESHOLD_PCT, 80),
    healthFailBudget: intVar(env.HEALTH_FAIL_BUDGET, 3),
  };
}
