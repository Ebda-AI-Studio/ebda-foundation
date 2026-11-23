// Bindings, vars and secrets of the brain Worker. Vars come from wrangler.jsonc (rendered by scripts/deploy.sh);
// secrets are set with `wrangler secret put` and never appear in the repo.
import type { BrainDO } from './brain-do';

export interface Env {
  BRAIN: DurableObjectNamespace<BrainDO>;
  EVENTS: KVNamespace;
  ASSETS?: Fetcher;
  // vars
  /** the git commit this build was deployed from (stamped by scripts/deploy.sh); /health returns it when it is a sha */
  GIT_COMMIT?: string;
  OS_ORGS: string;
  /** owner/name list of repos whose code is deployed; an advisory is urgent only there */
  DEPLOYED_REPOS?: string;
  /** [{url,kind,repo?}] (fast 5-min check). A URL belongs here OR in SERVICE_TARGETS, never both. repo = owner/name lets an outage reach the hands */
  HEALTH_TARGETS: string;
  // cloud watcher config (all optional; unset = that watcher raises one monitor-unconfigured finding). JSON vars are lists.
  /** services: [{name,url,kind:'api'|'page'|'money',repo?}] (not also in HEALTH_TARGETS) */
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
  /** loop-stall: minutes main CI stays red (30) / minutes without a merge while approved PRs wait (60) before the one escalation */
  LOOP_RED_MIN?: string;
  LOOP_STALL_MIN?: string;
  /** ci-pool: minutes a CI run may stay queued while nothing runs before the one `ci-pool-stall` escalation (60) */
  CI_QUEUE_MIN?: string;
  /** ci-pool: queued runs older than this many minutes (360) are ghosts no runner takes; they are ignored */
  CI_QUEUE_MAX_MIN?: string;
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
  /** ruling AIOS-7: '1' = the primary prod-watch probes run on the brain tick every 10 min ('0' = only the GitHub run) */
  PROD_WATCH_ON_BRAIN?: string;
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
  /** model routing: the default model alias (never opus), and how many explicitly flagged opus jobs a day */
  HANDS_DEFAULT_MODEL?: string;
  HANDS_OPUS_JOBS_PER_DAY?: string;
  /** dollar budgets: monthly (default 150, must stay under the $200 credit) and daily (default 10) */
  HANDS_MONTHLY_BUDGET_USD?: string;
  HANDS_DAILY_BUDGET_USD?: string;
  /** a Claude run nothing metered is charged this much per job (default 2), never $0; the per-job hard budget the forwarder enforces (default 5) */
  HANDS_JOB_PESSIMISTIC_USD?: string;
  HANDS_JOB_BUDGET_USD?: string;
  /** F-01: '1' halts every container start (second line of defence; the DO `halt` key is the first) */
  HANDS_HALT?: string;
  /** F-06: 'max' (default, Claude Max OAuth) or 'api' (a Console API key with a hard spend limit; REQUIRES HANDS_API_SPEND_LIMIT_USD) */
  HANDS_CLAUDE_AUTH?: string;
  /** F-06: the Console spend limit (USD) Ahmad set for the API key; api mode refuses to start without it */
  HANDS_API_SPEND_LIMIT_USD?: string;
  /** F-07: Mac claims per day (default 5 jobs) */
  HANDS_MAC_JOBS_PER_DAY?: string;
  /** F-14: findings accepted from /findings per day (default 1000) */
  INGEST_PER_DAY?: string;
  /** F-05 thresholds (per day) for the footprint watcher */
  CF_CONTAINER_VCPU_MIN_DAY?: string;
  CF_DO_REQUESTS_DAY?: string;
  CF_KV_WRITES_DAY?: string;
  /** the estimated-monthly-USD thresholds of the footprint watcher; default to Ahmad's Cloudflare alerts ($10 warn, $20 stop) */
  CF_WARN_USD?: string;
  CF_STOP_USD?: string;
  /** F-12: GitHub App (preferred over the PAT): app id, PKCS#8 key, {"owner": installationId} */
  GH_APP_ID?: string;
  GH_APP_PRIVATE_KEY?: string;
  GH_APP_INSTALLATIONS?: string;
  /** github-actions provider: disabled unless 'true' AND repo/workflow/token are set (Actions minutes are CI only) */
  HANDS_GITHUB_ACTIONS_ENABLED?: string;
  HANDS_GITHUB_ACTIONS_REPO?: string;
  HANDS_GITHUB_ACTIONS_WORKFLOW?: string;
  ACCESS_TEAM_DOMAIN: string;
  ACCESS_AUD: string;
  /** RR-dash-auth: interim Basic Auth for /dash/* and /api/* while Access is not configured. 'off' disables it (Access, or 503). */
  DASH_BASIC_AUTH?: string;
  /** the Basic Auth user (default `ahmad`) */
  DASH_BASIC_USER?: string;
  /** failures in 15 minutes before an IP (default 10) or everyone (default 200) is locked out */
  DASH_AUTH_FAILS_PER_IP?: string;
  DASH_AUTH_FAILS_GLOBAL?: string;
  // secrets
  /** RR-dash-auth: the dashboard Basic Auth password (Keychain `ebda-os-brain-dash-password`); unset = Basic Auth off */
  DASH_BASIC_PASSWORD?: string;
  GH_WEBHOOK_SECRET?: string;
  RELAY_SECRET?: string;
  GITHUB_TOKEN?: string;
  /** cf-workers + cost-guard: Account Analytics:Read + Workers Scripts:Read */
  CF_API_TOKEN?: string;
  /** sentry-stale: project:read */
  SENTRY_AUTH_TOKEN?: string;
  TELEGRAM_BOT_TOKEN?: string;
  TELEGRAM_CHAT_ID?: string;
  /** user id allowed to press the question buttons; defaults to TELEGRAM_CHAT_ID (a private chat's id is the owner's user id) */
  TELEGRAM_OWNER_ID?: string;
  /** secret_token the brain registers with Telegram as its webhook secret_token; Telegram echoes it as X-Telegram-Bot-Api-Secret-Token on every POST /telegram/webhook */
  TELEGRAM_WEBHOOK_SECRET?: string;
  /** '0' turns off the short "Got it" reply to an inbox message (default on) */
  TELEGRAM_INBOX_ACK?: string;
  /** F-06b: the HMAC KEY for per-run container tokens (never itself a bearer) */
  HANDS_TOKEN?: string;
  /** F-06b: the Mac's own bearer; it can only claim as mac-local and report on its own runs */
  HANDS_MAC_TOKEN?: string;
  /** F-06: the hands' Console API key (api mode). Named HANDS_* because ONLY the HandsContainer DO reads it, to pass it to the container as
   *  ANTHROPIC_API_KEY; no brain code path, watcher or the Mac ever sees it. */
  HANDS_ANTHROPIC_API_KEY?: string;
  INGEST_TOKEN?: string;
  /** InstaPay bridge (src/instapay-bridge.ts): per-product HMAC secrets (>= 16 chars) and the https revert endpoints the "not received" tap calls */
  INSTAPAY_BRIDGE_SECRET_STORE?: string;
  INSTAPAY_BRIDGE_SECRET_CHAT?: string;
  INSTAPAY_REVERT_URL_STORE?: string;
  INSTAPAY_REVERT_URL_CHAT?: string;
  /** passed into the hands container at start, never baked into the image */
  CLAUDE_CODE_OAUTH_TOKEN?: string;
  HANDS_GH_TOKEN?: string;
  HANDS_CONFIG_JSON?: string;
  HANDS_GIT_NAME?: string;
  HANDS_GIT_EMAIL?: string;
  HANDS_GITHUB_ACTIONS_TOKEN?: string;
  // ---- social posting (src/social/*, docs/plans/2026-11-11-social-posting.md): Facebook Pages + LinkedIn company pages only ----
  /** secret JSON {"whisky11":{"pageId","pageToken"},"ebda":{...}}: never-expiring Page tokens. Unset = Facebook disabled */
  SOCIAL_FACEBOOK?: string;
  /** secret JSON {"whisky11":{"orgUrn","token","expiresAt"},...}: needs an approved Community Management API app. Unset = LinkedIn disabled */
  SOCIAL_LINKEDIN?: string;
  /** secret: HMAC key of the signed approve / edit / skip links in the Telegram preview (unset = callback buttons only) */
  SOCIAL_LINK_SECRET?: string;
  /** secret: bearer for POST /social/decide and /social/brands (the controller forwarding Ahmad's Telegram text). NOT INGEST_TOKEN:
   *  the Mac content job that writes drafts must never be able to approve them */
  SOCIAL_DECIDE_TOKEN?: string;
  SOCIAL_APPROVAL_DAYS?: string;
  SOCIAL_APPROVAL_LEAD_HOURS?: string;
  SOCIAL_FB_SPACING_MIN?: string;
  SOCIAL_FB_MAX_DEFER_HOURS?: string;
  SOCIAL_GRAPH_VERSION?: string;
  SOCIAL_LINKEDIN_VERSION?: string;
}

/** Positive number var with a fallback. */
export function numberVar(v: string | undefined, fallback: number): number {
  const n = Number(v);
  return Number.isFinite(n) && n > 0 ? n : fallback;
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
