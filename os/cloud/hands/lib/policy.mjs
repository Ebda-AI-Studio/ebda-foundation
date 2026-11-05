// The merge rule, enforced by the HANDS (4a review, carried requirement 2): the brain accepts any reported outcome, so the
// last check before a merge lives here. A job may be merged automatically only when ALL hold:
//   - the brain classified it 'auto-when-gate-green'
//   - its kind is a pre-approved class (dependency / CVE bumps, docs, tests, lint, flaky fixes)
//   - nothing in its kind or `touches` is destructive, irreversible or sensitive
//   - the repo's own merge gate is green (checked by running it; see job.mjs)
// Everything else stops at a PR and becomes one question. Destructive classes are never worked on unattended at all:
// they need an explicit 'proceed' answer, and even then they are never merged by the hands.
//
// The sets mirror os/cloud/brain/src/classify.ts; test/policy.test.mjs fails when the two drift.

export const PRE_APPROVED_KINDS = new Set(['dep-bump', 'dependency-advisory', 'cve-bump', 'lockfile-drift', 'docs', 'test', 'tests', 'lint', 'lint-autofix', 'format', 'flaky-test']);
export const DESTRUCTIVE = /delet|drop-table|truncat|purge|wipe|prod-data|data-write|purchase|buy|secret|credential|billing|payment-method/;
export const SENSITIVE = /money|payment|payout|checkout|refund|auth|session|rls|polic|migration|env|deploy-config|dns|domain/;

function hits(re, finding) {
  const kind = String(finding?.kind ?? '').toLowerCase();
  return re.test(kind) || (finding?.touches ?? []).some((t) => re.test(String(t).toLowerCase()));
}

export function isDestructive(finding) {
  return hits(DESTRUCTIVE, finding);
}

/** May the hands work on this job unattended at all? Destructive classes need an explicit 'proceed' answer. */
export function mayWork(job) {
  if (isDestructive(job.finding) && job.answer !== 'proceed') {
    return { ok: false, reason: 'destructive or irreversible class without an explicit proceed answer: never acted on unattended' };
  }
  return { ok: true, reason: 'ok' };
}

/** Is the job eligible for an automatic merge (before the merge gate is even asked)? */
export function mayAutoMerge(job) {
  const f = job.finding ?? {};
  const kind = String(f.kind ?? '').toLowerCase();
  if (job.mergePolicy !== 'auto-when-gate-green') return { ok: false, reason: `merge policy ${job.mergePolicy}` };
  if (!PRE_APPROVED_KINDS.has(kind)) return { ok: false, reason: `class ${kind} is not pre-approved` };
  if (hits(DESTRUCTIVE, f)) return { ok: false, reason: 'destructive or irreversible class' };
  if (hits(SENSITIVE, f)) return { ok: false, reason: 'touches money, auth, deploy config or prod data' };
  return { ok: true, reason: `pre-approved class ${kind}` };
}
