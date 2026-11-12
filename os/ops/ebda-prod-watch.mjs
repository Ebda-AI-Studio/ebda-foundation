#!/usr/bin/env node
// ebda-prod-watch - the off-Cloudflare production watch for the Ebda suite. Run by .github/workflows/prod-watch.yml on GitHub-hosted
// runners (not Cloudflare, not the Egyptian ISP), so it still alerts when every Ebda host and the brain Worker are down.
//
//   ebda-prod-watch.mjs [--mode watch|digest|drill] [--state FILE] [--config os/config/prod-watch.json] [--dry-run] [--now <ISO>]
//
// watch : probe every public host (os/config/prod-watch.json), read the last Logpush window from R2 (ebda-logs), evaluate the rules in
//         lib/ebda-logs-core.mjs, dedupe against --state, send P1s to Telegram, queue the rest for the digest; sends the daily digest on
//         the first run after 05:00 UTC.
// digest: send the digest now.   drill: send ONE test alert end to end and record the Telegram message id (exit 1 if not delivered).
//
// Env (values never printed):
//   required  TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID                      the alert path
//   required  EBDA_LOGS_CF_TOKEN (Account > Workers R2 Storage > Read), CLOUDFLARE_ACCOUNT_ID   the log rules
//   optional  EBDA_GH_READ_TOKEN (contents:read on the commitRepo repos)  deploy commit vs main in the digest
//   optional  EBDA_OS_BRAIN_URL + EBDA_OS_INGEST_TOKEN                     send the brain this run's complete alert listing (cleared alerts resolve)
// A missing REQUIRED secret never makes the run green: whatever can still run runs (probes first), the gap is written to the job summary
// and the process exits 1, so the workflow goes red and GitHub's failed-run mail is the fallback channel.
import { readFileSync, writeFileSync, existsSync, appendFileSync } from 'node:fs';
import { evaluateLogAlerts, evaluateProbeAlerts, decide, digestText, DEFAULT_RULES, LOG_ALERT_PREFIXES, brainListing, brainKind, messageScope } from './lib/ebda-logs-core.mjs';
import { listKeys, fetchRecords } from './lib/ebda-logs-r2.mjs';

const argv = process.argv.slice(2);
if (argv.includes('--help') || argv.includes('-h')) {
  console.log(readFileSync(new URL(import.meta.url), 'utf8').split('\n').slice(1, 20).map((l) => l.replace(/^\/\/ ?/, '')).join('\n'));
  process.exit(0);
}
const opt = (n, d) => { const i = argv.indexOf(`--${n}`); return i >= 0 ? argv[i + 1] : d; };
const mode = opt('mode', 'watch');
const statePath = opt('state', '.prod-watch-state.json');
const dry = argv.includes('--dry-run');
const now = opt('now') ? Date.parse(opt('now')) : Date.now();
const env = process.env;
const cfgPath = opt('config', new URL('../config/prod-watch.json', import.meta.url).pathname);
const cfg = JSON.parse(readFileSync(cfgPath, 'utf8'));
const runUrl = env.GITHUB_RUN_ID ? `${env.GITHUB_SERVER_URL}/${env.GITHUB_REPOSITORY}/actions/runs/${env.GITHUB_RUN_ID}` : 'local run';

const summary = [];
const gaps = [];
const say = (l) => { console.log(l); summary.push(l); };
const flushSummary = () => { if (env.GITHUB_STEP_SUMMARY) appendFileSync(env.GITHUB_STEP_SUMMARY, `${summary.join('\n')}\n`); };
const redact = (s) => String(s).replace(/bot\d+:[A-Za-z0-9_-]+/g, 'bot<redacted>');

if (!env.TELEGRAM_BOT_TOKEN || !env.TELEGRAM_CHAT_ID) gaps.push('TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID secret missing: NO alert can be delivered');
if (mode !== 'drill' && (!env.EBDA_LOGS_CF_TOKEN || !env.CLOUDFLARE_ACCOUNT_ID)) gaps.push('EBDA_LOGS_CF_TOKEN / CLOUDFLARE_ACCOUNT_ID missing: log rules (5xx, 429, exceptions, silent pipeline) are NOT running');

const state = existsSync(statePath) ? JSON.parse(readFileSync(statePath, 'utf8')) : {};

async function telegram(text) {
  if (dry) { console.log(`[dry-run telegram] ${text.split('\n')[0]}`); return { ok: true, messageId: 0 }; }
  if (!env.TELEGRAM_BOT_TOKEN || !env.TELEGRAM_CHAT_ID) return { ok: false, error: 'telegram secrets missing' };
  try {
    const r = await fetch(`https://api.telegram.org/bot${env.TELEGRAM_BOT_TOKEN}/sendMessage`, {
      method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ chat_id: env.TELEGRAM_CHAT_ID, text: text.slice(0, 3900), disable_web_page_preview: true }),
      signal: AbortSignal.timeout(15000),
    });
    const j = await r.json().catch(() => ({}));
    return j.ok ? { ok: true, messageId: j.result?.message_id } : { ok: false, error: `HTTP ${r.status} ${redact(j.description || '')}` };
  } catch (e) { return { ok: false, error: redact(e.message) }; }
}

// body: a plain finding list (the drill), or { findings, reconcile } = the complete listing of this run (brainListing)
async function brainFindings(body) {
  if (dry || !env.EBDA_OS_BRAIN_URL || !env.EBDA_OS_INGEST_TOKEN) return;
  try {
    const r = await fetch(`${env.EBDA_OS_BRAIN_URL.replace(/\/$/, '')}/findings`, { method: 'POST', headers: { authorization: `Bearer ${env.EBDA_OS_INGEST_TOKEN}`, 'content-type': 'application/json' }, body: JSON.stringify(body), signal: AbortSignal.timeout(10000) });
    const text = (await r.text()).slice(0, 200);
    say(`brain: POST /findings -> ${r.status} ${redact(text)}`);
    // the brain is the OS's single copy of production state: a refused report is a gap in this run's output, not silence
    if (!r.ok) gaps.push(`brain: POST /findings -> ${r.status}: the AI OS did not receive this run's state`);
  } catch (e) {
    say(`brain: POST /findings failed (${e.message}); Telegram is the primary path, the brain may itself be down`);
    gaps.push('brain: unreachable: the AI OS did not receive this run\'s state');
  }
}

async function brainHealthy() {
  if (!env.EBDA_OS_BRAIN_URL || dry) return false;
  try {
    const r = await fetch(`${env.EBDA_OS_BRAIN_URL.replace(/\/$/, '')}/health`, { signal: AbortSignal.timeout(5000) });
    return r.ok && (await r.json().catch(() => ({}))).ok === true;
  } catch { return false; }
}

async function probe(p) {
  const t0 = Date.now();
  try {
    const r = await fetch(p.url, { redirect: 'manual', headers: { 'user-agent': 'ebda-prod-watch/1 (+github-actions)' }, signal: AbortSignal.timeout(cfg.timeoutMs || 10000) });
    const body = await r.text();
    const ms = Date.now() - t0;
    let ok = r.status === (p.expect || 200);
    let error = ok ? undefined : `HTTP ${r.status}`;
    if (ok && p.contains && !new RegExp(p.contains).test(body)) { ok = false; error = 'body check failed'; }
    let commit;
    let json = null;
    if (p.commitRepo || p.fxMaxAgeHours) { try { json = JSON.parse(body); } catch { /* not json */ } }
    if (p.commitRepo) commit = json?.commit;
    const fx = p.fxMaxAgeHours ? { ageHours: json?.fxAgeHours ?? null, maxHours: p.fxMaxAgeHours, noDataUntil: p.fxNoDataUntil } : undefined;
    return { name: p.name, url: p.url, ok, status: r.status, ms, error, commit, commitRepo: p.commitRepo, fx };
  } catch (e) {
    return { name: p.name, url: p.url, ok: false, status: 0, ms: Date.now() - t0, error: e.name === 'TimeoutError' ? `timeout after ${cfg.timeoutMs || 10000}ms` : `network: ${e.message}` };
  }
}

async function mainTip(repo) {
  if (!env.EBDA_GH_READ_TOKEN) return null;
  try {
    const r = await fetch(`https://api.github.com/repos/${repo}/commits/main`, { headers: { authorization: `Bearer ${env.EBDA_GH_READ_TOKEN}`, accept: 'application/vnd.github+json' }, signal: AbortSignal.timeout(10000) });
    if (!r.ok) return null;
    const j = await r.json();
    return { sha: j.sha, at: Date.parse(j.commit?.committer?.date) };
  } catch { return null; }
}

async function commitLines(probes) {
  const lines = [];
  const tips = {};
  for (const p of probes.filter((x) => x.commitRepo)) {
    tips[p.commitRepo] ??= await mainTip(p.commitRepo);
    const tip = tips[p.commitRepo];
    const c = p.commit ? String(p.commit).slice(0, 9) : '?';
    lines.push(`- ${p.name}: live ${c}${tip ? (tip.sha.startsWith(String(p.commit || '-')) ? ' = main' : ` vs main ${tip.sha.slice(0, 9)} (path-filtered deploys may lag)`) : ' (main tip unread: EBDA_GH_READ_TOKEN unset)'}`);
  }
  return lines;
}

async function runDigest(probes) {
  const ps = state.probeStats || {};
  const lines = ['', 'Probes since the last digest (ok/total):', ...Object.entries(ps).map(([k, v]) => `- ${k}: ${v.ok}/${v.total}${v.ok < v.total ? ` (worst ${v.worstMs} ms)` : ''}`)];
  lines.push('', 'Deployed commits:', ...(await commitLines(probes)));
  if (gaps.length) lines.push('', 'WATCH GAPS:', ...gaps.map((g) => `- ${g}`));
  const r = await telegram(digestText(state, lines));
  say(`digest: ${r.ok ? `sent (message ${r.messageId})` : `NOT sent: ${r.error}`}`);
  if (r.ok) { state.digest = []; state.probeStats = {}; state.lastDigest = new Date(now).toISOString().slice(0, 10); }
  return r.ok;
}

let failed = false;
say(`## ebda prod watch (${mode}) ${new Date(now).toISOString()}`);

if (mode === 'drill') {
  const r = await telegram(`DRILL: Ebda prod-watch end-to-end alert test. No action needed. ${new Date(now).toISOString()} ${runUrl}`);
  state.drills = [...(state.drills || []), { at: new Date(now).toISOString(), delivered: r.ok, messageId: r.messageId ?? null, error: r.error ?? null, run: runUrl }].slice(-20);
  say(r.ok ? `drill: DELIVERED, Telegram message_id ${r.messageId}` : `drill: NOT delivered: ${r.error}`);
  const drillKey = `alert-drill:${new Date(now).toISOString().slice(0, 10)}`;
  await brainFindings([{ source: 'prod-watch', kind: brainKind(drillKey), key: drillKey, severity: 'P3', title: `alert drill ${r.ok ? 'delivered' : 'FAILED'}` }]);
  failed = !r.ok;
} else {
  const probes = await Promise.all(cfg.probes.map(probe));
  say('| probe | ok | status | ms | note |\n|---|---|---|---|---|');
  for (const p of probes) say(`| ${p.name} | ${p.ok ? 'yes' : '**NO**'} | ${p.status} | ${p.ms} | ${p.error || ''} |`);
  const ps = state.probeStats || {};
  for (const p of probes) { const v = ps[p.name] || { ok: 0, total: 0, worstMs: 0 }; v.total++; if (p.ok) v.ok++; else v.worstMs = Math.max(v.worstMs, p.ms); ps[p.name] = v; }
  state.probeStats = ps;
  const pr = evaluateProbeAlerts(probes, state, Number(env.PROBE_FAIL_BUDGET || 2));
  state.streaks = pr.streaks;
  let alerts = [...pr.alerts];
  let logsRead = false;

  if (env.EBDA_LOGS_CF_TOKEN && env.CLOUDFLARE_ACCOUNT_ID) {
    const lag = 5 * 60000; // Logpush batches land a few minutes late
    const to = now - lag;
    const silenceFrom = to - DEFAULT_RULES.silenceMinutes * 60000;
    const winFrom = to - 15 * 60000;
    try {
      const keys = await listKeys({ token: env.EBDA_LOGS_CF_TOKEN, account: env.CLOUDFLARE_ACCOUNT_ID, fromMs: silenceFrom, toMs: to + lag });
      const { records, failed: unread } = await fetchRecords({ token: env.EBDA_LOGS_CF_TOKEN, account: env.CLOUDFLARE_ACCOUNT_ID, keys, concurrency: 6 });
      const silence = records.filter((r) => r.EventTimestampMs >= silenceFrom && r.EventTimestampMs <= to);
      const win = silence.filter((r) => r.EventTimestampMs >= winFrom);
      say(`logs: ${keys.length} objects (${unread} unreadable), ${win.length} records in the 15-min window, ${silence.length} in ${DEFAULT_RULES.silenceMinutes} min`);
      if (unread > keys.length / 2) gaps.push(`logs: ${unread}/${keys.length} objects unreadable`);
      alerts = alerts.concat(evaluateLogAlerts(win, silence, DEFAULT_RULES));
      logsRead = unread <= keys.length / 2;
    } catch (e) {
      gaps.push(`logs: cannot read R2 (${redact(e.message).slice(0, 160)}): the log rules did not run`);
    }
  }
  for (const a of alerts) say(`alert ${a.severity} ${a.key}: ${a.title}${a.detail ? ` | ${a.detail}` : ''}`);
  if (!alerts.length) say('no alert conditions');

  // AIOS-7: while the brain answers, its cron owns the probe alerts; this run messages them only when the brain is down
  const brainUp = await brainHealthy();
  const scope = messageScope(alerts, { brainUp, logsRead });
  say(`brain: ${brainUp ? 'up, it messages the probe alerts' : 'NOT answering: this run messages the probe alerts too'}`);
  const d = decide(scope.alerts, state, now, { unknownPrefixes: scope.unknownPrefixes });
  Object.assign(state, d.state);
  for (const m of d.messages) {
    const r = await telegram(`${m}\n${runUrl}`);
    say(`telegram: ${r.ok ? `sent ${r.messageId}` : `FAILED ${r.error}`} <- ${m.split('\n')[0]}`);
    if (!r.ok) failed = true;
  }
  await brainFindings(brainListing(alerts, { logsRead }));
  const hourUtc = new Date(now).getUTCHours();
  if (mode === 'digest' || (state.lastDigest !== new Date(now).toISOString().slice(0, 10) && hourUtc >= 5)) {
    if (!(await runDigest(probes))) failed = true;
  }
  // A firing P1 that could not be delivered must not end green.
  if (alerts.some((a) => a.severity === 'P1') && (!env.TELEGRAM_BOT_TOKEN || !env.TELEGRAM_CHAT_ID)) failed = true;
}

for (const g of gaps) say(`GAP: ${g}`);
if (gaps.length) failed = true;
if (!dry || argv.includes('--write-state')) writeFileSync(statePath, JSON.stringify(state));
flushSummary();
process.exit(failed ? 1 : 0);
