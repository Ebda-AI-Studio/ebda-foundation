#!/usr/bin/env node
// Foundation bump bot (F11, Ruling FDN-BUMP-1). When a foundation tag exists that a consumer's foundation.lock.json is behind, open ONE re-vendor PR in
// that consumer through `ebda-foundation sync`. It NEVER merges, never force-pushes, and is idempotent: a consumer already on the tag, or one that
// already has an open PR for it, is left alone. Run from a checkout of the foundation AT the tag (the workflow checks the tag out; sync records HEAD).
//
// usage: node ops/bump-consumers.mjs [--dry-run] [--tag vX.Y.Z] [--consumers name=owner/repo,...] [--consumer-dir name=path]
//   --dry-run          print the PRs it would open (and their bodies); writes nothing, pushes nothing, needs no token for reads of public repos
//   --consumer-dir     read the lock from / work in a local checkout instead of a remote clone (tests)
// env: GH_TOKEN (fine-grained PAT EBDA_FOUNDATION_BUMP_TOKEN: contents:write + pull-requests:write on each consumer); EBDA_BUMP_GH = gh binary override (tests).
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { SRC_ROOT, check, sync } from '../lib/foundation.mjs';

export const DEFAULT_CONSUMERS = 'ebda-store=Ebda-AI-Studio/ebda-store,ebda-whatsapp=Ebda-AI-Studio/ebda-whatsapp';
export const LABEL = 'foundation-bump';
const TAG_RE = /^v\d+\.\d+\.\d+$/;

/** -1 / 0 / 1 comparing two vX.Y.Z tags numerically. */
export function cmpTag(a, b) {
  const [x, y] = [a, b].map((t) => t.slice(1).split('.').map(Number));
  for (let i = 0; i < 3; i++) if (x[i] !== y[i]) return x[i] < y[i] ? -1 : 1;
  return 0;
}

/** What to do for one consumer: skip (current / ahead / open PR) or open. `open` = open PRs for the target branch; `others` = other open foundation-bump PRs. */
export function decide({ lockTag, tag, open, others }) {
  if (!TAG_RE.test(lockTag ?? '')) return { action: 'skip', why: `unreadable lock tag ${JSON.stringify(lockTag)}` };
  const c = cmpTag(lockTag, tag);
  if (c === 0) return { action: 'skip', why: `already on ${tag}` };
  if (c > 0) return { action: 'skip', why: `lock ${lockTag} is ahead of ${tag} (never downgrades)` };
  if (open.length) return { action: 'skip', why: `open PR #${open[0]} already bumps to ${tag}` };
  return { action: 'open', supersedes: others };
}

/** The PR body: the three sections pr-quality requires, written from facts the bot measured. */
export function prBody({ name, from, to, problems, supersedes, commit }) {
  const sup = supersedes.length ? `\n\nOlder open bump PRs this replaces (close them after merging this one): ${supersedes.map((n) => `#${n}`).join(', ')}.` : '';
  return `## What
Automated re-vendor of \`@ebda/foundation\` in ${name}: ${from} -> ${to} (foundation commit ${commit.slice(0, 9)}), produced by \`ebda-foundation sync\` (\`ops/bump-consumers.mjs\`, Ruling FDN-BUMP-1). Only the vendored directory, the managed parity test and \`foundation.lock.json\` change; see the foundation CHANGELOG for ${to}. The bot never merges: this PR goes through the normal gate.${sup}

## Verified
- \`ebda-foundation sync\` ran against this repo's own lock (dir + parity path taken from it) at ${to}.
- \`ebda-foundation check\` after the sync: ${problems.length ? `${problems.length} problem(s), listed below; PR opened as a draft` : 'in sync, 0 problems'}.${problems.length ? `\n${problems.map((p) => `  - ${p}`).join('\n')}` : ''}

## Not verified
- ${name}'s own typecheck, unit tests and the vendored-parity test: they run in this PR's CI, not in the bot. A red CI means the new foundation tag needs a consumer-side change; do not merge on the bot's word.
- Nothing was deployed; behaviour changes in ${to} reach production only after this merges and ${name} deploys.

## Cost-if-wrong
A bad bump merges into ${name} and breaks its build or a shared behaviour; it is caught by this PR's CI and the merge gate before any deploy, and reverted by reverting the single commit (the lock pins the previous tag).
`;
}

function gh(args, opts = {}) {
  return execFileSync(process.env.EBDA_BUMP_GH || 'gh', args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], ...opts }).trim();
}
function git(cwd, ...args) {
  return execFileSync('git', ['-C', cwd, ...args], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();
}

function parseList(s, what) {
  return s.split(',').filter(Boolean).map((p) => {
    const [name, v] = p.split('=');
    if (!name || !v) throw new Error(`bad ${what} entry ${JSON.stringify(p)} (want name=value)`);
    return [name, v];
  });
}

function readLockRemote(slug) {
  return JSON.parse(gh(['api', '-H', 'Accept: application/vnd.github.raw', `repos/${slug}/contents/foundation.lock.json`]));
}

function openPrs(slug, extra) {
  const out = gh(['pr', 'list', '-R', slug, '--state', 'open', ...extra, '--json', 'number', '--jq', '.[].number']);
  return out ? out.split('\n').map(Number) : [];
}

export async function run(argv, log = console.log, { root = SRC_ROOT } = {}) {
  const flag = (n) => argv.includes(n);
  const val = (n, d) => (argv.includes(n) ? argv[argv.indexOf(n) + 1] : d);
  const dry = flag('--dry-run');
  const pkgTag = `v${JSON.parse(readFileSync(join(root, 'packages/foundation/package.json'), 'utf8')).version}`;
  const tag = val('--tag', pkgTag);
  if (!TAG_RE.test(tag)) throw new Error(`--tag ${tag} is not vX.Y.Z`);
  if (tag !== pkgTag) throw new Error(`checkout is foundation ${pkgTag} but the target tag is ${tag}: check the tag out first (sync vendors the checkout, not a ref)`);
  const consumers = parseList(val('--consumers', DEFAULT_CONSUMERS), '--consumers');
  const dirs = Object.fromEntries(argv.flatMap((a, i) => (a === '--consumer-dir' ? [parseList(argv[i + 1], '--consumer-dir')[0]] : [])));
  const branch = `chore/foundation-${tag}`;
  let opened = 0;
  let failed = 0;
  log(`foundation bump ${dry ? '(DRY RUN) ' : ''}target ${tag}`);
  for (const [name, slug] of consumers) {
    try {
      const local = dirs[name];
      const lock = local ? JSON.parse(readFileSync(join(resolve(local), 'foundation.lock.json'), 'utf8')) : readLockRemote(slug);
      const open = local ? [] : openPrs(slug, ['--head', branch]);
      const others = local ? [] : openPrs(slug, ['--label', LABEL]).filter((n) => !open.includes(n));
      const d = decide({ lockTag: lock.tag, tag, open, others });
      if (d.action === 'skip') {
        log(`${name}: ${d.why}; nothing to do`);
        continue;
      }
      if (dry) {
        log(`WOULD OPEN PR ${slug}: ${lock.tag} -> ${tag} (branch ${branch}, label ${LABEL}${d.supersedes.length ? `, supersedes ${d.supersedes.map((n) => `#${n}`).join(' ')}` : ''}); sync dir ${lock.dir}, parity ${lock.parity}`);
        opened++;
        continue;
      }
      const target = local ? resolve(local) : join(mkdtempSync(join(tmpdir(), `bump-${name}-`)), name);
      if (!local) gh(['repo', 'clone', slug, target, '--', '--depth', '1']);
      if (git(target, 'ls-remote', '--heads', 'origin', branch)) {
        log(`${name}: branch ${branch} already on the remote without an open PR; leaving it for a human`);
        continue;
      }
      git(target, 'checkout', '-q', '-b', branch);
      const fresh = sync({ target, dir: lock.dir, parity: lock.parity, root });
      const problems = check(target);
      git(target, 'add', 'foundation.lock.json', lock.dir, lock.parity);
      git(target, '-c', 'user.name=ebda-foundation-bot', '-c', 'user.email=ebda-foundation-bot@users.noreply.github.com', 'commit', '-qm', `chore(foundation): bump to ${tag}`);
      git(target, 'push', '-q', '-u', 'origin', branch);
      try { gh(['label', 'create', LABEL, '-R', slug, '--color', 'B08D57', '--description', 'Automated ebda-foundation re-vendor']); } catch { /* exists */ }
      const body = prBody({ name, from: lock.tag, to: tag, problems, supersedes: d.supersedes, commit: fresh.commit });
      const url = gh(['pr', 'create', '-R', slug, '--head', branch, '--label', LABEL, '--title', `chore(foundation): bump to ${tag}`, '--body', body, ...(problems.length ? ['--draft'] : [])]);
      log(`${name}: opened ${url}`);
      opened++;
    } catch (e) {
      failed++;
      log(`${name}: FAILED: ${(e.stderr || e.message || e).toString().trim().split('\n')[0]}`);
    }
  }
  log(`${dry ? 'would open' : 'opened'} ${opened}, failed ${failed}`);
  return { opened, failed };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const { failed } = await run(process.argv.slice(2)).catch((e) => { console.error(e.message); return { failed: 1 }; });
  process.exit(failed ? 1 : 0);
}
