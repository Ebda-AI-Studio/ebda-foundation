// Finding -> lane. Pure, unit-tested (test/classify.test.ts), and the only place the urgency rules live.
//
// URGENT (Amendment A.1, strict): an immediate hands run, at most URGENT_RUNS_PER_DAY a day and one at a time:
//   (1) a production outage or broken money path (checkout, payment webhook, payout) the self-heal recipes did not fix
//       within their retry budget;
//   (2) a security issue in deployed code or a deployed dependency that is critical (CVSS >= 9.0) or CISA-KEV listed;
//   (3) a data exposure (PII or secret leak) detected by a watcher.
// QUESTION: anything destructive or irreversible (deletes, prod data writes, purchases, secrets, billing) and anything
//   touching money, auth, data deletion, deploy config or prod data waits for Ahmad's answer before any work starts.
// DIGEST: monitor self-reports (monitor-unconfigured, watcher-error): recorded + listed once in the digest, no job, no question.
// NIGHTLY: everything else, in the one batched run at the end of the day. Only the pre-approved classes (dependency /
//   CVE bumps, docs, tests, lint, flaky-test fixes) may auto-merge, and only when the repo's merge gate is green;
//   every other change becomes a PR plus one question.
import type { Classification, Finding } from './findings';

export const URGENT_CVSS = 9.0;

/** Config / access self-reports of any source (watchers, dream-scan, heal-watch): ops problems, digest only. */
const DIGEST_KINDS = new Set(['monitor-stale', 'monitor-unconfigured', 'watcher-error', 'alert-drill', 'scan-target-missing', 'dream-scan-failed', 'dr-drill-stale', 'pr-needs-you', 'usage-starved', 'budget-warn', 'cf-usage-warn', 'cost-warn', 'footprint-unknown', 'drain-held']);
/** Ruling F-I6: a restore drill with no PASS for 14+ days is a P1 decision for Ahmad (run it on the Mac), never a hands job. */
const ALERT_KINDS = new Set(['monitor-silent', 'drain-stall', 'loop-main-red', 'loop-merge-stall', 'ci-pool-stall', 'dr-drill-overdue', 'cost-stop', 'cf-usage-stop', 'budget-stop', 'isp-block-range']);
/** F-01: a finding of one of these kinds halts the hands (one flag, checked before every container start). */
export const HALT_KINDS: ReadonlySet<string> = new Set(['cost-stop', 'cf-usage-stop', 'budget-stop']);
const OUTAGE_KINDS = new Set(['prod-outage', 'money-path-broken']);
const EXPOSURE_KINDS = new Set(['data-exposure', 'pii-leak', 'secret-leak']);
const ADVISORY_KINDS = new Set(['dependency-advisory', 'code-advisory']);
/** Pre-approved classes: the only ones that may auto-merge (gate green). */
export const PRE_APPROVED_KINDS = new Set(['dep-bump', 'dependency-advisory', 'cve-bump', 'lockfile-drift', 'docs', 'test', 'tests', 'flaky-test']);
// M-1: lint / lint-autofix / format are not pre-approved (see os/cloud/hands/lib/policy.mjs)

// Substring matching on purpose (fail-safe, as in ops/remediation/classify.sh): compound labels such as
// `security-rls` or `payout-migration` must not slip into an autonomous lane. Over-inclusion costs one question.
const DESTRUCTIVE = /delet|drop-table|truncat|purge|wipe|prod-data|data-write|purchase|buy|secret|credential|billing|payment-method/;
const SENSITIVE = /money|payment|payout|checkout|refund|auth|session|rls|polic|migration|env|deploy-config|dns|domain/;

function matches(re: RegExp, f: Finding): boolean {
  return re.test(f.kind.toLowerCase()) || (f.touches ?? []).some((t) => re.test(t.toLowerCase()));
}

export function classifyFinding(f: Finding): Classification {
  const kind = f.kind.toLowerCase();

  // Self-reports of a monitor (no config, or a source it cannot read; any source: cloud watchers, dream, heal-watch) are ops
  // problems a hands container cannot fix (it cannot set a token or a var). They are recorded and deduped, listed once in the
  // daily digest, and never become a hands job or a Telegram question (rulings R-4a-1, R-4a-2).
  if (DIGEST_KINDS.has(kind)) {
    return { lane: 'digest', reason: 'monitor self-report (config or source access): digest only, no hands job, no question', mergePolicy: 'pr-and-question' };
  }

  // An external monitor that already messaged Ahmad itself (prod-watch, ruling OBS-2) and named no repo: the brain records it as
  // production state (open until the monitor's listing drops it) but has nothing to hand the hands and must not ask twice.
  if (f.source === 'prod-watch' && !f.repo) {
    return { lane: 'digest', reason: 'production state from prod-watch (already alerted there; no repo to fix): recorded, no hands job, no question', mergePolicy: 'pr-and-question' };
  }

  if (ALERT_KINDS.has(kind)) {
    return { lane: 'digest', reason: 'overdue control: one P1 message, no hands job', mergePolicy: 'pr-and-question', alert: true };
  }

  // (3) data exposure: contain it now. Rotating a secret stays a question for the hands (destructive class).
  if (EXPOSURE_KINDS.has(kind)) {
    return { lane: 'urgent', reason: 'data exposure detected by a watcher', mergePolicy: 'pr-and-question' };
  }

  // (1) outage / money path: urgent only after self-heal spent its retry budget.
  if (OUTAGE_KINDS.has(kind)) {
    if (f.selfHealExhausted === true) {
      return { lane: 'urgent', reason: `${kind} not fixed by self-heal within its retry budget`, mergePolicy: 'pr-and-question' };
    }
    return { lane: 'nightly', reason: `${kind} still inside the self-heal retry budget`, mergePolicy: 'pr-and-question' };
  }

  // (2) security advisories: urgent only when deployed AND (critical OR known-exploited).
  if (ADVISORY_KINDS.has(kind)) {
    // deployed only when the source says so (the advisory watcher sets it from DEPLOYED_REPOS); unknown = not deployed,
    // so a critical alert in a library or tool repo waits for the nightly batch instead of spending an urgent run
    const deployed = f.deployed === true && f.depScope !== 'development';
    const critical = typeof f.cvss === 'number' && f.cvss >= URGENT_CVSS;
    if (deployed && (critical || f.kev === true)) {
      return { lane: 'urgent', reason: f.kev ? 'known-exploited (CISA KEV) issue in deployed code' : `critical (CVSS ${f.cvss}) issue in deployed code`, mergePolicy: 'pr-and-question' };
    }
    const why = !deployed ? 'not deployed (development-only, or repo not in DEPLOYED_REPOS)' : `CVSS ${f.cvss ?? 'unknown'} below ${URGENT_CVSS} and not KEV`;
    // a plain version bump is pre-approved; anything that touches sensitive areas still needs the question
    const sensitive = matches(DESTRUCTIVE, f) || matches(SENSITIVE, f);
    return { lane: 'nightly', reason: `advisory ${why}`, mergePolicy: sensitive ? 'pr-and-question' : 'auto-when-gate-green' };
  }

  if (matches(DESTRUCTIVE, f)) {
    return { lane: 'question', reason: 'destructive or irreversible class: never acted on unattended', mergePolicy: 'pr-and-question' };
  }
  if (matches(SENSITIVE, f)) {
    return { lane: 'question', reason: 'touches money, auth, data deletion, deploy config or prod data', mergePolicy: 'pr-and-question' };
  }
  if (PRE_APPROVED_KINDS.has(kind)) {
    return { lane: 'nightly', reason: `pre-approved class (${kind})`, mergePolicy: 'auto-when-gate-green' };
  }
  return { lane: 'nightly', reason: `code change (${kind}): PR plus one question`, mergePolicy: 'pr-and-question' };
}
