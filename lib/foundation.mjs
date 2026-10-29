#!/usr/bin/env node
// Library behind bin/ebda-foundation.mjs (sync | check | status). Plain Node (>=20), no dependencies.
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { cpSync, existsSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs';
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

/** The vendored file set of the foundation checkout at `root`: [relative-to-dir path, absolute source path]. Tests are not vendored. */
export function vendoredSet(root = SRC_ROOT) {
  const pkgDir = join(root, 'packages/foundation');
  const out = [['package.json', join(pkgDir, 'package.json')]];
  for (const f of walk(join(pkgDir, 'src'))) if (!/\.test\.tsx?$/.test(f)) out.push([posix(relative(join(pkgDir, 'src'), f)), f]);
  for (const f of walk(join(root, 'vectors'))) out.push([posix(relative(root, f)), f]);
  return out.sort((a, b) => a[0].localeCompare(b[0]));
}

function git(root, ...args) {
  return execFileSync('git', ['-C', root, ...args], { encoding: 'utf8' }).trim();
}

function readJson(p) {
  return JSON.parse(readFileSync(p, 'utf8'));
}

/** Copy the foundation into `target` at `dir`, write the managed parity test and the lock. Returns the lock. */
export function sync({ target, dir, parity, root = SRC_ROOT }) {
  if (git(root, 'status', '--porcelain', '--untracked-files=no')) throw new Error(`foundation checkout ${root} has uncommitted changes: commit first, the lock records the commit`);
  const commit = git(root, 'rev-parse', 'HEAD');
  const pkg = readJson(join(root, 'packages/foundation/package.json'));
  const tag = `v${pkg.version}`;
  const abs = join(target, dir);
  rmSync(abs, { recursive: true, force: true });
  const files = {};
  for (const [rel, src] of vendoredSet(root)) {
    let buf = readFileSync(src);
    if (rel === 'package.json') buf = Buffer.from(JSON.stringify({ ...pkg, foundationCommit: commit, exports: Object.fromEntries(Object.entries(pkg.exports).map(([k, v]) => [k, v.replace('./src/', './')])) }, null, 2) + '\n');
    const dest = join(abs, rel);
    mkdirSync(dirname(dest), { recursive: true });
    writeFileSync(dest, buf);
    files[posix(join(dir, rel))] = sha256(buf);
  }
  const parityBuf = readFileSync(join(root, 'parity/foundation-parity.test.ts'));
  mkdirSync(dirname(join(target, parity)), { recursive: true });
  writeFileSync(join(target, parity), parityBuf);
  files[posix(parity)] = sha256(parityBuf);
  const lock = { tag, commit, dir: posix(dir), parity: posix(parity), files, managed: [] };
  writeFileSync(join(target, LOCK), JSON.stringify(lock, null, 2) + '\n');
  return lock;
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
  for (const f of walk(join(target, lock.dir))) {
    const rel = posix(relative(target, f));
    if (!(rel in lock.files)) problems.push(`extra file not in the lock: ${rel}`);
  }
  const pkgPath = join(target, lock.dir, 'package.json');
  if (existsSync(pkgPath)) {
    const pkg = readJson(pkgPath);
    if (lock.tag !== `v${pkg.version}`) problems.push(`lock tag ${lock.tag} != vendored package version v${pkg.version}`);
    if (!/^[0-9a-f]{40}$/.test(lock.commit) || lock.commit !== pkg.foundationCommit) problems.push(`lock commit ${lock.commit} != vendored foundationCommit ${pkg.foundationCommit}`);
  }
  return problems;
}

function latestTag(remote) {
  try {
    const out = execFileSync('git', ['ls-remote', '--tags', '--refs', remote], { encoding: 'utf8' });
    const tags = out.split('\n').map((l) => l.split('refs/tags/')[1]).filter((t) => /^v\d+\.\d+\.\d+$/.test(t ?? ''));
    return tags.sort((a, b) => a.slice(1).localeCompare(b.slice(1), undefined, { numeric: true })).pop() ?? null;
  } catch {
    return null;
  }
}

/** `store v0.1.0 · whatsapp v0.1.0 · latest v0.1.0 · content identical`. */
export function status(repos, remote = 'git@github.com:Whisky-11/ebda-foundation.git') {
  const locks = repos.map((r) => {
    const [name, path] = r.includes('=') ? r.split('=') : [r.split('/').pop(), r];
    return { name, lock: readJson(join(path, LOCK)) };
  });
  const rel = (l) => Object.fromEntries(Object.entries(l.files).filter(([k]) => k.startsWith(`${l.dir}/`)).map(([k, v]) => [k.slice(l.dir.length + 1), v]));
  const first = JSON.stringify(rel(locks[0].lock));
  const identical = locks.every((x) => JSON.stringify(rel(x.lock)) === first);
  const latest = latestTag(remote) ?? 'unknown';
  return `${locks.map((x) => `${x.name} ${x.lock.tag}`).join(' · ')} · latest ${latest} · content ${identical ? 'identical' : 'DIFFERENT'}`;
}

