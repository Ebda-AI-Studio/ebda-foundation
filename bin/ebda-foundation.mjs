#!/usr/bin/env node
// ebda-foundation: sync | check | status | new. Plain Node (>=20), no dependencies: it runs from a checkout of the foundation repo.
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { check, status, sync } from '../lib/foundation.mjs';

function arg(argv, name, fallback) {
  const i = argv.indexOf(name);
  return i >= 0 ? argv[i + 1] : fallback;
}

async function main(argv) {
  const [cmd, ...rest] = argv;
  if (cmd === 'sync') {
    const target = resolve(arg(rest, '--target', '.'));
    const lock = sync({ target, dir: arg(rest, '--dir'), parity: arg(rest, '--parity') });
    console.log(`synced ${Object.keys(lock.files).length} files to ${lock.tag} (${lock.commit.slice(0, 9)}) in ${target}`);
  } else if (cmd === 'check') {
    const problems = check(resolve(arg(rest, '--target', '.')));
    if (problems.length) {
      console.error(problems.join('\n'));
      process.exit(1);
    }
    console.log('foundation in sync');
  } else if (cmd === 'status') {
    console.log(status(rest.filter((a) => !a.startsWith('--'))));
  } else if (cmd === 'new') {
    const { createProduct } = await import('../create/new.mjs');
    await createProduct(rest);
  } else {
    console.error('usage: ebda-foundation sync --target <repo> --dir <vendored dir> --parity <test path> | check [--target <repo>] | status <repo>... | new <ebda-name> [--no-remote] [--out <dir>]');
    process.exit(2);
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) await main(process.argv.slice(2));
