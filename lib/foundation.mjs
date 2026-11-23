#!/usr/bin/env node
// Library behind bin/ebda-foundation.mjs (sync | check | status). Plain Node (>=20), no dependencies.
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { chmodSync, cpSync, existsSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { dirname, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

export const SRC_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
export const LOCK = 'foundation.lock.json';
const sha256 = (buf) => createHash('sha256').update(buf).digest('hex');
const posix = (p) => p.split(sep).join('/');

function walk(dir) {
  if (!existsSync(dir)) return [];
  return readdirSync(dir, { withFileTypes: true }).flatMap((e) => {
    const p = join(dir, e.name);
    return e.isDirectory() ? walk(p) : [p];
  });
}

/** The ops scripts a consumer vendors into its `--ops` dir (F10): plain files from `ops/`, flat. host-lock.sh and workflow-lint.mjs stay out (not part of the shared gate set). */
export const OPS_FILES = ['merge-gate.sh', 'merge-gate-required.mjs', 'pre-push-gate.sh', 'deploy-verify.mjs', 'cron-lint.mjs', 'logpush-setup.sh'];

/** The vendored file set of the foundation checkout at `root`: [relative-to-dir path, absolute source path]. Tests are not vendored. */
export function vendoredSet(root = SRC_ROOT) {
  const pkgDir = join(root, 'packages/foundation');
  const out = [['package.json', join(pkgDir, 'package.json')]];
  for (const f of walk(join(pkgDir, 'src'))) if (!/\.test\.tsx?$/.test(f)) out.push([posix(relative(join(pkgDir, 'src'), f)), f]);
  for (const f of walk(join(root, 'vectors'))) out.push([posix(relative(root, f)), f]);
  for (const f of walk(join(root, 'legal'))) out.push([posix(relative(root, f)), f]); // counsel-approved clauses and texts: byte for byte
  return out.sort((a, b) => a[0].localeCompare(b[0]));
}

function git(root, ...args) {
  return execFileSync('git', ['-C', root, ...args], { encoding: 'utf8' }).trim();
}

function readJson(p) {
  return JSON.parse(readFileSync(p, 'utf8'));
}

/** Copy the foundation into `target` at `dir`, write the managed parity test and the lock. Returns the lock.
 *  `ops` (a dir such as scripts/foundation) also vendors OPS_FILES there; omitted, it keeps whatever the existing lock already vendors. */
export function sync({ target, dir, parity, ops, root = SRC_ROOT }) {
  if (git(root, 'status', '--porcelain', '--untracked-files=no')) throw new Error(`foundation checkout ${root} has uncommitted changes: commit first, the lock records the commit`);
  const commit = git(root, 'rev-parse', 'HEAD');
  const pkg = readJson(join(root, 'packages/foundation/package.json'));
  const tag = `v${pkg.version}`;
  const abs = join(target, dir);
  const prevLock = existsSync(join(target, LOCK)) ? readJson(join(target, LOCK)) : null;
  const opsDir = ops ?? prevLock?.opsDir;
  const { type: _type, ...vendoredPkg } = pkg; // no "type": the Store's CJS-mode tsc (extensionless imports) must not read the copy as ESM
  rmSync(abs, { recursive: true, force: true });
  const files = {};
  for (const [rel, src] of vendoredSet(root)) {
    let buf = readFileSync(src);
    if (rel === 'package.json') buf = Buffer.from(JSON.stringify({ ...vendoredPkg, foundationCommit: commit, exports: Object.fromEntries(Object.entries(vendoredPkg.exports).map(([k, v]) => [k, v.replace('./src/', './')])) }, null, 2) + '\n');
    const dest = join(abs, rel);
    mkdirSync(dirname(dest), { recursive: true });
    writeFileSync(dest, buf);
    files[posix(join(dir, rel))] = sha256(buf);
  }
  if (opsDir) {
    // only the files this foundation owns are replaced: anything else in the dir is left for `check` to name as an extra file
    for (const f of new Set([...OPS_FILES, ...Object.keys(prevLock?.files ?? {}).filter((k) => k.startsWith(`${opsDir}/`)).map((k) => k.slice(opsDir.length + 1))])) rmSync(join(target, opsDir, f), { force: true });
    for (const f of OPS_FILES) {
      const src = join(root, 'ops', f);
      const buf = readFileSync(src);
      const dest = join(target, opsDir, f);
      mkdirSync(dirname(dest), { recursive: true });
      writeFileSync(dest, buf);
      chmodSync(dest, statSync(src).mode & 0o777);
      files[posix(join(opsDir, f))] = sha256(buf);
    }
  }
  const parityBuf = readFileSync(join(root, 'parity/foundation-parity.test.ts'));
  mkdirSync(dirname(join(target, parity)), { recursive: true });
  writeFileSync(join(target, parity), parityBuf);
  files[posix(parity)] = sha256(parityBuf);
  const lock = { tag, commit, dir: posix(dir), parity: posix(parity), ...(opsDir ? { opsDir: posix(opsDir) } : {}), files, managed: [] };
  writeFileSync(join(target, LOCK), JSON.stringify(lock, null, 2) + '\n');
  return lock;
}

/** The vendored package's peerDependencies (zod for the capability modules) must be declared, at that exact version, by the product's own package.json. */
export function peerProblems(target, vendoredPkg) {
  const p = join(target, 'package.json');
  if (!existsSync(p)) return []; // not a package checkout (fixtures); every product has one
  const own = readJson(p);
  const have = { ...own.peerDependencies, ...own.devDependencies, ...own.dependencies };
  return Object.entries(vendoredPkg.peerDependencies ?? {}).flatMap(([name, want]) => (have[name] === want ? [] : [`peer dependency ${name}@${want} is not declared by package.json (found ${have[name] ?? 'nothing'}): add it before using the vendored modules`]));
}

/** Problems found in a consumer checkout, as readable lines (empty = in sync). */
export function check(target) {
  const lockPath = join(target, LOCK);
  if (!existsSync(lockPath)) return [`${LOCK} is missing`];
  const lock = readJson(lockPath);
  const problems = [];
  for (const [rel, want] of Object.entries(lock.files)) {
    const p = join(target, rel);
    if (!existsSync(p)) problems.push(`missing: ${rel}`);
    else if (sha256(readFileSync(p)) !== want) problems.push(`modified: ${rel}`);
  }
  for (const f of [...walk(join(target, lock.dir)), ...(lock.opsDir ? walk(join(target, lock.opsDir)) : [])]) {
    const rel = posix(relative(target, f));
    if (!(rel in lock.files)) problems.push(`extra file not in the lock: ${rel}`);
  }
  const pkgPath = join(target, lock.dir, 'package.json');
  if (existsSync(pkgPath)) {
    const pkg = readJson(pkgPath);
    if (lock.tag !== `v${pkg.version}`) problems.push(`lock tag ${lock.tag} != vendored package version v${pkg.version}`);
    if (!/^[0-9a-f]{40}$/.test(lock.commit) || lock.commit !== pkg.foundationCommit) problems.push(`lock commit ${lock.commit} != vendored foundationCommit ${pkg.foundationCommit}`);
    problems.push(...peerProblems(target, pkg));
  }
  return problems;
}

function latestTag(remote) {
  try {
    const out = execFileSync('git', ['ls-remote', '--tags', '--refs', remote], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] });
    const tags = out.split('\n').map((l) => l.split('refs/tags/')[1]).filter((t) => /^v\d+\.\d+\.\d+$/.test(t ?? ''));
    return tags.sort((a, b) => a.slice(1).localeCompare(b.slice(1), undefined, { numeric: true })).pop() ?? null;
  } catch {
    return null;
  }
}

/** `store v0.1.0 · whatsapp v0.1.0 · latest v0.1.0 · content identical`. */
export function status(repos, remote = 'https://github.com/Ebda-AI-Studio/ebda-foundation.git') {
  if (repos.length === 0) throw new Error('status: pass at least one consumer repo path (name=path) that holds a foundation lock file');
  const locks = repos.map((r) => {
    const [name, path] = r.includes('=') ? r.split('=') : [r.split('/').pop(), r];
    return { name, lock: readJson(join(path, LOCK)) };
  });
  const rel = (l) => Object.fromEntries(Object.entries(l.files).filter(([k]) => k.startsWith(`${l.dir}/`)).map(([k, v]) => [k.slice(l.dir.length + 1), v]));
  // the vendored ops scripts count toward "content identical" too, keyed apart from the source files
  const opsRel = (l) => Object.fromEntries(Object.entries(l.files).filter(([k]) => l.opsDir && k.startsWith(`${l.opsDir}/`)).map(([k, v]) => [`ops:${k.slice(l.opsDir.length + 1)}`, v]));
  const content = (l) => JSON.stringify({ ...rel(l), ...opsRel(l) });
  const first = content(locks[0].lock);
  const identical = locks.every((x) => content(x.lock) === first);
  const latest = latestTag(remote) ?? 'unknown';
  return `${locks.map((x) => `${x.name} ${x.lock.tag}`).join(' · ')} · latest ${latest} · content ${identical ? 'identical' : 'DIFFERENT'}`;
}

