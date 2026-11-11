// Every relative markdown link in os/standard/** and os/audit/lenses/** must point at a file that exists.
// Skips absolute URLs, mailto, pure anchors, and anything under ~ (memory pointers are prose, not links).
import { readdirSync, readFileSync, existsSync, statSync } from 'node:fs';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const roots = ['os/standard', 'os/audit/lenses'].map((d) => join(root, d));

function* walk(dir) {
  for (const n of readdirSync(dir)) {
    const p = join(dir, n);
    if (statSync(p).isDirectory()) yield* walk(p);
    else if (n.endsWith('.md')) yield p;
  }
}

let files = 0;
let links = 0;
const broken = [];
for (const r of roots) {
  for (const f of walk(r)) {
    files++;
    const text = readFileSync(f, 'utf8').replace(/```[\s\S]*?```/g, '').replace(/`[^`\n]*`/g, '');
    for (const m of text.matchAll(/\[[^\]\n]*\]\(([^)\s]+)(?:\s+"[^"]*")?\)/g)) {
      let target = m[1];
      if (/^(https?:|mailto:|#|~|\/)/.test(target)) continue;
      target = target.split('#')[0].split('?')[0];
      if (!target) continue;
      links++;
      if (!existsSync(resolve(dirname(f), decodeURI(target)))) broken.push(`${f.slice(root.length + 1)} -> ${m[1]}`);
    }
  }
}
// Every numbered lens row in the index (| N | `id` | ...) must have a standard/<id>.md.
const index = readFileSync(join(root, 'os/standard/00-index.md'), 'utf8');
let rows = 0;
for (const m of index.matchAll(/^\|\s*\d+\s*\|\s*`([a-z0-9-]+)`\s*\|/gm)) {
  rows++;
  if (!existsSync(join(root, 'os/standard', `${m[1]}.md`))) broken.push(`00-index.md row \`${m[1]}\` -> no os/standard/${m[1]}.md`);
}
if (rows === 0) broken.push('00-index.md: no numbered lens rows found (parser drift)');
if (broken.length) {
  console.error(`FAIL: ${broken.length} broken relative link(s) in ${files} file(s):`);
  for (const b of broken) console.error('  ' + b);
  process.exit(1);
}
console.log(`PASS: ${links} relative link(s) across ${files} markdown file(s) resolve; ${rows} index rows all have a standard file`);
