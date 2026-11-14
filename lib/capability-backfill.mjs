// Help backfill tooling: which live capabilities still need a help article, and an MDX skeleton to start one. Plain Node (>=20), no dependencies.
// The decision rules mirror packages/foundation/src/help-article.ts (checkHelp); test/capability-backfill.test.ts pins the two against each other.
import { existsSync, readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';

const OPERATOR_ONLY = new Set(['super_admin', 'operator']);

function readEntries(dir) {
  return readdirSync(dir)
    .filter((f) => f.endsWith('.capability.json'))
    .sort()
    .map((f) => JSON.parse(readFileSync(join(dir, f), 'utf8')));
}

/** capabilities: [{id, version}] from an article's front matter block list ("- id@version"). */
function articleCapabilities(raw) {
  const m = /^---\r?\n([\s\S]*?)\r?\n---/.exec(raw.replace(/^﻿/, ''));
  if (!m) return [];
  const out = [];
  let inList = false;
  for (const line of m[1].split(/\r?\n/)) {
    if (/^capabilities:\s*$/.test(line)) { inList = true; continue; }
    if (inList) {
      const it = /^\s+-\s+(\S+)@(\d+)\s*$/.exec(line);
      if (it) out.push({ id: it[1], version: Number(it[2]) });
      else if (/^\S/.test(line)) inList = false;
    }
  }
  return out;
}

function loadArticle(articlesDir, lang, slug) {
  if (!articlesDir) return null;
  for (const ext of ['mdx', 'md']) {
    const p = join(articlesDir, lang, `${slug}.${ext}`);
    if (existsSync(p)) return articleCapabilities(readFileSync(p, 'utf8'));
  }
  return null;
}

/**
 * Live, merchant-facing, non-exempt entries whose help is missing, absent in a language, unlinked or stale, grouped by area (areas and ids sorted).
 * `articlesDir` holds <lang>/<slug>.mdx; without it no article exists yet, so every needs-help entry is planned.
 */
export function backfillPlan(dir, cfg, { articlesDir } = {}) {
  const byArea = new Map();
  for (const e of readEntries(dir)) {
    const needs = e.status === 'live' && (e.roles ?? []).some((r) => !OPERATOR_ONLY.has(r)) && !(cfg.helpExemptAreas ?? []).includes(e.area);
    if (!needs) continue;
    let ok = false;
    if (e.helpArticle) {
      const caps = ['ar', 'en'].map((lang) => loadArticle(articlesDir, lang, e.helpArticle));
      ok = caps.every((c) => c && c.some((x) => x.id === e.id && x.version === e.version));
    }
    if (ok) continue;
    byArea.set(e.area, [...(byArea.get(e.area) ?? []), e.id]);
  }
  return { batches: [...byArea.keys()].sort().map((name) => ({ name, ids: byArea.get(name).sort() })) };
}

const HEADINGS = { ar: { steps: 'الخطوات', questions: 'أسئلة بيسألها التجار', edge: 'حالات خاصة' }, en: { steps: 'Steps', questions: 'Questions merchants ask', edge: 'Edge cases' } };

/** MDX skeleton: a starting point, a human or agent still writes the real text. */
export function scaffoldArticle(entry, lang) {
  const h = HEADINGS[lang];
  const appPath = (entry.screens ?? []).find((s) => s.startsWith('/'));
  const title = lang === 'ar' ? entry.titleAr : entry.titleEn;
  const front = ['---', `title: ${JSON.stringify(title)}`, 'description: ""', `section: ${JSON.stringify(entry.area)}`, 'order: 100', ...(appPath ? [`appPath: ${appPath}`] : []), 'capabilities:', `  - ${entry.id}@${entry.version}`, '---'];
  const list = (items) => (items.length ? items.map((s) => `- ${s}`).join('\n') : '- ');
  const steps = (entry.steps ?? []).length ? entry.steps.map((s, i) => `${i + 1}. ${s}`).join('\n') : '1. ';
  return `${front.join('\n')}\n\n## ${h.steps}\n\n${steps}\n\n## ${h.questions}\n\n${list(entry.questions?.[lang] ?? [])}\n\n## ${h.edge}\n\n${list(entry.edgeCases ?? [])}\n`;
}
