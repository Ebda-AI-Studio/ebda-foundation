#!/usr/bin/env node
// Lints .github/workflows/*.yml against the Ebda CI standard. Workflows stay product-owned; this only checks them.
// usage: node workflow-lint.mjs [workflowsDir=.github/workflows]      exit 1 and one line per violation
//   - every workflow has a top-level `concurrency:`
//   - every job has `timeout-minutes:`
//   - every `runs-on:` is exactly ${{ fromJSON(vars.EBDA_RUNS_ON || '"ubuntu-latest"') }}
//   - a job that can run on a pull_request carries the fork guard (head.repo.full_name == github.repository), because the
//     same runs-on may resolve to a self-hosted runner
//   - setup-node `cache:` is only allowed when conditional on vars.EBDA_RUNS_ON (the remote cache is for hosted runners only)
//   - every `uses:` is pinned to a 40-hex commit SHA
//   - across the workflows there is an `npm audit` gate and a gitleaks job
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';

const RUNS_ON = "${{ fromJSON(vars.EBDA_RUNS_ON || '\"ubuntu-latest\"') }}";

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
    else if (block[ro].replace(/^    runs-on:\s*/, '').trim() !== RUNS_ON) bad(j.start + ro + 1, `job ${j.id}: runs-on must be exactly ${RUNS_ON}`);
    if (onPr && ro >= 0 && !block.some((l) => /head\.repo\.full_name\s*==\s*github\.repository/.test(l)) && !/needs:/.test(block.join('\n'))) {
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
