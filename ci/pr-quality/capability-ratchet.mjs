#!/usr/bin/env node
// Capability baselines may only shrink (os/standard/ai-native-self-service.md, docs/standard/capability-registry.md).
//   node capability-ratchet.mjs --base <base-checkout> --pr <pr-checkout>
// For every capabilities/baselines/*.json in the PR checkout, fails (exit 1) listing each id the PR file has and the base file lacks.
// A base with no such file (the adoption PR) is allowed. Runs from the base checkout, so a PR cannot edit the judge (Ruling PRQ-3).
import { existsSync, lstatSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { readJsonRegular } from './slop-guard.mjs';

const DIR = 'capabilities/baselines';
const idsOf = (p) => {
  const j = readJsonRegular(p);
  return Array.isArray(j) ? j : (j.ids ?? []);
};

export function growth(base, pr) {
  const out = [];
  const dir = join(pr, DIR);
  if (!existsSync(dir) || lstatSync(dir).isSymbolicLink()) return out;
  for (const name of readdirSync(dir).filter((n) => n.endsWith('.json')).sort()) {
    const bp = join(base, DIR, name);
    if (!existsSync(bp)) continue;
    const B = new Set(idsOf(bp));
    for (const id of idsOf(join(dir, name))) if (!B.has(id)) out.push(`${name}: ${id}`);
  }
  return out;
}

function main() {
  const a = process.argv.slice(2);
  const arg = (k) => (a.includes(k) ? a[a.indexOf(k) + 1] : undefined);
  const base = arg('--base');
  const pr = arg('--pr');
  if (!base || !pr) { console.error('usage: capability-ratchet.mjs --base <base-checkout> --pr <pr-checkout>'); process.exit(2); }
  const grew = growth(base, pr);
  for (const g of grew) console.error(`capability-ratchet: the PR baseline holds an id the base branch's does not (baselines only shrink): ${g}`);
  if (grew.length) process.exit(1);
  console.log('capability-ratchet: ok (no baseline grew)');
}
if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) main();
