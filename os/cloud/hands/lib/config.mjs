// Hands configuration. Nothing about a repo is hardcoded: what to install, which tests to run and how to merge come
// from a per-repo JSON config (shape: os/config/hands.example.json), read from HANDS_CONFIG_FILE or HANDS_CONFIG_JSON.
// Commands are argv arrays (no shell). Placeholders in an argument: {dir} (the job checkout), {repo} (owner/name),
// {pr} (PR number), {sha} (PR head sha), {base} (default branch), {os_home} (HANDS_OS_HOME, where ops/ lives).
// Credentials never come from here: GH_TOKEN and CLAUDE_CODE_OAUTH_TOKEN are environment-only (container secrets).
import { readFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

/** os/ in this checkout (ops/merge-gate.sh lives under it); the image copies the same layout to /opt/ebda-os. */
export const OS_DIR = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

export const DEFAULTS = {
  workdir: join(homedir(), '.ebda-os-hands', 'work'),
  jobCapMin: 45,
  runCapMin: 90,
  claudeModel: 'sonnet',
  maxTurns: 80,
  usageThresholdPct: 80,
  branchPrefix: 'os/fix-',
  repos: {},
};

function isArgv(x) {
  return Array.isArray(x) && x.length > 0 && x.every((a) => typeof a === 'string');
}

/** Returns an error string or null. */
export function validateConfig(c) {
  if (!c || typeof c !== 'object') return 'config must be an object';
  if (c.repos === undefined || typeof c.repos !== 'object' || Array.isArray(c.repos)) return 'repos must be an object keyed by owner/name';
  for (const [slug, r] of Object.entries(c.repos)) {
    if (!/^[\w.-]+\/[\w.-]+$/.test(slug)) return `repo key ${slug} must be owner/name`;
    if (!isArgv(r?.test)) return `${slug}: test must be a non-empty argv array (the repo's own affected-tests command)`;
    for (const k of ['install', 'mergeGate']) if (r[k] !== undefined && !isArgv(r[k])) return `${slug}: ${k} must be an argv array`;
    if (r.defaultBranch !== undefined && typeof r.defaultBranch !== 'string') return `${slug}: defaultBranch must be a string`;
  }
  for (const k of ['jobCapMin', 'runCapMin', 'maxTurns', 'usageThresholdPct']) {
    if (c[k] !== undefined && !(Number.isInteger(c[k]) && c[k] > 0)) return `${k} must be a positive integer`;
  }
  return null;
}

export async function loadConfig(env = process.env) {
  let raw = {};
  if (env.HANDS_CONFIG_FILE) raw = JSON.parse(await readFile(env.HANDS_CONFIG_FILE, 'utf8'));
  else if (env.HANDS_CONFIG_JSON) raw = JSON.parse(env.HANDS_CONFIG_JSON);
  const cfg = { ...DEFAULTS, ...raw, repos: raw.repos ?? {} };
  if (env.HANDS_WORKDIR) cfg.workdir = env.HANDS_WORKDIR;
  const err = validateConfig(cfg);
  if (err) throw new Error(`hands config: ${err}`);
  cfg.osHome = env.HANDS_OS_HOME ?? OS_DIR;
  cfg.sandboxed = env.HANDS_SANDBOXED === '1';
  cfg.claudeBin = env.HANDS_CLAUDE_BIN ?? 'claude';
  cfg.usageState = env.USAGE_STATE ?? (env.OS_STATE_DIR ? join(env.OS_STATE_DIR, 'usage') : '');
  cfg.usageSnapshot = env.USAGE_SNAPSHOT ?? (cfg.sandboxed ? '' : join(homedir(), '.claude', 'usage-snapshot.json'));
  return cfg;
}

export function fill(argv, vars) {
  return argv.map((a) => a.replace(/\{(dir|repo|pr|sha|base|os_home)\}/g, (_, k) => String(vars[k] ?? '')));
}
