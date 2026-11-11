// --dry-run: a scripted exec that answers git / gh / claude / the repo's commands without touching the network, a
// remote, Claude or GitHub. It walks the real runJob pipeline end to end; it only fakes the leaves. Each call is logged.
// Fixture knobs per job (finding.detail.dryRun): { claude: 'fix'|'cannot'|'nochange', tests: 'pass'|'fail', gate: 'green'|'red', usagePct,
//   openPrs: [{number, headRefName, files:[{path}]}] }; a fixture batch may carry `leases` (HANDS-COORD).
import { mkdir, writeFile } from 'node:fs/promises';
import { join } from 'node:path';

export function dryRunExec({ batch, log = () => {}, usagePct = 12 }) {
  const calls = [];
  const knobs = (cwd) => {
    const j = batch.jobs.find((x) => cwd && cwd.includes(x.id));
    return j?.finding?.detail?.dryRun ?? {};
  };
  const ok = (stdout = '') => ({ code: 0, stdout, stderr: '', timedOut: false });
  const resetsAt = Math.floor(Date.now() / 1000) + 3 * 86400;
  async function exec(cmd, args = [], opts = {}) {
    calls.push({ cmd, args, cwd: opts.cwd });
    const k = knobs(opts.cwd);
    log(`  [dry-run] ${cmd} ${args.map((a) => (a.length > 60 ? `${a.slice(0, 57)}...` : a)).join(' ')}`);
    if (cmd === 'git') {
      const verb = args.filter((a, i) => a !== '-c' && args[i - 1] !== '-c')[0];
      if (verb === 'clone') {
        // a tiny base tree: the same workflow file in every clone, so the merge gate has pristine workflows to read
        await mkdir(join(args.at(-1), '.github', 'workflows'), { recursive: true });
        await writeFile(join(args.at(-1), '.github', 'workflows', 'ci.yml'), 'on: pull_request\n');
        return ok();
      }
      if (verb === 'status') return ok(''); // the fresh commit tree is clean after the commit
      if (verb === 'check-ignore') return { code: 1, stdout: '', stderr: '', timedOut: false };
      if (verb === 'rev-parse') return ok('0123456789abcdef0123456789abcdef01234567\n');
      return ok();
    }
    // HANDS-COORD: the open-PR listing (fixture knob openPrs: [{number, headRefName, files:[{path}]}], default none)
    if (cmd === 'gh' && args[0] === 'pr' && args[1] === 'list') return ok(JSON.stringify(k.openPrs ?? []));
    if (cmd === 'gh') return ok(`https://github.com/${args[args.indexOf('--repo') + 1]}/pull/101\n`);
    if (args.includes('stream-json')) {
      // the Claude Code CLI: a rate_limit_event (measured shape) then a result event
      const pct = (k.usagePct ?? usagePct) / 100;
      const events = [
        { type: 'rate_limit_event', rate_limit_info: { status: 'allowed', rateLimitType: 'seven_day', utilization: pct, resetsAt, unifiedWindows: { seven_day: { utilization: pct, resetsAt } } } },
        { type: 'result', subtype: 'success', is_error: false, result: k.claude === 'cannot' ? 'HANDS_CANNOT_FIX: needs a schema change' : 'Fixed the broken link in README.md.' },
      ];
      if (opts.cwd && k.claude !== 'cannot' && k.claude !== 'nochange') await writeFile(join(opts.cwd, 'README.md'), 'fixed\n').catch(() => {});
      for (const e of events) opts.onLine?.(JSON.stringify(e));
      return ok(events.map((e) => JSON.stringify(e)).join('\n'));
    }
    if (cmd === 'python3' && args.includes('secrets-exposure')) return ok('[]');
    if (args.some((a) => a.includes('merge-gate'))) return k.gate === 'red' ? { code: 1, stdout: '', stderr: 'REFUSED: check failed', timedOut: false } : ok('merge-gate: green');
    // the repo's own install / test command
    if (k.tests === 'fail') return { code: 1, stdout: '1 failing', stderr: '', timedOut: false };
    return ok('tests passed');
  }
  return { exec, calls };
}
