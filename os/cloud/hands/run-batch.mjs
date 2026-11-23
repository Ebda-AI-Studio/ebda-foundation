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
import { appendFileSync, readdirSync, rmSync } from 'node:fs';
import { readFile, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { brainClient, recordingBrain } from './lib/brain-client.mjs';
import { loadConfig, parseThreshold } from './lib/config.mjs';
import { dryRunExec } from './lib/dry-run.mjs';
import { claudeAllowList, newRunKey, proxyEnv, startAnthropicForwarder, startProxy, startRegistryMirror, testsEnv } from './lib/egress.mjs';
import { authModeOf, billableKeyTripwire } from './lib/auth.mjs';
import { CLAUDE_ISOLATION } from './lib/job.mjs';
import { exec as realExec } from './lib/exec.mjs';
import { asSandbox, untrustedEnv } from './lib/git.mjs';
import { runBatch } from './lib/run.mjs';
import { BudgetOnlyGuard, UsageGuard } from './lib/usage-guard.mjs';
import { priceTable } from './lib/prices.mjs';

/** Credentials the hands hold in memory; no child process inherits them from the hands' env. */
export const CRED_KEYS = ['GH_TOKEN', 'GITHUB_TOKEN', 'GH_ENTERPRISE_TOKEN', 'HANDS_GH_TOKENS', 'HANDS_TOKEN', 'HANDS_MAC_TOKEN', 'CLAUDE_CODE_OAUTH_TOKEN', 'ANTHROPIC_API_KEY', 'OPENAI_API_KEY', 'GEMINI_API_KEY', 'GOOGLE_API_KEY'];

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
    const [c, a] = asSandbox(cfg, cfg.claudeBin, ['-p', 'Reply with the single word ok.', ...CLAUDE_ISOLATION, '--model', 'haiku', '--max-turns', '1', '--output-format', 'stream-json', '--verbose', '--tools', '']);
    const r = await exec(c, a, {
      env: untrustedEnv(env, { HOME: cfg.sandboxHome, ...(cfg.proxyEnv ?? {}), DISABLE_AUTOUPDATER: '1', ...(creds.claudeToken ? { CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR: '3' } : {}) }),
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
  const sandboxed = env.HANDS_SANDBOXED === '1';
  const mode = authModeOf(env, sandboxed);
  // F-06: the billable-key tripwire runs before anything else. A stray key bills the API in -p mode, so it is refused, not ignored.
  if (!args.dryRun) {
    const trip = billableKeyTripwire(env, mode);
    if (trip) {
      log(`REFUSED to run: ${trip}`);
      if (env.BRAIN_URL && env.HANDS_TOKEN && env.HANDS_RUN_ID) {
        try {
          await brainClient({ url: env.BRAIN_URL, token: env.HANDS_TOKEN, runId: env.HANDS_RUN_ID }).call('POST', '/hands/refused', { runId: env.HANDS_RUN_ID, reason: `billable key tripwire: ${trip}`.slice(0, 200) });
        } catch {
          /* best effort: the exit code is the signal */
        }
      }
      return 4;
    }
  }
  const ghTokens = (() => {
    try {
      return env.HANDS_GH_TOKENS ? JSON.parse(env.HANDS_GH_TOKENS) : undefined;
    } catch {
      return undefined;
    }
  })();
  const creds = { ghToken: env.GH_TOKEN || undefined, ghTokens, claudeToken: mode === 'max' ? env.CLAUDE_CODE_OAUTH_TOKEN || undefined : undefined, apiKey: mode === 'api' ? env.ANTHROPIC_API_KEY || undefined : undefined };
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
      // test-isolation: a dry run never reads host usage state (~/.claude snapshot, OS_STATE_DIR); only an explicit USAGE_STATE / USAGE_SNAPSHOT
      cfg.usageState = env.USAGE_STATE ?? '';
      cfg.usageSnapshot = env.USAGE_SNAPSHOT ?? '';
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
      // F-06b: a container holds its PER-RUN token (HANDS_TOKEN) and names its run; the Mac holds its own HANDS_MAC_TOKEN
      brain = brainClient({ url: env.BRAIN_URL, token: args.claim ? env.HANDS_MAC_TOKEN : env.HANDS_TOKEN, runId: args.claim ? undefined : args.run });
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

  // F-I8: in the container every untrusted command reaches the network only through the allowlist proxy (entrypoint.sh blocks the rest)
  let proxy = null;
  let testsProxy = null;
  let mirror = null;
  let forwarder = null;
  let meter;
  if (cfg.sandboxed && !args.dryRun) {
    cfg.claudeAuth = mode;
    // F-03: the model API is reached ONLY through the loopback forwarder (messages endpoints, our credential); Claude's CONNECT proxy then
    // has nothing in its allowlist. HANDS_ANTHROPIC_FORWARDER=0 falls back to CONNECT api.anthropic.com (see lib/egress.mjs).
    const secret = mode === 'api' ? env.ANTHROPIC_API_KEY : env.CLAUDE_CODE_OAUTH_TOKEN;
    if (env.HANDS_ANTHROPIC_FORWARDER !== '0') {
      // C1 + C2: a random per-run key (Claude gets it, the forwarder requires it); every API response is metered and posted to the brain as it
      // happens, and appended to a local ledger, so a killed or timed-out job still has its spend on record
      const runKey = newRunKey();
      const ledger = join(cfg.workdir, 'meter.jsonl');
      forwarder = await startAnthropicForwarder({
        mode, secret, runKey, log, maxTokensCeiling: cfg.maxOutputTokens ?? 16000, prices: priceTable(env),
        onMeter: (m) => {
          try {
            appendFileSync(ledger, `${JSON.stringify({ at: Date.now(), runId: batch?.runId ?? args.run, ...m })}\n`);
          } catch {
            /* a full disk must not stop the meter's report */
          }
          const runId = batch?.runId ?? args.run;
          brain.meter({ runId, ...m }).catch((e) => log(`meter report failed: ${e.message}`));
        },
      });
      cfg.anthropicBaseUrl = `http://127.0.0.1:${forwarder.port}`;
      cfg.anthropicPlaceholderKey = runKey;
      meter = {
        begin: (j) => {
          forwarder.begin(j);
          brain.meter({ runId: batch?.runId ?? args.run, jobId: j.id, started: true }).catch((e) => log(`meter start beacon failed: ${e.message}`));
        },
        end: (id) => forwarder.end(id),
      };
    }
    proxy = await startProxy({ allow: forwarder ? [] : claudeAllowList(cfg.egressAllow), log });
    cfg.proxyEnv = proxyEnv(proxy.port);
    // the tests role (install / test / format) gets NO CONNECT target and a read-only registry mirror (RR-egress-roles)
    testsProxy = await startProxy({ allow: [], log });
    mirror = await startRegistryMirror({ log });
    cfg.proxyEnvTests = testsEnv(testsProxy.port, mirror.port);
    log(`egress: claude proxy 127.0.0.1:${proxy.port} (${forwarder ? `nothing; model API via forwarder :${forwarder.port}` : 'model API'}), tests proxy 127.0.0.1:${testsProxy.port} (nothing) + read-only registry mirror 127.0.0.1:${mirror.port}`);
  } else cfg.claudeAuth = mode;

  // I-1: a threshold that is not a finite 1..100 number fails CLOSED (every job refused and reported)
  const parsed = parseThreshold(env.HANDS_USAGE_THRESHOLD_PCT);
  const thresholdPct = parsed === undefined ? cfg.usageThresholdPct : parsed === null ? Number.NaN : parsed;
  if (Number.isNaN(thresholdPct)) log(`HANDS_USAGE_THRESHOLD_PCT=${JSON.stringify(env.HANDS_USAGE_THRESHOLD_PCT)} is not a number 1..100: refusing every job`);
  const usage = mode === 'api' && !args.dryRun ? new BudgetOnlyGuard() : new UsageGuard({
    thresholdPct,
    manualPath: cfg.usageState ? join(cfg.usageState, 'manual.json') : '',
    snapshotPath: cfg.usageSnapshot,
    probe: cliProbe(cfg, exec, childEnv, creds),
    log,
  });
  log(`run ${batch.runId} (${batch.kind}): ${batch.jobs.length} job(s), per-job cap ${batch.perJobCapMin} min, usage threshold ${thresholdPct}% (brain ${batch.usageThresholdPct ?? 'n/a'}%)`);
  const results = await runBatch(batch, { brain, cfg, exec, usage, log, keepWorkdir: false, env: childEnv, creds, meter });
  for (const p of [proxy, testsProxy, mirror, forwarder]) {
    if (!p) continue;
    if (p.denied.size) log(`egress denied during the run: ${[...p.denied].join(', ')}`);
    await p.close();
  }
  const counts = results.reduce((m, r) => ((m[r.status] = (m[r.status] ?? 0) + 1), m), {});
  log(`run ${batch.runId} done: ${JSON.stringify(counts)}`);
  if (args.dryRun) await rm(cfg.workdir, { recursive: true, force: true }).catch(() => {});
  if (args.dryRun) out(JSON.stringify({ dryRun: true, outcomes: brain.outcomes, usage: brain.usageReports }, null, 2));
  return 0;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main().then((code) => process.exit(code));
}
