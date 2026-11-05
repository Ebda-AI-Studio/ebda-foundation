// Finding -> lane. Pure, unit-tested (test/classify.test.ts), and the only place the urgency rules live.
//
// URGENT (Amendment A.1, strict): an immediate hands run, at most URGENT_RUNS_PER_DAY a day and one at a time:
//   (1) a production outage or broken money path (checkout, payment webhook, payout) the self-heal recipes did not fix
//       within their retry budget;
//   (2) a security issue in deployed code or a deployed dependency that is critical (CVSS >= 9.0) or CISA-KEV listed;
//   (3) a data exposure (PII or secret leak) detected by a watcher.
// QUESTION: anything destructive or irreversible (deletes, prod data writes, purchases, secrets, billing) and anything
//   touching money, auth, data deletion, deploy config or prod data waits for Ahmad's answer before any work starts.
// NIGHTLY: everything else, in the one batched run at the end of the day. Only the pre-approved classes (dependency /
//   CVE bumps, docs, tests, lint, flaky-test fixes) may auto-merge, and only when the repo's merge gate is green;
//   every other change becomes a PR plus one question.
import type { Classification, Finding } from './findings';

export const URGENT_CVSS = 9.0;

const OUTAGE_KINDS = new Set(['prod-outage', 'money-path-broken']);
const EXPOSURE_KINDS = new Set(['data-exposure', 'pii-leak', 'secret-leak']);
const ADVISORY_KINDS = new Set(['dependency-advisory', 'code-advisory']);
/** Pre-approved classes: the only ones that may auto-merge (gate green). */
export const PRE_APPROVED_KINDS = new Set(['dep-bump', 'dependency-advisory', 'cve-bump', 'lockfile-drift', 'docs', 'test', 'tests', 'lint', 'lint-autofix', 'format', 'flaky-test']);

// Substring matching on purpose (fail-safe, as in ops/remediation/classify.sh): compound labels such as
// `security-rls` or `payout-migration` must not slip into an autonomous lane. Over-inclusion costs one question.
const DESTRUCTIVE = /delet|drop-table|truncat|purge|wipe|prod-data|data-write|purchase|buy|secret|credential|billing|payment-method/;
const SENSITIVE = /money|payment|payout|checkout|refund|auth|session|rls|polic|migration|env|deploy-config|dns|domain/;

function matches(re: RegExp, f: Finding): boolean {
  return re.test(f.kind.toLowerCase()) || (f.touches ?? []).some((t) => re.test(t.toLowerCase()));
}

export function classifyFinding(f: Finding): Classification {
  const kind = f.kind.toLowerCase();

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
    const deployed = f.deployed !== false && f.depScope !== 'development';
    const critical = typeof f.cvss === 'number' && f.cvss >= URGENT_CVSS;
    if (deployed && (critical || f.kev === true)) {
      return { lane: 'urgent', reason: f.kev ? 'known-exploited (CISA KEV) issue in deployed code' : `critical (CVSS ${f.cvss}) issue in deployed code`, mergePolicy: 'pr-and-question' };
    }
    const why = !deployed ? 'not deployed (development-only or not shipped)' : `CVSS ${f.cvss ?? 'unknown'} below ${URGENT_CVSS} and not KEV`;
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
