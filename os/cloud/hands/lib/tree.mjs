// The hands never run git inside the tree Claude edited (security S1): .git/hooks, core.fsmonitor, filter drivers,
// credential helpers and textconv in that tree are attacker-controlled. Instead the changed files are found by comparing
// the work tree with a FRESH clone of the same base commit, byte by byte, with plain filesystem reads that never follow
// symlinks, and the changes are applied to the fresh clone, which is the only tree git commits from.
import { constants } from 'node:fs';
import { lstat, open, readdir, readFile, realpath, rm, mkdir, writeFile, chmod } from 'node:fs/promises';
import { dirname, join } from 'node:path';

const SKIP_DIRS = new Set(['.git', 'node_modules']);
export const MAX_FILE_BYTES = 5 * 1024 * 1024;

async function walk(root, rel = '', out = new Map()) {
  let entries;
  try {
    entries = await readdir(join(root, rel), { withFileTypes: true });
  } catch {
    return out;
  }
  for (const e of entries) {
    const p = rel ? `${rel}/${e.name}` : e.name;
    if (e.isDirectory()) {
      if (!SKIP_DIRS.has(e.name)) await walk(root, p, out);
    } else if (e.isSymbolicLink()) {
      out.set(p, { kind: 'symlink' });
    } else if (e.isFile()) {
      out.set(p, { kind: 'file' });
    } else {
      out.set(p, { kind: 'other' });
    }
  }
  return out;
}

/**
 * Read one regular file without ever following a symlink (re-review N-2): the parent dir must still resolve to where
 * the walk saw it, the final component is opened O_NOFOLLOW, and the open file must be the same inode the walk
 * lstat'ed. A swap between walk and read (a process Claude left behind) is refused, never read through.
 */
export async function readNoFollow(root, rel, seen) {
  const abs = join(root, rel);
  const realRoot = await realpath(root);
  const parent = await realpath(dirname(abs));
  if (parent !== join(realRoot, dirname(rel)) && !(dirname(rel) === '.' && parent === realRoot)) throw new Error(`${rel}: a parent directory changed into a link`);
  const fh = await open(abs, constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const st = await fh.stat();
    if (!st.isFile() || st.ino !== seen.ino || st.dev !== seen.dev) throw new Error(`${rel} changed while it was read`);
    return await fh.readFile();
  } finally {
    await fh.close();
  }
}

/**
 * Compare the edited tree `work` against the pristine clone `clean`. Returns
 * { changes: [{path, type:'write'|'delete', buf?, mode?, base?}], refused?: string }.
 * Symlinks, special files and oversized files in the diff are refused (never copied into the commit tree).
 */
export async function treeDiff(work, clean, opts = {}) {
  const a = await walk(work);
  const b = await walk(clean);
  const changes = [];
  for (const [p, info] of a) {
    const other = b.get(p);
    if (info.kind !== 'file') {
      if (!other || other.kind !== info.kind) return { changes: [], refused: `${p} is a ${info.kind}; the hands only commit regular files` };
      continue; // an unchanged symlink present in both trees
    }
    const st = await lstat(join(work, p));
    if (!st.isFile()) return { changes: [], refused: `${p} changed into a ${st.isSymbolicLink() ? 'symlink' : 'non-file'} during the walk` };
    if (st.size > MAX_FILE_BYTES) return { changes: [], refused: `${p} is larger than ${MAX_FILE_BYTES} bytes` };
    if (opts.beforeRead) await opts.beforeRead(p);
    let buf;
    try {
      buf = await readNoFollow(work, p, st);
    } catch (e) {
      return { changes: [], refused: `${p}: refused to read (${e.code === 'ELOOP' ? 'it became a symlink' : e.message})` };
    }
    const mode = st.mode & 0o111 ? 0o755 : 0o644;
    if (other?.kind === 'file') {
      const bst = await lstat(join(clean, p));
      const base = await readFile(join(clean, p));
      const bmode = bst.mode & 0o111 ? 0o755 : 0o644;
      if (base.equals(buf) && bmode === mode) continue;
      changes.push({ path: p, type: 'write', buf, mode, base });
    } else if (other) {
      return { changes: [], refused: `${p} replaces a ${other.kind}` };
    } else {
      changes.push({ path: p, type: 'write', buf, mode, base: null });
    }
  }
  for (const [p, info] of b) {
    if (!a.has(p)) {
      if (info.kind !== 'file') return { changes: [], refused: `${p} (a ${info.kind}) was removed` };
      changes.push({ path: p, type: 'delete', base: await readFile(join(clean, p)) });
    }
  }
  changes.sort((x, y) => x.path.localeCompare(y.path));
  return { changes };
}

/** Write the changes into `dir` (the fresh clone). Paths are relative, validated against escaping. */
export async function applyChanges(dir, changes) {
  for (const c of changes) {
    if (c.path.split('/').some((s) => s === '..' || s === '' || s === '.git')) throw new Error(`refusing path ${c.path}`);
    const target = join(dir, c.path);
    if (c.type === 'delete') {
      await rm(target, { force: true });
      continue;
    }
    await mkdir(dirname(target), { recursive: true });
    await writeFile(target, c.buf);
    await chmod(target, c.mode ?? 0o644);
  }
}
