// The hands never run git inside the tree Claude edited (security S1): .git/hooks, core.fsmonitor, filter drivers,
// credential helpers and textconv in that tree are attacker-controlled. Instead the changed files are found by comparing
// the work tree with a FRESH clone of the same base commit, byte by byte, with plain filesystem reads that never follow
// symlinks, and the changes are applied to the fresh clone, which is the only tree git commits from.
import { lstat, readdir, readFile, rm, mkdir, writeFile, chmod } from 'node:fs/promises';
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
 * Compare the edited tree `work` against the pristine clone `clean`. Returns
 * { changes: [{path, type:'write'|'delete', buf?, mode?, base?}], refused?: string }.
 * Symlinks, special files and oversized files in the diff are refused (never copied into the commit tree).
 */
export async function treeDiff(work, clean) {
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
    if (st.size > MAX_FILE_BYTES) return { changes: [], refused: `${p} is larger than ${MAX_FILE_BYTES} bytes` };
    const buf = await readFile(join(work, p));
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
