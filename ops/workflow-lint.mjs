#!/usr/bin/env node
// Lints .github/workflows/*.yml against the Ebda CI standard. Workflows stay product-owned; this only checks them.
// usage: node workflow-lint.mjs [workflowsDir=.github/workflows]      exit 1 and one line per violation
//   - every workflow has a top-level `concurrency:`
//   - every job has `timeout-minutes:`
//   - every `runs-on:` is exactly ${{ fromJSON(vars.EBDA_RUNS_ON || '"ubuntu-latest"') }} (or the same with vars.EBDA_LIGHT_RUNS_ON || in front, for a seconds-long job), except a job whose runs-on line is
//     `runs-on: ubuntu-latest` directly under a `# hosted-only: <reason>` comment (a job that must NOT follow EBDA_RUNS_ON onto the
//     self-hosted runner, e.g. an outside-in production watch); it may not run on pull_request
//   - a job that can run on a pull_request carries the fork guard (or a `    # fork-guard-exempt: <reason>` comment line in the job, for a job that
//     only inspects/labels a PR and never executes its content, e.g. the fork gate of ai-review.yml) (head.repo.full_name == github.repository), because the
//     same runs-on may resolve to a self-hosted runner
//   - setup-node `cache:` is only allowed when conditional on vars.EBDA_RUNS_ON (the remote cache is for hosted runners only)
//   - every `uses:` is pinned to a 40-hex commit SHA
//   - across the workflows there is an `npm audit` gate and a gitleaks job
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';

const RUNS_ON = "${{ fromJSON(vars.EBDA_RUNS_ON || '\"ubuntu-latest\"') }}";
// A seconds-long plain-node job may route to the light runners: same fallback chain, the light variable first (pr-quality.yml).
const RUNS_ON_LIGHT = "${{ fromJSON(vars.EBDA_LIGHT_RUNS_ON || vars.EBDA_RUNS_ON || '\"ubuntu-latest\"') }}";

export function lintWorkflow(name, text) {
  const out = [];
  const lines = text.split('\n');
  const bad = (n, msg) => out.push(`${name}:${n}: ${msg}`);
  if (!/^concurrency:/m.test(text)) bad(1, 'no top-level concurrency group');
  const onPr = /^on:[\s\S]*?\bpull_request\b/m.test(text.split(/^jobs:/m)[0] ?? '');
  const ji = lines.findIndex((l) => /^jobs:\s*$/.test(l));
  const jobs = [];
  if (ji >= 0) {
    for (let i = ji + 1; i < lines.length; i++) {
      if (/^\S/.test(lines[i]) && lines[i].trim()) break;
      const m = lines[i].match(/^  ([\w-]+):\s*$/);
      if (m) jobs.push({ id: m[1], start: i, end: lines.length });
      if (jobs.length > 1 && jobs.at(-1).start === i) jobs.at(-2).end = i;
    }
  }
  for (const j of jobs) {
    const block = lines.slice(j.start, j.end);
    const at = (re) => block.findIndex((l) => re.test(l));
    if (at(/^    timeout-minutes:\s*\d+/) < 0) bad(j.start + 1, `job ${j.id}: no timeout-minutes`);
    const ro = at(/^    runs-on:/);
    if (ro < 0) bad(j.start + 1, `job ${j.id}: no runs-on`);
    else {
      const val = block[ro].replace(/^    runs-on:\s*/, '').trim();
      const hostedOnly = val === 'ubuntu-latest' && ro > 0 && /^    # hosted-only: \S.{9,}/.test(block[ro - 1]);
      if (hostedOnly && onPr) bad(j.start + ro + 1, `job ${j.id}: a hosted-only job may not run on pull_request`);
      else if (!hostedOnly && val !== RUNS_ON && val !== RUNS_ON_LIGHT) bad(j.start + ro + 1, `job ${j.id}: runs-on must be exactly ${RUNS_ON}`);
    }
    if (onPr && ro >= 0 && !block.some((l) => /head\.repo\.full_name\s*==\s*github\.repository/.test(l)) && !block.some((l) => /^    # fork-guard-exempt: \S.{9,}/.test(l)) && !/needs:/.test(block.join('\n'))) {
      bad(j.start + 1, `job ${j.id}: pull_request job without the fork guard (github.event.pull_request.head.repo.full_name == github.repository)`);
    }
  }
  lines.forEach((l, i) => {
    const u = l.match(/^\s*-?\s*uses:\s*([^\s#]+)/);
    if (u && !u[1].startsWith('./') && !/@[0-9a-f]{40}$/.test(u[1])) bad(i + 1, `action not pinned to a 40-hex SHA: ${u[1]}`);
    if (/^\s+cache:\s*\S/.test(l) && !/vars\.EBDA_RUNS_ON/.test(l) && /setup-node/.test(lines.slice(Math.max(0, i - 6), i).join('\n'))) {
      bad(i + 1, 'setup-node cache must be conditional on vars.EBDA_RUNS_ON (hosted runners only)');
    }
  });
  return out;
}

export function lintDir(dir) {
  const files = readdirSync(dir).filter((f) => /\.ya?ml$/.test(f));
  const all = files.map((f) => ({ f, t: readFileSync(join(dir, f), 'utf8') }));
  const out = all.flatMap(({ f, t }) => lintWorkflow(f, t));
  const joined = all.map((a) => a.t).join('\n');
  if (!/npm audit/.test(joined)) out.push(`${dir}: no workflow runs an npm audit gate`);
  if (!/gitleaks/i.test(joined)) out.push(`${dir}: no gitleaks job`);
  return out;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const dir = process.argv[2] ?? '.github/workflows';
  const problems = lintDir(dir);
  for (const p of problems) console.error(`workflow-lint: ${p}`);
  if (problems.length) process.exit(1);
  console.log(`workflow-lint: ${dir} clean`);
}
