#!/usr/bin/env node
// ebda-foundation: sync | check | status | new
// The foundation is distributed as sha-pinned VENDORED copies plus a lock file (Ruling FDN-DIST-1).
//   sync    copy this foundation checkout's modules, vectors, ops scripts and the parity test into a product repo, write the lock
//   check   fail (exit 1, naming the file) when a vendored file was edited, is missing, or an unlisted file appeared
//   status  print the tag each product repo is on against the latest foundation tag
//   new     scaffold a new product repo from create/skeleton
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { basename, dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { homedir } from 'node:os';

const SOURCE = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const LOCK = 'foundation.lock.json';
const PKG = join(SOURCE, 'packages/foundation');
const DEFAULTS = { dir: 'foundation', ops: 'scripts/foundation', parity: 'test/foundation-parity.test.ts' };
const REMOTE = 'https://github.com/Whisky-11/ebda-foundation.git';

const sha256 = (buf) => createHash('sha256').update(buf).digest('hex');
const posix = (p) => p.split('\\').join('/');
const die = (msg, code = 1) => { console.error(`ebda-foundation: ${msg}`); process.exit(code); };

function parseArgs(argv) {
  const pos = [], opt = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a.startsWith('--')) {
      const k = a.slice(2);
      if (['no-remote', 'allow-dirty'].includes(k)) opt[k] = true;
      else { opt[k] = argv[++i]; if (opt[k] === undefined) die(`--${k} needs a value`, 64); }
    } else pos.push(a);
  }
  return { pos, opt };
}

function walk(dir) {
  if (!existsSync(dir)) return [];
  return readdirSync(dir).sort().flatMap((n) => {
    if (n === 'node_modules' || n === '.DS_Store') return [];
    const p = join(dir, n);
    return statSync(p).isDirectory() ? walk(p) : [p];
  });
}

/** Every file a sync writes: [destRelPath, Buffer]. */
function plan({ dir, ops, parity, commit }) {
  const files = [];
  const pkg = JSON.parse(readFileSync(join(PKG, 'package.json'), 'utf8'));
  pkg.foundationCommit = commit;
  files.push([`${dir}/package.json`, Buffer.from(JSON.stringify(pkg, null, 2) + '\n')]);
  for (const f of walk(join(PKG, 'src'))) {
    if (/\.test\.ts$/.test(f)) continue;
    files.push([`${dir}/src/${posix(relative(join(PKG, 'src'), f))}`, readFileSync(f)]);
  }
  for (const f of walk(join(SOURCE, 'vectors'))) files.push([`${dir}/vectors/${basename(f)}`, readFileSync(f)]);
  for (const f of walk(join(SOURCE, 'ops'))) files.push([`${ops}/${posix(relative(join(SOURCE, 'ops'), f))}`, readFileSync(f)]);
  files.push([parity, readFileSync(join(SOURCE, 'parity/foundation-parity.test.ts'))]);
  return { files, version: pkg.version };
}

function sourceCommit(opt) {
  if (opt.commit) {
    if (!/^[0-9a-f]{40}$/.test(opt.commit)) die('--commit must be a 40-hex sha', 64);
    return opt.commit;
  }
  try {
    const git = (...a) => execFileSync('git', ['-C', SOURCE, ...a], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
    if (git('status', '--porcelain') && !opt['allow-dirty']) die('the foundation checkout has uncommitted changes; commit them or pass --allow-dirty (or --commit <sha>)');
    return git('rev-parse', 'HEAD');
  } catch (e) {
    die('cannot read the foundation commit (no git checkout); pass --commit <40-hex>');
  }
}

function readLock(target) {
  const p = join(target, LOCK);
  if (!existsSync(p)) die(`${p} not found (run sync first)`);
  return JSON.parse(readFileSync(p, 'utf8'));
}

function sync(opt) {
  const target = resolve(opt.target ?? process.cwd());
  const cfg = { dir: opt.dir ?? DEFAULTS.dir, ops: opt.ops ?? DEFAULTS.ops, parity: opt.parity ?? DEFAULTS.parity };
  const prev = existsSync(join(target, LOCK)) ? JSON.parse(readFileSync(join(target, LOCK), 'utf8')) : null;
  if (prev) { cfg.dir = opt.dir ?? prev.dir; cfg.ops = opt.ops ?? prev.ops; cfg.parity = opt.parity ?? prev.parity; }
  const commit = sourceCommit(opt);
  const { files, version } = plan({ ...cfg, commit });
  const tag = `v${version}`;
  if (opt.to && opt.to !== tag) die(`--to ${opt.to} but this foundation checkout is ${tag}; run the CLI from that tag`);
  const lockFiles = {};
  for (const [rel, buf] of files) {
    const dest = join(target, rel);
    mkdirSync(dirname(dest), { recursive: true });
    writeFileSync(dest, buf);
    if (rel.endsWith(".sh")) execFileSync("chmod", ["+x", dest]);
    lockFiles[rel] = sha256(buf);
  }
  // files the previous sync wrote that this tag no longer ships
  if (prev) for (const rel of Object.keys(prev.files)) if (!(rel in lockFiles)) rmSync(join(target, rel), { force: true });
  const lock = { tag, commit, dir: cfg.dir, ops: cfg.ops, parity: cfg.parity, files: Object.fromEntries(Object.entries(lockFiles).sort()), managed: [`${cfg.ops}/*`] };
  writeFileSync(join(target, LOCK), JSON.stringify(lock, null, 2) + '\n');
  console.log(`ebda-foundation: synced ${tag} (${commit.slice(0, 9)}) into ${target}: ${files.length} files`);
}

/** Returns the list of problems ("MODIFIED path", ...) for a vendored product repo. */
export function verify(target) {
  const lock = readLock(target);
  const problems = [];
  for (const [rel, want] of Object.entries(lock.files)) {
    const p = join(target, rel);
    if (!existsSync(p)) problems.push(`MISSING ${rel}`);
    else if (sha256(readFileSync(p)) !== want) problems.push(`MODIFIED ${rel}`);
  }
  for (const root of [lock.dir, lock.ops]) {
    for (const f of walk(join(target, root))) {
      const rel = posix(relative(target, f));
      if (!(rel in lock.files)) problems.push(`EXTRA ${rel}`);
    }
  }
  const pkgPath = join(target, lock.dir, 'package.json');
  if (existsSync(pkgPath)) {
    const pkg = JSON.parse(readFileSync(pkgPath, 'utf8'));
    if (`v${pkg.version}` !== lock.tag) problems.push(`MISMATCH ${lock.dir}/package.json version v${pkg.version} != lock tag ${lock.tag}`);
    if (pkg.foundationCommit !== lock.commit) problems.push(`MISMATCH ${lock.dir}/package.json foundationCommit != lock commit`);
  }
  return problems;
}

function check(opt) {
  const target = resolve(opt.target ?? process.cwd());
  const problems = verify(target);
  if (problems.length) {
    for (const p of problems) console.error(`ebda-foundation check: ${p}`);
    console.error('ebda-foundation check: vendored files are read-only; change the foundation repo, tag it, and run sync.');
    process.exit(1);
  }
  const lock = readLock(target);
  console.log(`ebda-foundation check: ${lock.tag} clean (${Object.keys(lock.files).length} files)`);
}

const semver = (t) => t.replace(/^v/, '').split('.').map(Number);
const cmp = (a, b) => { const x = semver(a), y = semver(b); for (let i = 0; i < 3; i++) if (x[i] !== y[i]) return x[i] - y[i]; return 0; };

function latestTag(remote) {
  const out = execFileSync('git', ['ls-remote', '--tags', '--refs', remote], { encoding: 'utf8' });
  const tags = out.split('\n').map((l) => l.split('refs/tags/')[1]).filter((t) => /^v\d+\.\d+\.\d+$/.test(t ?? ''));
  return tags.sort(cmp).at(-1) ?? null;
}

function status(opt, repos) {
  if (!repos.length) die('usage: status <repoDir>... [--remote <url>] [--latest <tag>]', 64);
  let latest = opt.latest ?? null;
  if (!latest) { try { latest = latestTag(opt.remote ?? REMOTE); } catch { latest = null; } }
  let skewDays = null;
  if (latest) {
    try { skewDays = Math.floor((Date.now() - new Date(execFileSync('git', ['-C', SOURCE, 'log', '-1', '--format=%cI', latest], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim()).getTime()) / 864e5); } catch { /* tag not local */ }
  }
  const parts = []; let behind = false;
  for (const r of repos) {
    const name = basename(resolve(r)).replace(/^ebda-/, '');
    const lockPath = join(resolve(r), LOCK);
    if (!existsSync(lockPath)) { parts.push(`${name} no lock`); behind = true; continue; }
    const tag = JSON.parse(readFileSync(lockPath, 'utf8')).tag;
    parts.push(`${name} ${tag}`);
    if (latest && cmp(tag, latest) < 0) behind = true;
  }
  parts.push(`latest ${latest ?? 'unknown'}`);
  parts.push(`skew ${behind ? (skewDays === null ? 'behind' : `${skewDays} d`) : '0 d'}`);
  console.log(parts.join(' · '));
}

function fillTemplate(text, vars) {
  return text.replace(/__([A-Z_]+)__/g, (m, k) => (k in vars ? vars[k] : m));
}

function newProduct(opt, name) {
  if (!name || !/^ebda-[a-z][a-z0-9-]{1,30}$/.test(name)) die('usage: new ebda-<product> [--name-ar "..."] [--dest dir] [--no-remote]  (name like ebda-crm)', 64);
  const id = name.slice('ebda-'.length);
  const title = 'Ebda ' + (id.length <= 3 ? id.toUpperCase() : id[0].toUpperCase() + id.slice(1));
  const dest = resolve(opt.dest ?? join(homedir(), 'Desktop/projects/Ebda-AI-Studio/internal-projects', name));
  if (existsSync(dest) && readdirSync(dest).length) die(`${dest} already exists and is not empty`);
  const vars = { NAME: name, ID: id, HOST: `${id}.ebda.app`, TITLE_EN: title, TITLE_AR: opt['name-ar'] ?? `ابدأ ${id.toUpperCase()}`, TODAY: new Date().toISOString().slice(0, 10) };
  const skel = join(SOURCE, 'create/skeleton');
  for (const f of walk(skel)) {
    let rel = posix(relative(skel, f));
    const text = fillTemplate(readFileSync(f, 'utf8'), vars);
    if (rel.endsWith('.tmpl')) rel = rel.slice(0, -5);
    const out = join(dest, fillTemplate(rel, vars));
    mkdirSync(dirname(out), { recursive: true });
    writeFileSync(out, text);
  }
  sync({ ...opt, target: dest });
  const run = (cmd, args, o = {}) => execFileSync(cmd, args, { cwd: dest, stdio: 'inherit', ...o });
  run('npm', ['install', '--no-audit', '--no-fund']);
  if (!existsSync(join(dest, '.git'))) run('git', ['init', '-q', '-b', 'main']);
  run('git', ['-c', 'user.name=ebda-foundation', '-c', 'user.email=noreply@ebda.app', 'commit', '-q', '--allow-empty', '-m', 'chore: init']);
  if (!opt['no-remote']) {
    run('git', ['add', '-A']);   // a fresh scaffold: nothing else is in this directory
    run('git', ['commit', '-q', '-m', `feat: scaffold ${name} from ebda-foundation`]);
    run('gh', ['repo', 'create', `Whisky-11/${name}`, '--private', '--source', '.', '--push']);
    let runsOn = '';
    try { runsOn = execFileSync('gh', ['variable', 'get', 'EBDA_RUNS_ON', '-R', 'Whisky-11/ebda-foundation'], { encoding: 'utf8' }).trim(); } catch { /* none set */ }
    if (runsOn) run('gh', ['variable', 'set', 'EBDA_RUNS_ON', '-R', `Whisky-11/${name}`, '--body', runsOn]);
  } else {
    run('git', ['add', '-A']);
    run('git', ['-c', 'user.name=ebda-foundation', '-c', 'user.email=noreply@ebda.app', 'commit', '-q', '-m', `feat: scaffold ${name} from ebda-foundation`]);
  }
  console.log(`\nebda-foundation: created ${name} at ${dest}\nNext: add "${id}" to PRODUCTS in packages/foundation/src/brand (a foundation PR) if it is not there yet, then work through ${join(SOURCE, 'checklists/launch.md')}`);
}

const [cmd, ...rest] = process.argv.slice(2);
if (import.meta.url === `file://${process.argv[1]}` || process.argv[1]?.endsWith('ebda-foundation')) {
  const { pos, opt } = parseArgs(rest);
  switch (cmd) {
    case 'sync': sync(opt); break;
    case 'check': check(opt); break;
    case 'status': status(opt, pos); break;
    case 'new': newProduct(opt, pos[0]); break;
    default: die('usage: ebda-foundation <sync|check|status|new> [options]\n  sync   [--target dir] [--dir foundation] [--ops scripts/foundation] [--parity test/foundation-parity.test.ts] [--to vX.Y.Z] [--commit sha] [--allow-dirty]\n  check  [--target dir]\n  status <repoDir>... [--remote url] [--latest tag]\n  new    ebda-<product> [--name-ar "..."] [--dest dir] [--no-remote]', 64);
  }
}
