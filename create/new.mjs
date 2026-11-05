// `ebda-foundation new ebda-crm`: scaffold a new Ebda product repo, vendor the foundation, optionally create its private GitHub repo.
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, readdirSync, statSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { SRC_ROOT, sync } from '../lib/foundation.mjs';

/** The reserved-slug list of the foundation checkout (parsed from the TS source so this script needs no TS loader). */
export function reservedSlugs(root = SRC_ROOT) {
  const src = readFileSync(join(root, 'packages/foundation/src/slugs.ts'), 'utf8');
  const body = /RESERVED_SLUGS = \[([\s\S]*?)\] as const/.exec(src)?.[1] ?? '';
  return [...body.matchAll(/'([a-z0-9-]+)'/g)].map((m) => m[1]);
}

const SKELETON = join(dirname(fileURLToPath(import.meta.url)), 'skeleton');

const opt = (argv, name) => {
  const i = argv.indexOf(name);
  return i >= 0 ? argv[i + 1] : undefined;
};

/** Pure: the names derived from `ebda-<x>`. */
export function namesFor(name, displayEn, displayAr) {
  if (!/^ebda-[a-z][a-z0-9-]{1,30}$/.test(name)) throw new Error(`product name must look like ebda-crm (lowercase, ebda- prefix), got "${name}"`);
  const slug = name.slice('ebda-'.length);
  const word = slug.length <= 4 ? slug.toUpperCase() : slug[0].toUpperCase() + slug.slice(1);
  return { name, slug, host: `${slug}.ebda.app`, displayEn: displayEn ?? `Ebda ${word}`, displayAr: displayAr ?? `ابدأ ${word}` };
}

function copyTree(from, to, vars) {
  mkdirSync(to, { recursive: true });
  for (const e of readdirSync(from)) {
    const src = join(from, e);
    if (statSync(src).isDirectory()) {
      copyTree(src, join(to, e), vars);
      continue;
    }
    const outName = e.endsWith('.tmpl') ? e.slice(0, -5) : e;
    const text = readFileSync(src, 'utf8').replace(/\{\{(name|slug|host|displayEn|displayAr)\}\}/g, (_, k) => vars[k]);
    writeFileSync(join(to, outName), text);
  }
}

const sh = (cwd, cmd, args, stdio = 'inherit') => execFileSync(cmd, args, { cwd, stdio });

export async function createProduct(argv) {
  const name = argv[0];
  const vars = namesFor(name, opt(argv, '--display'), opt(argv, '--display-ar'));
  // <slug>.ebda.app is a store host too: an unreserved slug lets a merchant register it first and impersonate the product.
  if (!reservedSlugs().includes(vars.slug)) throw new Error(`"${vars.slug}" is not in RESERVED_SLUGS: add it (and the product to brand) in a foundation PR first, tag, then run new`);
  const out = resolve(opt(argv, '--out') ?? join(homedir(), 'Desktop/projects/Ebda-AI-Studio/internal-projects', name));
  if (existsSync(out)) throw new Error(`${out} already exists`);
  copyTree(SKELETON, out, vars);
  const lock = sync({ target: out, dir: 'foundation', parity: 'test/foundation-parity.test.ts' });
  if (!argv.includes('--no-install')) sh(out, 'npm', ['install', '--no-audit', '--no-fund']);
  sh(out, 'git', ['init', '-q', '-b', 'main']);
  sh(out, 'git', ['add', '.']);
  sh(out, 'git', ['-c', 'user.name=Ahmad Sharaf', '-c', 'user.email=ahmed0montaser@gmail.com', 'commit', '-qm', `chore: init ${name} from ebda-foundation ${lock.tag}`]);
  if (!argv.includes('--no-remote')) {
    sh(out, 'gh', ['repo', 'create', `Ebda-AI-Studio/${name}`, '--private', '--source', '.', '--remote', 'origin', '--push']);
    sh(out, 'gh', ['variable', 'set', 'EBDA_RUNS_ON', '--repo', `Ebda-AI-Studio/${name}`, '--body', '["self-hosted","umbra-ebda"]']);
  }
  console.log(`\n${vars.displayEn} created at ${out} (foundation ${lock.tag})\nNext, before any customer: the foundation repo's checklists/launch.md and docs/new-product.md.`);
}
