// Bindings, vars and secrets of the brain Worker. Vars come from wrangler.jsonc (rendered by scripts/deploy.sh);
// secrets are set with `wrangler secret put` and never appear in the repo.
import type { BrainDO } from './brain-do';

export interface Env {
  BRAIN: DurableObjectNamespace<BrainDO>;
  EVENTS: KVNamespace;
  ASSETS?: Fetcher;
  // vars
  OS_ORGS: string;
  /** owner/name list of repos whose code is deployed; an advisory is urgent only there */
  DEPLOYED_REPOS?: string;
  HEALTH_TARGETS: string;
  HEALTH_FAIL_BUDGET: string;
  MESSAGE_BUDGET_PER_DAY: string;
  URGENT_MESSAGE_BUDGET_PER_DAY?: string;
  URGENT_RUNS_PER_DAY: string;
  URGENT_RUN_CAP_MIN: string;
  QUESTION_DEADLINE_HOURS: string;
  USAGE_WEEKLY_THRESHOLD_PCT: string;
  /** optional: consecutive fully-skipped nightly batches before the brain alerts (default 3) */
  USAGE_STARVED_ALERT_AFTER?: string;
  HANDS_PROVIDER: string;
  /** cloudflare-sandbox: the brain's public URL the container calls back (rendered from OS_BRAIN_HOST) */
  HANDS_BRAIN_URL?: string;
  /** cloudflare-sandbox: wall-clock cap of a nightly container run (urgent runs use URGENT_RUN_CAP_MIN) */
  HANDS_NIGHTLY_RUN_CAP_MIN?: string;
  /** cloudflare-sandbox: the HandsContainer Durable Object (Container-enabled). Absent until Task 7 configures it. */
  HANDS_CONTAINER?: DurableObjectNamespace;
  /** github-actions provider: disabled unless 'true' AND repo/workflow/token are set (Actions minutes are CI only) */
  HANDS_GITHUB_ACTIONS_ENABLED?: string;
  HANDS_GITHUB_ACTIONS_REPO?: string;
  HANDS_GITHUB_ACTIONS_WORKFLOW?: string;
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
  /** passed into the hands container at start, never baked into the image */
  CLAUDE_CODE_OAUTH_TOKEN?: string;
  HANDS_GH_TOKEN?: string;
  HANDS_CONFIG_JSON?: string;
  HANDS_GIT_NAME?: string;
  HANDS_GIT_EMAIL?: string;
  HANDS_GITHUB_ACTIONS_TOKEN?: string;
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
  urgentMessageBudgetPerDay: number;
  urgentRunsPerDay: number;
  urgentRunCapMin: number;
  questionDeadlineHours: number;
  usageThresholdPct: number;
  healthFailBudget: number;
  /** ruling 4b-6: alert after this many consecutive nightly batches in which every job was skipped by the usage guard */
  usageStarvedAlertAfter: number;
}

export function policyFrom(env: Partial<Env>): Policy {
  return {
    messageBudgetPerDay: intVar(env.MESSAGE_BUDGET_PER_DAY, 3),
    urgentMessageBudgetPerDay: intVar(env.URGENT_MESSAGE_BUDGET_PER_DAY, 3),
    urgentRunsPerDay: intVar(env.URGENT_RUNS_PER_DAY, 3),
    urgentRunCapMin: intVar(env.URGENT_RUN_CAP_MIN, 30),
    questionDeadlineHours: intVar(env.QUESTION_DEADLINE_HOURS, 24),
    usageThresholdPct: intVar(env.USAGE_WEEKLY_THRESHOLD_PCT, 80),
    healthFailBudget: intVar(env.HEALTH_FAIL_BUDGET, 3),
    usageStarvedAlertAfter: intVar(env.USAGE_STARVED_ALERT_AFTER, 3),
  };
}
