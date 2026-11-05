#!/usr/bin/env node
// Ebda OS hands: pull a batch from the brain, work each job sequentially, report every outcome, exit.
//
//   run-batch.mjs --run <runId>              the batch the brain started (container: HANDS_RUN_ID)
//   run-batch.mjs --claim [--max N]          Mac fallback: claim queued nightly jobs (POST /hands/claim) and run them
//   run-batch.mjs --dry-run --fixture <file> walk a fixture batch end to end with no network, Claude, git remote or gh
//
// Env: BRAIN_URL, HANDS_TOKEN (brain contract); GH_TOKEN (fine-grained, contents + pull requests write; handed ONLY to
// git clone/push via askpass and to gh / the merge gate); CLAUDE_CODE_OAUTH_TOKEN (container; handed to Claude through
// fd 3, never its env); HANDS_CONFIG_FILE | HANDS_CONFIG_JSON (per-repo config, os/config/hands.example.json);
// HANDS_GIT_NAME + HANDS_GIT_EMAIL (commit identity); HANDS_SANDBOXED=1 + HANDS_SANDBOX_USER (container);
// HANDS_OS_HOME (where ops/merge-gate.sh lives); HANDS_USAGE_THRESHOLD_PCT (1..100, else every job is refused);
// HANDS_GITLEAKS (gitleaks binary, optional); USAGE_STATE / USAGE_SNAPSHOT (Mac usage sources).
// Exit: 0 = ran (outcomes reported, whatever they were); 2 = could not start (config, brain unreachable); 64 = usage.
import { readdirSync, rmSync } from 'node:fs';
import { readFile, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { brainClient, recordingBrain } from './lib/brain-client.mjs';
import { loadConfig, parseThreshold } from './lib/config.mjs';
import { dryRunExec } from './lib/dry-run.mjs';
import { exec as realExec } from './lib/exec.mjs';
import { asSandbox, untrustedEnv } from './lib/git.mjs';
import { runBatch } from './lib/run.mjs';
import { UsageGuard } from './lib/usage-guard.mjs';

/** Credentials the hands hold in memory; no child process inherits them from the hands' env. */
export const CRED_KEYS = ['GH_TOKEN', 'GITHUB_TOKEN', 'GH_ENTERPRISE_TOKEN', 'HANDS_TOKEN', 'CLAUDE_CODE_OAUTH_TOKEN', 'ANTHROPIC_API_KEY'];

function parseArgs(argv) {
  const a = { dryRun: false, max: 5 };
  for (let i = 0; i < argv.length; i++) {
    const k = argv[i];
    if (k === '--dry-run') a.dryRun = true;
    else if (k === '--fixture') a.fixture = argv[++i];
    else if (k === '--run') a.run = argv[++i];
    else if (k === '--claim') a.claim = true;
    else if (k === '--max') a.max = Number.parseInt(argv[++i], 10);
    else if (k === '--provider') a.provider = argv[++i];
    else throw new Error(`unknown argument ${k}`);
  }
  if (a.dryRun && !a.fixture) throw new Error('--dry-run needs --fixture <batch.json>');
  if (!a.dryRun && !a.run && !a.claim) a.run = process.env.HANDS_RUN_ID;
  if (!a.dryRun && !a.run && !a.claim) throw new Error('pass --run <runId>, --claim or --dry-run --fixture <file>');
  return a;
}

/** One-turn Claude call whose only purpose is the CLI's rate_limit_event (the weekly-usage reading). */
function cliProbe(cfg, exec, env, creds) {
  return async () => {
    const events = [];
    const [c, a] = asSandbox(cfg, cfg.claudeBin, ['-p', 'Reply with the single word ok.', '--model', 'haiku', '--max-turns', '1', '--output-format', 'stream-json', '--verbose', '--tools', '']);
    const r = await exec(c, a, {
      env: untrustedEnv(env, { HOME: cfg.sandboxHome, DISABLE_AUTOUPDATER: '1', ...(creds.claudeToken ? { CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR: '3' } : {}) }),
      ...(creds.claudeToken ? { fd3: creds.claudeToken } : {}),
      timeoutMs: 120_000,
      onLine: (l) => {
        try {
          events.push(JSON.parse(l));
        } catch {
          /* not json */
        }
      },
    });
    if (r.code !== 0 && !events.length) throw new Error(`exit ${r.code}: ${r.stderr.slice(-200)}`);
    return events;
  };
}

/** Remove job dirs a crashed run left behind (only entries named job_*: a misconfigured workdir is never wiped). */
export function sweepWorkdir(workdir) {
  let n = 0;
  try {
    for (const e of readdirSync(workdir)) {
      if (/^job_[\w-]+$/.test(e)) {
        rmSync(join(workdir, e), { recursive: true, force: true });
        n++;
      }
    }
  } catch {
    /* no workdir yet */
  }
  return n;
}

export async function main(argv = process.argv.slice(2), env = process.env, out = (s) => console.log(s)) {
  let args;
  try {
    args = parseArgs(argv);
  } catch (e) {
    out(`run-batch: ${e.message}`);
    return 64;
  }
  const log = (s) => out(`[hands ${new Date().toISOString()}] ${s}`);
  const creds = { ghToken: env.GH_TOKEN || undefined, claudeToken: env.CLAUDE_CODE_OAUTH_TOKEN || undefined };
  const childEnv = { ...env };
  for (const k of CRED_KEYS) delete childEnv[k];
  let cfg;
  let batch;
  let brain;
  let exec = realExec;
  try {
    if (args.dryRun) {
      const fx = JSON.parse(await readFile(args.fixture, 'utf8'));
      batch = fx.batch;
      const dryEnv = { ...childEnv, HANDS_CONFIG_JSON: JSON.stringify(fx.config), HANDS_WORKDIR: env.HANDS_WORKDIR ?? join(process.env.TMPDIR ?? '/tmp', `ebda-os-hands-dry-${process.pid}`) };
      delete dryEnv.HANDS_CONFIG_FILE;
      cfg = await loadConfig(dryEnv);
      cfg.gitName = 'dry-run';
      cfg.gitEmail = 'dry-run@invalid';
      cfg.gitleaks = '';
      brain = recordingBrain(batch);
      exec = dryRunExec({ batch, log }).exec;
      creds.ghToken = undefined;
      creds.claudeToken = undefined;
      log(`DRY RUN: fixture ${args.fixture}, ${batch.jobs.length} job(s); no network, no Claude, no git remote, no gh`);
    } else {
      cfg = await loadConfig(childEnv);
      cfg.gitName = env.HANDS_GIT_NAME;
      cfg.gitEmail = env.HANDS_GIT_EMAIL;
      if (!cfg.gitName || !cfg.gitEmail) throw new Error('HANDS_GIT_NAME and HANDS_GIT_EMAIL are required (commit identity)');
      brain = brainClient({ url: env.BRAIN_URL, token: env.HANDS_TOKEN });
      const swept = sweepWorkdir(cfg.workdir);
      if (swept) log(`removed ${swept} job dir(s) left by an earlier crash`);
      if (args.claim) {
        const r = await brain.claim(args.provider ?? 'mac-local', Number.isInteger(args.max) ? args.max : 5);
        if (!r || r.refused) {
          log(`nothing claimed: ${r?.refused ?? 'no answer'}`);
          return 0;
        }
        batch = r;
      } else {
        batch = await brain.getRun(args.run);
      }
    }
  } catch (e) {
    out(`run-batch: cannot start: ${e.message}`);
    return 2;
  }

  // a crash (SIGTERM from the container cap, Ctrl-C, launchd stop) must not leave checkouts behind
  const onSignal = (sig) => {
    sweepWorkdir(cfg.workdir);
    process.exit(sig === 'SIGINT' ? 130 : 143);
  };
  if (!args.dryRun) for (const s of ['SIGTERM', 'SIGINT', 'SIGHUP']) process.once(s, onSignal);

  // I-1: a threshold that is not a finite 1..100 number fails CLOSED (every job refused and reported)
  const parsed = parseThreshold(env.HANDS_USAGE_THRESHOLD_PCT);
  const thresholdPct = parsed === undefined ? cfg.usageThresholdPct : parsed === null ? Number.NaN : parsed;
  if (Number.isNaN(thresholdPct)) log(`HANDS_USAGE_THRESHOLD_PCT=${JSON.stringify(env.HANDS_USAGE_THRESHOLD_PCT)} is not a number 1..100: refusing every job`);
  const usage = new UsageGuard({
    thresholdPct,
    manualPath: cfg.usageState ? join(cfg.usageState, 'manual.json') : '',
    snapshotPath: cfg.usageSnapshot,
    probe: cliProbe(cfg, exec, childEnv, creds),
    log,
  });
  log(`run ${batch.runId} (${batch.kind}): ${batch.jobs.length} job(s), per-job cap ${batch.perJobCapMin} min, usage threshold ${thresholdPct}% (brain ${batch.usageThresholdPct ?? 'n/a'}%)`);
  const results = await runBatch(batch, { brain, cfg, exec, usage, log, keepWorkdir: false, env: childEnv, creds });
  const counts = results.reduce((m, r) => ((m[r.status] = (m[r.status] ?? 0) + 1), m), {});
  log(`run ${batch.runId} done: ${JSON.stringify(counts)}`);
  if (args.dryRun) await rm(cfg.workdir, { recursive: true, force: true }).catch(() => {});
  if (args.dryRun) out(JSON.stringify({ dryRun: true, outcomes: brain.outcomes, usage: brain.usageReports }, null, 2));
  return 0;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main().then((code) => process.exit(code));
}
