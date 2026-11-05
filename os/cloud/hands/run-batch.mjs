#!/usr/bin/env node
// Ebda OS hands: pull a batch from the brain, work each job sequentially, report every outcome, exit.
//
//   run-batch.mjs --run <runId>              the batch the brain started (container: HANDS_RUN_ID)
//   run-batch.mjs --claim [--max N]          Mac fallback: claim queued nightly jobs (POST /hands/claim) and run them
//   run-batch.mjs --dry-run --fixture <file> walk a fixture batch end to end with no network, Claude, git remote or gh
//
// Env: BRAIN_URL, HANDS_TOKEN (brain contract); GH_TOKEN (git push + gh, fine-grained, contents + pull requests write);
// CLAUDE_CODE_OAUTH_TOKEN (Claude Code, long-lived Max-plan token); HANDS_CONFIG_FILE | HANDS_CONFIG_JSON (per-repo
// config, os/config/hands.example.json); HANDS_GIT_NAME + HANDS_GIT_EMAIL (commit identity); HANDS_SANDBOXED=1 inside
// the container; HANDS_OS_HOME (where ops/merge-gate.sh lives); USAGE_STATE / USAGE_SNAPSHOT (Mac usage sources).
// Exit: 0 = ran (outcomes reported, whatever they were); 2 = could not start (config, brain unreachable); 64 = usage.
import { readFile, rm } from 'node:fs/promises';
import { brainClient, recordingBrain } from './lib/brain-client.mjs';
import { loadConfig } from './lib/config.mjs';
import { dryRunExec } from './lib/dry-run.mjs';
import { exec as realExec } from './lib/exec.mjs';
import { runBatch } from './lib/run.mjs';
import { UsageGuard } from './lib/usage-guard.mjs';
import { join } from 'node:path';

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
function cliProbe(cfg, exec, env) {
  return async () => {
    const events = [];
    const r = await exec(cfg.claudeBin, ['-p', 'Reply with the single word ok.', '--model', 'haiku', '--max-turns', '1', '--output-format', 'stream-json', '--verbose', '--tools', ''], {
      env,
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

export async function main(argv = process.argv.slice(2), env = process.env, out = (s) => console.log(s)) {
  let args;
  try {
    args = parseArgs(argv);
  } catch (e) {
    out(`run-batch: ${e.message}`);
    return 64;
  }
  const log = (s) => out(`[hands ${new Date().toISOString()}] ${s}`);
  let cfg;
  let batch;
  let brain;
  let exec = realExec;
  try {
    if (args.dryRun) {
      const fx = JSON.parse(await readFile(args.fixture, 'utf8'));
      batch = fx.batch;
      const dryEnv = { ...env, HANDS_CONFIG_JSON: JSON.stringify(fx.config), HANDS_WORKDIR: env.HANDS_WORKDIR ?? join(process.env.TMPDIR ?? '/tmp', `ebda-os-hands-dry-${process.pid}`) };
      delete dryEnv.HANDS_CONFIG_FILE;
      cfg = await loadConfig(dryEnv);
      cfg.gitName = 'dry-run';
      cfg.gitEmail = 'dry-run@invalid';
      brain = recordingBrain(batch);
      exec = dryRunExec({ batch, log }).exec;
      log(`DRY RUN: fixture ${args.fixture}, ${batch.jobs.length} job(s); no network, no Claude, no git remote, no gh`);
    } else {
      cfg = await loadConfig(env);
      cfg.gitName = env.HANDS_GIT_NAME;
      cfg.gitEmail = env.HANDS_GIT_EMAIL;
      if (!cfg.gitName || !cfg.gitEmail) throw new Error('HANDS_GIT_NAME and HANDS_GIT_EMAIL are required (commit identity)');
      brain = brainClient({ url: env.BRAIN_URL, token: env.HANDS_TOKEN });
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

  const usage = new UsageGuard({
    thresholdPct: env.HANDS_USAGE_THRESHOLD_PCT ? Number(env.HANDS_USAGE_THRESHOLD_PCT) : cfg.usageThresholdPct,
    manualPath: cfg.usageState ? join(cfg.usageState, 'manual.json') : '',
    snapshotPath: cfg.usageSnapshot,
    probe: cliProbe(cfg, exec, env),
    log,
  });
  log(`run ${batch.runId} (${batch.kind}): ${batch.jobs.length} job(s), per-job cap ${batch.perJobCapMin} min, usage threshold ${Math.min(usage.thresholdPct, batch.usageThresholdPct ?? 100)}%`);
  const results = await runBatch(batch, { brain, cfg, exec, usage, log, keepWorkdir: false, env });
  const counts = results.reduce((m, r) => ((m[r.status] = (m[r.status] ?? 0) + 1), m), {});
  log(`run ${batch.runId} done: ${JSON.stringify(counts)}`);
  if (args.dryRun) await rm(cfg.workdir, { recursive: true, force: true }).catch(() => {});
  if (args.dryRun) out(JSON.stringify({ dryRun: true, outcomes: brain.outcomes, usage: brain.usageReports }, null, 2));
  return 0;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main().then((code) => process.exit(code));
}
