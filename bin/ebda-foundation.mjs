#!/usr/bin/env node
// ebda-foundation: sync | check | status | new | capabilities. Plain Node (>=20), no dependencies: it runs from a checkout of the foundation repo.
import { readFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { check, status, sync } from '../lib/foundation.mjs';

function arg(argv, name, fallback) {
  const i = argv.indexOf(name);
  return i >= 0 ? argv[i + 1] : fallback;
}

function usage(msg) {
  console.error(`${msg}\nusage: ebda-foundation capabilities seed --product store|chat --catalogue <file> --out <dir> [--today YYYY-MM-DD]\n       ebda-foundation capabilities backfill-plan --dir <capabilities dir> --config <guard.config.json> [--articles <help content dir>]\n       ebda-foundation capabilities scaffold --dir <capabilities dir> --id <id> --lang ar|en`);
  process.exit(2);
}

async function capabilities([sub, ...rest]) {
  if (sub === 'seed') {
    const [product, catalogue, out] = ['--product', '--catalogue', '--out'].map((k) => arg(rest, k));
    if (!product || !catalogue || !out) usage('seed needs --product, --catalogue and --out');
    const { seed } = await import('../lib/capability-seed.mjs');
    const { written, skipped, report } = seed({ catalogue: resolve(catalogue), product, out: resolve(out), today: arg(rest, '--today', new Date().toISOString().slice(0, 10)) });
    console.log(`written ${written.length}, skipped ${skipped.length}`);
    console.log(`total ${report.counts.total}, needsHelp ${report.counts.needsHelp}, helpGap ${report.counts.helpGap}`);
    console.log(`unclassifiedUndo ${report.unclassifiedUndo.length}, unparsedRoles ${report.unparsedRoles.length}, invalidOperatorReasons ${report.invalidOperatorReasons.length}`);
    for (const k of ['unclassifiedUndo', 'unparsedRoles', 'invalidOperatorReasons']) if (report[k].length) console.log(`${k}: ${report[k].join(' ')}`);
  } else if (sub === 'backfill-plan') {
    const [dir, config] = ['--dir', '--config'].map((k) => arg(rest, k));
    if (!dir || !config) usage('backfill-plan needs --dir and --config');
    const { backfillPlan } = await import('../lib/capability-backfill.mjs');
    const articles = arg(rest, '--articles');
    console.log(JSON.stringify(backfillPlan(resolve(dir), JSON.parse(readFileSync(resolve(config), 'utf8')), { articlesDir: articles && resolve(articles) }), null, 2));
  } else if (sub === 'scaffold') {
    const [dir, id, lang] = ['--dir', '--id', '--lang'].map((k) => arg(rest, k));
    if (!dir || !id || (lang !== 'ar' && lang !== 'en')) usage('scaffold needs --dir, --id and --lang ar|en');
    const { scaffoldArticle } = await import('../lib/capability-backfill.mjs');
    let entry;
    try {
      entry = JSON.parse(readFileSync(join(resolve(dir), `${id}.capability.json`), 'utf8'));
    } catch {
      usage(`no capability file for ${id} in ${dir}`);
    }
    process.stdout.write(scaffoldArticle(entry, lang));
  } else {
    usage(`unknown capabilities subcommand: ${sub ?? '(none)'}`);
  }
}

async function main(argv) {
  const [cmd, ...rest] = argv;
  if (cmd === 'sync') {
    const target = resolve(arg(rest, '--target', '.'));
    const lock = sync({ target, dir: arg(rest, '--dir'), parity: arg(rest, '--parity'), ops: arg(rest, '--ops') });
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
  } else if (cmd === 'capabilities') {
    await capabilities(rest);
  } else {
    console.error('usage: ebda-foundation sync --target <repo> --dir <vendored dir> --parity <test path> [--ops <scripts dir, e.g. scripts/foundation>] | check [--target <repo>] | status <repo>... | new <ebda-name> [--no-remote] [--out <dir>] | capabilities seed|backfill-plan|scaffold (see docs/standard/capability-registry.md)');
    process.exit(2);
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) await main(process.argv.slice(2));
