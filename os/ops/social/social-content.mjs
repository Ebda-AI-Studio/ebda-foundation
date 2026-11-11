#!/usr/bin/env node
// Social content job (Mac, daily via launchd social-content). Fills the brain's calendar 2-8 days ahead with Facebook + LinkedIn drafts
// for both brands (copy by `claude -p --model sonnet`, image = the brand HTML template rendered to JPEG by headless Chrome), and
// rewrites the posts Ahmad asked to edit. The brain is the gate (copy rules, approval window); this job only proposes.
// Plan: docs/plans/2026-11-11-social-posting.md. Instagram and TikTok are Ahmad's own and are never generated here.
//
// env: OS_BRAIN_URL, INGEST_TOKEN (from $OS_SERVICES_ENV via social-content.sh), optional CLAUDE_BIN, CHROME_BIN, SOCIAL_MAX_DRAFTS (8)
// flags: --dry-run (reads the calendar if it can, generates + renders, prints, POSTS NOTHING)
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const DAY = 86_400_000;
const NETWORKS = ['facebook', 'linkedin'];

/** Cairo wall-clock parts of an instant. */
export function cairoParts(ms) {
  const f = new Intl.DateTimeFormat('en-GB', { timeZone: 'Africa/Cairo', year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', weekday: 'short', hourCycle: 'h23' });
  const p = Object.fromEntries(f.formatToParts(ms).map((x) => [x.type, x.value]));
  const wd = { Mon: 1, Tue: 2, Wed: 3, Thu: 4, Fri: 5, Sat: 6, Sun: 7 }[p.weekday];
  return { y: +p.year, m: +p.month, d: +p.day, hh: +p.hour, mm: +p.minute, wd };
}

/** UTC epoch of a Cairo wall-clock time (handles Egyptian summer time). */
export function cairoToUtc(y, m, d, hh, mm) {
  let t = Date.UTC(y, m - 1, d, hh, mm);
  for (let i = 0; i < 2; i++) {
    const p = cairoParts(t);
    const off = Date.UTC(p.y, p.m - 1, p.d, p.hh, p.mm) - t;
    t = Date.UTC(y, m - 1, d, hh, mm) - off;
  }
  return t;
}

const pad = (n) => String(n).padStart(2, '0');

/** Every cadence slot between horizon.min and horizon.max days ahead, with its stable brain id. */
export function slotsFor(config, now) {
  const out = [];
  for (let k = config.horizonDays.min; k <= config.horizonDays.max; k++) {
    const day = cairoParts(now + k * DAY);
    for (const [brand, b] of Object.entries(config.brands)) {
      for (const network of NETWORKS) {
        for (const s of b.cadence?.[network] ?? []) {
          if (s.weekday !== day.wd) continue;
          const [hh, mm] = s.time.split(':').map(Number);
          out.push({ id: `${brand}-${network}-${day.y}${pad(day.m)}${pad(day.d)}${pad(hh)}${pad(mm)}`, brand, network, scheduledAt: cairoToUtc(day.y, day.m, day.d, hh, mm) });
        }
      }
    }
  }
  return out.sort((a, b) => a.scheduledAt - b.scheduledAt);
}

export function topicFor(brandCfg, id) {
  let h = 0;
  for (const c of id) h = (h * 31 + c.charCodeAt(0)) >>> 0;
  return brandCfg.topics[h % brandCfg.topics.length];
}

export const escHtml = (s) => String(s).replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);

export function renderHtml(template, v) {
  return template.replace(/\{\{(headline|sub|lang|dir)\}\}/g, (_, k) => escHtml(v[k] ?? ''));
}

export function buildPrompt(brandCfg, network, topic, edit) {
  const lines = [
    `Write one ${network === 'linkedin' ? 'LinkedIn company-page' : 'Facebook Page'} post for ${brandCfg.label}.`,
    `Audience: ${brandCfg.audience}.`,
    `Voice: ${brandCfg.voice}.`,
    `Topic: ${topic}.`,
    'Facts you may use (use NOTHING else as a fact):',
    ...brandCfg.facts.map((f) => `- ${f}`),
    'Hard rules: no emojis or emoji-like symbols; no numbers, percentages, statistics, client names, reviews, ratings or testimonials; no claims that are not in the facts; never mention any other company; no hashtags except at most two at the very end.',
    brandCfg.languages[0] === 'ar-EG'
      ? 'Write the post in Egyptian Arabic first (full sentences), then a blank line, then the same message in plain English. The headline and sub are Arabic.'
      : 'Write in English.',
    `Length: ${network === 'linkedin' ? '600-1200' : '300-700'} characters for "text".`,
    'Return ONLY a JSON object: {"headline": "<= 8 words for the image", "sub": "<= 18 words for the image", "text": "the post", "altText": "one sentence describing the image"}.',
  ];
  if (edit) lines.push('', 'This is a REWRITE. The previous version:', edit.text, '', `Ahmad asked for this change: ${edit.note}`);
  return lines.join('\n');
}

/** `claude -p --output-format json` prints {"result": "..."}; the result holds the post JSON, maybe fenced. */
export function parseClaudeJson(stdout) {
  const outer = JSON.parse(stdout);
  const r = String(outer.result ?? '');
  const m = r.match(/\{[\s\S]*\}/);
  if (!m) throw new Error('no JSON object in the model output');
  const o = JSON.parse(m[0]);
  for (const k of ['headline', 'sub', 'text']) if (typeof o[k] !== 'string' || !o[k].trim()) throw new Error(`model output missing ${k}`);
  return o;
}

function generate(brandCfg, network, topic, edit, rejection) {
  let prompt = buildPrompt(brandCfg, network, topic, edit);
  if (rejection) prompt += `\n\nYour previous answer was rejected by the checker: ${rejection}. Fix that.`;
  const out = execFileSync(process.env.CLAUDE_BIN || 'claude', ['-p', '--model', 'sonnet', '--output-format', 'json', prompt], { encoding: 'utf8', timeout: 240_000, maxBuffer: 4 << 20 });
  return parseClaudeJson(out);
}

export function render(brandCfg, copy) {
  const dir = mkdtempSync(join(tmpdir(), 'social-'));
  try {
    const ar = brandCfg.languages[0] === 'ar-EG';
    const html = renderHtml(readFileSync(join(HERE, 'templates', brandCfg.template), 'utf8'), { ...copy, lang: ar ? 'ar' : 'en', dir: ar ? 'rtl' : 'ltr' });
    writeFileSync(join(dir, 'post.html'), html);
    const chrome = process.env.CHROME_BIN || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
    execFileSync(chrome, ['--headless=new', '--disable-gpu', '--hide-scrollbars', '--window-size=1080,1080', '--virtual-time-budget=8000', `--screenshot=${join(dir, 'post.png')}`, pathToFileURL(join(dir, 'post.html')).href], { stdio: 'ignore', timeout: 60_000 });
    execFileSync('/usr/bin/sips', ['-s', 'format', 'jpeg', '-s', 'formatOptions', '85', join(dir, 'post.png'), '--out', join(dir, 'post.jpg')], { stdio: 'ignore' });
    return readFileSync(join(dir, 'post.jpg')).toString('base64');
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

async function brain(path, init = {}) {
  const r = await fetch(`${process.env.OS_BRAIN_URL.replace(/\/$/, '')}${path}`, { ...init, headers: { authorization: `Bearer ${process.env.INGEST_TOKEN}`, 'content-type': 'application/json' }, signal: AbortSignal.timeout(30_000) });
  const body = await r.json().catch(() => null);
  return { status: r.status, body };
}

async function main() {
  const dry = process.argv.includes('--dry-run');
  if (!dry && (!process.env.OS_BRAIN_URL || !process.env.INGEST_TOKEN)) {
    console.error('[social-content] OS_BRAIN_URL / INGEST_TOKEN unset: nothing generated');
    process.exit(3);
  }
  const config = JSON.parse(readFileSync(join(HERE, 'social.config.json'), 'utf8'));
  const now = Date.now();
  const max = Number(process.env.SOCIAL_MAX_DRAFTS || 8);
  const existing = new Set();
  let edits = [];
  let enabled = () => true;
  // the calendar/status reads are read-only, so a dry run with brain access skips the same slots a real run would
  const canRead = Boolean(process.env.OS_BRAIN_URL && process.env.INGEST_TOKEN);
  if (canRead) {
    const cal = await brain(`/social/calendar?from=${now}&to=${now + (config.horizonDays.max + 1) * DAY}`);
    if (cal.status !== 200) throw new Error(`calendar HTTP ${cal.status}`);
    for (const r of cal.body) existing.add(r.id);
    const e = await brain('/social/edits');
    edits = e.status === 200 ? e.body : [];
    // only generate for networks the brain can publish (LinkedIn stays off until its API is approved)
    const st = await brain('/social/status');
    if (st.status !== 200) throw new Error(`status HTTP ${st.status}`);
    enabled = (brand, network) => st.body?.brands?.[brand]?.networks?.[network]?.enabled === true;
  }
  const work = [
    ...edits.map((e) => ({ id: e.id, brand: e.brand, network: e.network, scheduledAt: e.scheduledAt, edit: { text: e.text, note: e.note } })),
    ...slotsFor(config, now).filter((s) => !existing.has(s.id) && enabled(s.brand, s.network)),
  ].slice(0, max);
  const skipped = slotsFor(config, now).filter((s) => existing.has(s.id)).length;
  // resource-frugal: nothing new to write = no model call, no render
  console.log(`[social-content] ${work.length} to write, ${skipped} slot(s) already drafted (skipped)${canRead ? '' : ' [no brain access: calendar not read]'}`);
  if (!work.length) return;
  let ok = 0;
  for (const w of work) {
    const b = config.brands[w.brand];
    let rejection = null;
    for (let attempt = 0; attempt < 2; attempt++) {
      try {
        const copy = generate(b, w.network, topicFor(b, w.id), w.edit, rejection);
        const draft = { id: w.id, brand: w.brand, network: w.network, scheduledAt: w.scheduledAt, text: copy.text.trim(), altText: copy.altText, imageBase64: render(b, copy), imageType: 'image/jpeg', origin: 'os' };
        if (dry) {
          console.log(JSON.stringify({ ...draft, imageBase64: `<${draft.imageBase64.length} b64 chars>` }));
          ok++;
          break;
        }
        const r = await brain('/social/drafts', { method: 'POST', body: JSON.stringify(draft) });
        if (r.status === 200) {
          ok++;
          console.log(`[social-content] ${w.id}: ${r.body.status} rev ${r.body.rev}`);
          break;
        }
        rejection = r.body?.error ?? `HTTP ${r.status}`;
        console.error(`[social-content] ${w.id}: refused (${rejection})`);
        if (r.status !== 400) break;
      } catch (e) {
        console.error(`[social-content] ${w.id}: ${e.message}`);
        break;
      }
    }
  }
  console.log(`[social-content] ${ok}/${work.length} drafts ${dry ? 'generated (dry run)' : 'submitted'}`);
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) main().catch((e) => { console.error(`[social-content] ${e.message}`); process.exit(1); });
