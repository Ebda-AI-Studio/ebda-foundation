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
  // cloud watcher config (all optional; unset = that watcher raises one monitor-unconfigured finding). JSON vars are lists.
  /** services: [{name,url,kind:'api'|'page'|'money'}] */
  SERVICE_TARGETS?: string;
  /** page-load: [{name,url}] and the p50 limit in ms (1500) */
  PAGE_LOAD_TARGETS?: string;
  PAGE_LOAD_P50_MS?: string;
  /** journey-monitor: [{name,steps:[{name,url,contains?}]}] (GET only, checkout/payment paths refused) */
  JOURNEY_CONFIG?: string;
  /** deploy-drift: [{name,healthUrl,repo,branch?}] and the grace in minutes (120) */
  DEPLOY_DRIFT_TARGETS?: string;
  DEPLOY_DRIFT_GRACE_MIN?: string;
  /** pr-shepherd: hours without an update before an open PR is flagged (24) */
  PR_SHEPHERD_STALE_HOURS?: string;
  /** cf-workers + cost-guard: the personal Cloudflare account id; name prefixes to watch (ebda-), expected Workers, error rate (0.05) */
  CF_ACCOUNT_ID?: string;
  CF_WORKERS_PREFIXES?: string;
  CF_WORKERS_EXPECTED?: string;
  CF_WORKER_ERROR_RATE?: string;
  /** cost-guard: Actions org and minute thresholds (48000 / 49500), Cloudflare request thresholds (8M / 10M) */
  COST_GH_ORG?: string;
  COST_ACTIONS_WARN_MIN?: string;
  COST_ACTIONS_STOP_MIN?: string;
  CF_REQUESTS_WARN?: string;
  CF_REQUESTS_STOP?: string;
  /** sentry-stale */
  SENTRY_ORG?: string;
  SENTRY_PROJECTS?: string;
  SENTRY_BASE_URL?: string;
  /** dr-drill: owner/name of the repo holding scripts/ops/restore-drill.mjs; days before a missing drill result is a finding (8) */
  DR_DRILL_REPO?: string;
  DR_DRILL_STALE_DAYS?: string;
  /** world-watch: [{name,url}] status pages (default Cloudflare + GitHub) and {"npm-package":["version"]} */
  WORLD_STATUS_URLS?: string;
  WORLD_NPM_DEPS?: string;
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
  /** cf-workers + cost-guard: Account Analytics:Read + Workers Scripts:Read */
  CF_API_TOKEN?: string;
  /** sentry-stale: project:read */
  SENTRY_AUTH_TOKEN?: string;
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
