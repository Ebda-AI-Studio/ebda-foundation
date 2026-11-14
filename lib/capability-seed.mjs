// Seed capability registry files from the 2026-11-14 catalogues (one JSON file per capability). Plain Node (>=20), no dependencies.
// Run ONCE per product: an existing <id>.capability.json is never read, merged or overwritten, so human review edits survive a rerun.
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const ROLE_ORDER = ['public', 'customer', 'owner', 'staff', 'super_admin', 'operator'];
const OPERATOR_ONLY = new Set(['super_admin', 'operator']);
/** Areas the help guard exempts per product (they have no merchant-facing screen); mirrors capabilities/guard.config.json helpExemptAreas. */
const EXEMPT_AREAS = { store: ['platform'], chat: ['system'] };

/** Same pattern as capabilitySchema.id; kept here because this module is plain Node and cannot import the TS schema. */
const ID_RE = /^[a-z0-9]+(\.[a-z0-9-]+)+$/;
const asArray = (v) => (Array.isArray(v) ? v : v == null ? [] : [String(v)]);

export function parseRoles(raw) {
  let t = asArray(raw).join(' ; ').toLowerCase();
  t = t.replace(/staff\s+cannot[^;,)]*/g, '').replace(/store_admin\s+cannot/g, '');
  const has = (re) => re.test(t);
  const set = new Set();
  if (has(/\bowner\b|store_admin|\bown\b/)) set.add('owner');
  if (has(/\bstaff\b/)) set.add('staff');
  if (has(/super[_ ]admin/)) set.add('super_admin');
  if (has(/\boperator\b/)) set.add('operator');
  if (has(/\bpublic\b|invitee/)) set.add('public');
  if (has(/\bcustomer\b|shopper/)) set.add('customer');
  if (has(/signed-in|merchant user/)) { set.add('owner'); set.add('staff'); }
  const roles = ROLE_ORDER.filter((r) => set.has(r));
  return roles.length ? { roles, parsed: true } : { roles: ['owner'], parsed: false };
}

export function mapHelp(raw) {
  if (raw == null || raw === '') return { slug: null };
  let m = /^help\/(.+)$/.exec(raw);
  if (m) return { slug: m[1] };
  m = /^docs\/help\/\{ar,en\}\/(?:\d+-)?([a-z0-9-]+)\.md$/.exec(raw);
  if (m) return { slug: `whatsapp/${m[1]}` };
  return { slug: null, gap: raw };
}

export function mapUndo(raw, getOnly) {
  if (typeof raw === 'boolean') return raw ? { class: 'reversible' } : { class: getOnly ? 'none' : 'irreversible' };
  const text = String(raw ?? '').trim();
  const note = { note: text };
  if (/^n\/a$/i.test(text)) return { class: 'none', ...note };
  if (/^no\b/i.test(text) || /irreversible/i.test(text)) return { class: 'irreversible', ...note };
  if (/^yes\b/i.test(text)) return { class: /inverse|opposite|reversing|adjust|re-?create/i.test(text) ? 'compensating' : 'reversible', ...note };
  return { class: 'unclassified', ...note };
}

function mapScreens(raw) {
  const out = [];
  for (const part of String(raw ?? '').split(';').map((s) => s.trim()).filter(Boolean)) {
    // a route keeps only its path: "/signup (accounts app)" and "/x?tab=y" claim "/signup" and "/x"
    out.push(part.startsWith('/') ? part.replace(/\s*\(.*$/, '').replace(/\?.*$/, '') : part);
  }
  return out;
}

const viewNames = (raw) => [...new Set(String(raw ?? '').match(/\b[A-Z][a-z0-9]+(?:[A-Z][A-Za-z0-9]*)+\b/g) ?? [])].map((n) => `view:${n}`);

const REASON_CODES = [[/abuse/i, 'abuse'], [/legal/i, 'legal'], [/money/i, 'money-dispute'], [/platform/i, 'platform-config'], [/critical|incident/i, 'critical']];
function mapReason(text, validity) {
  if (!text) return undefined;
  const code = REASON_CODES.find(([re]) => re.test(text))?.[1] ?? null;
  const v = String(validity ?? '');
  return { code, text: String(text).trim(), validUnderRule: /valid/i.test(v) && !/invalid|^gap/i.test(v) };
}

const isPr = (v) => /^ebda-[a-z]+#\d+/.test(v);

/** One catalogue row -> one capability object with keys in schema order. */
export function mapEntry(row, product, today) {
  const api = asArray(row.api);
  const getOnly = api.every((a) => /^GET(\s|$)/i.test(a));
  const { roles, parsed } = parseRoles(row.roles);
  const help = mapHelp(row.help_article);
  const undo = mapUndo(row.undo_possible, getOnly);
  const reason = mapReason(row.super_admin_reason ?? row.operator_reason, row.reason_valid_under_self_service_rule ?? row.operator_reason_valid);
  const srcPlan = product === 'store' ? row.pr_or_plan : row.plan;
  const srcPr = product === 'store' ? undefined : row.pr;
  const pr = srcPr ?? (srcPlan && isPr(srcPlan) ? srcPlan : undefined);
  const plan = srcPlan && !isPr(srcPlan) ? srcPlan : undefined;
  const gaps = [...asArray(row.gaps)];
  if (!parsed) gaps.push('roles unverified');
  if (row.operator_replaces) gaps.push(`operator replaces: ${row.operator_replaces}`);
  const screenText = product === 'store' ? row.page : row.screen;
  const screens = [...mapScreens(screenText), ...(product === 'chat' ? viewNames(screenText) : [])];
  const e = {
    id: row.id,
    status: row.status,
    pr,
    plan,
    area: row.area,
    version: 1,
    versionDate: today,
    titleAr: row.title_ar,
    titleEn: row.title_en,
    screens,
    api,
    mcpTool: row.mcp_tool ?? null,
    planGate: row.plan_gate == null ? null : String(row.plan_gate),
    roles,
    policy: row.assistant_policy,
    undo,
    operatorReason: reason,
    helpArticle: help.slug,
    helpGap: help.gap,
    questions: { ar: asArray(row.merchant_questions_ar), en: asArray(row.merchant_questions_en) },
    steps: asArray(row.steps),
    edgeCases: asArray(row.edge_cases),
    gaps,
    assistantNote: row.assistant_note ?? undefined,
  };
  return { entry: e, parsed, undoClass: undo.class, reasonInvalid: reason?.validUnderRule === false, rawHelpNull: help.slug === null && !help.gap };
}

/** Writes <out>/<id>.capability.json for every catalogue row whose file does not exist yet. */
export function seed({ catalogue, product, out, today }) {
  if (product !== 'store' && product !== 'chat') throw new Error(`product must be store or chat, got ${product}`);
  const rows = JSON.parse(readFileSync(catalogue, 'utf8'));
  if (!Array.isArray(rows)) throw new Error(`${catalogue} is not a catalogue array`);
  // validate every id before writing anything: ids become file names, and a duplicate would silently drop a row
  const seen = new Set();
  for (const row of rows) {
    if (typeof row.id !== 'string' || !ID_RE.test(row.id)) throw new Error(`catalogue id ${JSON.stringify(row.id)} is not path-safe (expected ${ID_RE})`);
    if (seen.has(row.id)) throw new Error(`duplicate id ${row.id} in ${catalogue}`);
    seen.add(row.id);
  }
  mkdirSync(out, { recursive: true });
  const written = [];
  const skipped = [];
  const report = { unclassifiedUndo: [], unparsedRoles: [], invalidOperatorReasons: [], counts: { total: rows.length, needsHelp: 0, helpGap: 0 } };
  for (const row of rows) {
    const m = mapEntry(row, product, today);
    const e = m.entry;
    if (m.undoClass === 'unclassified') report.unclassifiedUndo.push(e.id);
    if (!m.parsed) report.unparsedRoles.push(e.id);
    if (m.reasonInvalid) report.invalidOperatorReasons.push(e.id);
    // needsHelp: live, merchant-facing, area not exempt, and the catalogue names no help doc at all (a row pointing at a non-help doc is counted in helpGap instead)
    const merchantFacing = e.roles.some((r) => !OPERATOR_ONLY.has(r));
    if (e.status === 'live' && merchantFacing && !EXEMPT_AREAS[product].includes(e.area)) {
      if (m.rawHelpNull) report.counts.needsHelp++;
      else if (e.helpGap) report.counts.helpGap++;
    }
    const file = join(out, `${e.id}.capability.json`);
    if (existsSync(file)) { skipped.push(e.id); continue; }
    const clean = Object.fromEntries(Object.entries(e).filter(([, v]) => v !== undefined));
    writeFileSync(file, `${JSON.stringify(clean, null, 2)}\n`);
    written.push(e.id);
  }
  return { written, skipped, report };
}
