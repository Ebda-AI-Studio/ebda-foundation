// ebda-logs-core.mjs - pure helpers behind os/ops/ebda-logs.mjs (reader) and os/ops/ebda-prod-watch.mjs (alert job).
// No I/O here: everything takes data in and returns data, so os/ops/tests/ebda-logs.test.mjs can drive it with fixtures.
//
// Record shape (Cloudflare Logpush, dataset workers_trace_events, as written to R2 bucket ebda-logs):
//   { ScriptName, Outcome, EventTimestampMs, Exceptions:[{Name,Message,TimestampMs}], Logs:[{Level,Message:[...],TimestampMs}],
//     Event: { Request:{URL,Method}, Response:{Status}, RayID } | { RPCMethod } | { Cron, ScheduledTimeMs } | { Queue, BatchSize } }
// The job's field list carries no CPUTimeMs / WallTimeMs today; timings() reports them only when present.

/** Object keys look like workers/20261110/20261110T000047Z_20261110T000150Z_7b91ed37.log.gz. Returns {startMs,endMs} or null. */
export function parseKeyWindow(key) {
  const m = /(\d{8}T\d{6}Z)_(\d{8}T\d{6}Z)_/.exec(key);
  if (!m) return null;
  const t = (s) => Date.UTC(+s.slice(0, 4), +s.slice(4, 6) - 1, +s.slice(6, 8), +s.slice(9, 11), +s.slice(11, 13), +s.slice(13, 15));
  return { startMs: t(m[1]), endMs: t(m[2]) };
}

/** The daily prefixes (workers/YYYYMMDD/) a [fromMs, toMs] window touches. Logpush files by batch END date, so one day of slack. */
export function dayPrefixes(fromMs, toMs, root = 'workers/') {
  const out = [];
  const day = 86400000;
  for (let t = Math.floor(fromMs / day) * day; t <= toMs + day; t += day) {
    const d = new Date(t);
    out.push(`${root}${d.getUTCFullYear()}${String(d.getUTCMonth() + 1).padStart(2, '0')}${String(d.getUTCDate()).padStart(2, '0')}/`);
  }
  return out;
}

/** Keep keys whose batch window overlaps [fromMs, toMs]; keys without a parsable window are kept (filtered later per record). */
export function keysInWindow(keys, fromMs, toMs) {
  return keys.filter((k) => {
    const w = parseKeyWindow(k);
    return !w || (w.endMs >= fromMs && w.startMs <= toMs);
  });
}

/** Parse NDJSON text into records; bad lines are counted, never thrown. */
export function parseNdjson(text) {
  const records = [];
  let bad = 0;
  for (const line of text.split('\n')) {
    if (!line.trim()) continue;
    try { records.push(JSON.parse(line)); } catch { bad++; }
  }
  return { records, bad };
}

export function eventKind(r) {
  const e = r.Event || {};
  if (e.Request) return 'fetch';
  if (e.RPCMethod) return 'rpc';
  if (e.Cron !== undefined || e.ScheduledTimeMs !== undefined) return 'scheduled';
  if (e.Queue !== undefined || e.BatchSize !== undefined) return 'queue';
  if (e.Alarm !== undefined || e.ScheduledTime !== undefined) return 'alarm';
  return 'other';
}

/** Collapse ids so paths group: uuids, long hex, numbers, and long opaque tokens become :id. Query strings are dropped. */
export function normalizePath(url) {
  let host = '';
  let path = url || '';
  try { const u = new URL(url); host = u.host; path = u.pathname; } catch { /* keep raw */ }
  path = path
    .split('/')
    .map((s) => (/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(s) || /^[0-9a-f]{16,}$/i.test(s) || /^\d{2,}$/.test(s) || /^[A-Za-z0-9_-]{24,}$/.test(s) ? ':id' : s))
    .join('/');
  return { host, path };
}

export function statusClass(s) {
  if (typeof s !== 'number' || s <= 0) return 'none';
  return `${Math.floor(s / 100)}xx`;
}

/** Does a record pass the CLI filters? f = {script?, status?, path?} ; status accepts 429, 5xx, 4xx. */
export function matches(r, f = {}) {
  if (f.script && !String(f.script).split(',').includes(r.ScriptName)) return false;
  if (f.status) {
    const s = r.Event?.Response?.Status;
    const want = String(f.status);
    if (/^\dxx$/.test(want) ? statusClass(s) !== want : String(s) !== want) return false;
  }
  if (f.path) {
    const url = r.Event?.Request?.URL || '';
    if (!url.includes(f.path)) return false;
  }
  if (f.fromMs !== undefined && r.EventTimestampMs < f.fromMs) return false;
  if (f.toMs !== undefined && r.EventTimestampMs > f.toMs) return false;
  return true;
}

const inc = (m, k, n = 1) => m.set(k, (m.get(k) || 0) + n);

function pct(sorted, p) {
  if (!sorted.length) return null;
  return sorted[Math.min(sorted.length - 1, Math.floor((p / 100) * sorted.length))];
}

/** One pass over records -> aggregates. Maps are returned as sorted arrays so callers can print or JSON them. */
export function aggregate(records) {
  const scripts = new Map();
  const kinds = new Map();
  const outcomes = new Map();
  const byScriptStatus = new Map();
  const errPaths = new Map(); // `${status}|${script}|${host}${path}`
  const exceptions = new Map();
  const errorLogs = new Map();
  const rpc = new Map();
  const rays = new Map(); // RayID -> Set(script)
  const cpu = [];
  const wall = [];
  let minTs = Infinity;
  let maxTs = -Infinity;
  for (const r of records) {
    const s = r.ScriptName || '(none)';
    const k = eventKind(r);
    inc(scripts, s);
    inc(kinds, `${s}|${k}`);
    inc(outcomes, `${s}|${r.Outcome || '?'}`);
    if (r.EventTimestampMs < minTs) minTs = r.EventTimestampMs;
    if (r.EventTimestampMs > maxTs) maxTs = r.EventTimestampMs;
    if (k === 'fetch') {
      const st = r.Event.Response?.Status;
      inc(byScriptStatus, `${s}|${st ?? 'none'}`);
      if (st === 429 || st >= 500 || st === undefined) {
        const { host, path } = normalizePath(r.Event.Request.URL);
        inc(errPaths, `${st ?? 'none'}|${s}|${host}${path}`);
      }
    }
    if (k === 'rpc') inc(rpc, `${s}|${r.Event.RPCMethod}`);
    const ray = r.Event?.RayID;
    if (ray) { if (!rays.has(ray)) rays.set(ray, new Set()); rays.get(ray).add(s); }
    for (const e of r.Exceptions || []) inc(exceptions, `${s}|${e.Name || 'Error'}: ${String(e.Message || '').slice(0, 140)}`);
    for (const l of r.Logs || []) {
      if (l.Level === 'error' || l.Level === 'warn') inc(errorLogs, `${s}|${l.Level}|${(Array.isArray(l.Message) ? l.Message.join(' ') : String(l.Message || '')).slice(0, 140)}`);
    }
    if (typeof r.CPUTimeMs === 'number') cpu.push(r.CPUTimeMs);
    if (typeof r.WallTimeMs === 'number') wall.push(r.WallTimeMs);
  }
  const sorted = (m) => [...m.entries()].sort((a, b) => b[1] - a[1]);
  cpu.sort((a, b) => a - b);
  wall.sort((a, b) => a - b);
  return {
    total: records.length,
    window: { fromMs: Number.isFinite(minTs) ? minTs : null, toMs: Number.isFinite(maxTs) ? maxTs : null },
    scripts: sorted(scripts),
    kinds: sorted(kinds),
    outcomes: sorted(outcomes),
    byScriptStatus: sorted(byScriptStatus),
    errPaths: sorted(errPaths),
    exceptions: sorted(exceptions),
    errorLogs: sorted(errorLogs),
    rpc: sorted(rpc),
    rays,
    timings: {
      cpu: cpu.length ? { n: cpu.length, p50: pct(cpu, 50), p95: pct(cpu, 95) } : null,
      wall: wall.length ? { n: wall.length, p50: pct(wall, 50), p95: pct(wall, 95) } : null,
    },
  };
}

/**
 * For records of `script` with `status`, which OTHER scripts share their RayID (the caller, when one Worker calls another through a
 * service binding inside the same request). Returns [[callerOrDirect, count]].
 */
export function callers(records, agg, script, status) {
  const m = new Map();
  for (const r of records) {
    if (r.ScriptName !== script || eventKind(r) !== 'fetch' || r.Event.Response?.Status !== status) continue;
    const peers = [...(agg.rays.get(r.Event.RayID) || [])].filter((x) => x !== script);
    inc(m, peers.length ? peers.sort().join('+') : 'direct (no peer in the logs)');
  }
  return [...m.entries()].sort((a, b) => b[1] - a[1]);
}

/** Bucket fetch events by minute for one script: [[isoMinute, {total, s5xx, s429}]]. */
export function perMinute(records, script) {
  const m = new Map();
  for (const r of records) {
    if (r.ScriptName !== script || eventKind(r) !== 'fetch') continue;
    const k = new Date(Math.floor(r.EventTimestampMs / 60000) * 60000).toISOString().slice(0, 16);
    const v = m.get(k) || { total: 0, s5xx: 0, s429: 0 };
    v.total++;
    const st = r.Event.Response?.Status;
    if (st >= 500) v.s5xx++;
    if (st === 429) v.s429++;
    m.set(k, v);
  }
  return [...m.entries()].sort();
}

// ----------------------------------------------------------------------------------------------------------------------------
// Alert rules (os/ops/ebda-prod-watch.mjs). Thresholds live in DEFAULT_RULES; the job may override them from env.

/** Key prefixes the log rules own (kept open, not resolved, when the logs could not be read). */
export const LOG_ALERT_PREFIXES = ['storefront-5xx', 'api-429', 'exceptions:', 'logs-silent:'];

export const DEFAULT_RULES = {
  storefrontScript: 'ebda-web',
  apiScript: 'ebda-api',
  storefront5xxMin: 5, // at least this many 5xx in the window ...
  storefront5xxRate: 0.02, // ... and at least this share of storefront fetches
  api429Min: 3, // any 429 from the API this many times in the window
  api429P1: 20, // ... P1 at this many
  exceptionsMin: 10, // non-ok outcomes (exception, exceededCpu, ...) per script per window
  // Workers that always log (crons every few minutes): zero records for silenceMinutes = a dead pipeline or a dead Worker.
  alwaysActive: ['ebda-api', 'ebda-status'],
  silenceMinutes: 30,
};

/**
 * Evaluate log-based alerts. `windowRecords` = the last window (e.g. 15 min); `silenceRecords` = the last silenceMinutes.
 * Returns [{key, severity:'P1'|'P2', title, detail}]; the key is stable so the dedupe state can hold it.
 */
export function evaluateLogAlerts(windowRecords, silenceRecords, rules = DEFAULT_RULES) {
  const out = [];
  const agg = aggregate(windowRecords);
  const fetchOf = (script) => agg.byScriptStatus.filter(([k]) => k.startsWith(`${script}|`));
  const sf = fetchOf(rules.storefrontScript);
  const sfTotal = sf.reduce((n, [, c]) => n + c, 0);
  const sf5xx = sf.filter(([k]) => /\|5\d\d$/.test(k)).reduce((n, [, c]) => n + c, 0);
  if (sf5xx >= rules.storefront5xxMin && sfTotal > 0 && sf5xx / sfTotal >= rules.storefront5xxRate) {
    const top = agg.errPaths.filter(([k]) => k.startsWith('5') && k.includes(`|${rules.storefrontScript}|`)).slice(0, 3).map(([k, c]) => `${c}x ${k.split('|')[2]}`);
    out.push({ key: 'storefront-5xx', severity: 'P1', title: `storefront 5xx: ${sf5xx}/${sfTotal} (${Math.round((100 * sf5xx) / sfTotal)}%)`, detail: top.join('; ') });
  }
  const api429 = fetchOf(rules.apiScript).filter(([k]) => k.endsWith('|429')).reduce((n, [, c]) => n + c, 0);
  if (api429 >= rules.api429Min) {
    const top = agg.errPaths.filter(([k]) => k.startsWith('429|')).slice(0, 3).map(([k, c]) => `${c}x ${k.split('|')[2]}`);
    const who = callers(windowRecords, agg, rules.apiScript, 429).slice(0, 2).map(([k, c]) => `${c} from ${k}`);
    out.push({ key: 'api-429', severity: api429 >= rules.api429P1 ? 'P1' : 'P2', title: `API answered 429 ${api429}x`, detail: [...top, ...who].join('; ') });
  }
  const bad = new Map();
  for (const [k, c] of agg.outcomes) {
    const [s, o] = k.split('|');
    if (o !== 'ok' && o !== 'canceled') bad.set(s, (bad.get(s) || 0) + c);
  }
  for (const [s, c] of bad) {
    if (c < rules.exceptionsMin) continue;
    const ex = agg.exceptions.filter(([k]) => k.startsWith(`${s}|`)).slice(0, 2).map(([k, n]) => `${n}x ${k.slice(s.length + 1)}`);
    out.push({ key: `exceptions:${s}`, severity: 'P1', title: `${s}: ${c} failed invocations`, detail: ex.join('; ') });
  }
  const seen = new Set(silenceRecords.map((r) => r.ScriptName));
  if (silenceRecords.length === 0) {
    out.push({ key: 'logs-silent:all', severity: 'P1', title: `no Worker logs at all in ${rules.silenceMinutes} min (Logpush job or R2 sink dead)`, detail: 'bucket ebda-logs, prefix workers/' });
  } else {
    for (const s of rules.alwaysActive) {
      if (!seen.has(s)) out.push({ key: `logs-silent:${s}`, severity: 'P1', title: `${s}: zero log records in ${rules.silenceMinutes} min`, detail: 'its crons always log; the Worker or its logpush flag is gone' });
    }
  }
  return out;
}

/**
 * Probe results -> alerts. probes = [{name, url, ok, status, ms, error?, commit?}]. A probe alerts after `failBudget` consecutive fails
 * (streaks live in state.streaks). Every probe down at once = one 'probe:all' P1 instead of N messages.
 */
export function evaluateProbeAlerts(probes, state, failBudget = 2, nowMs = Date.now()) {
  const streaks = { ...(state.streaks || {}) };
  const failing = [];
  for (const p of probes) {
    streaks[p.name] = p.ok ? 0 : (streaks[p.name] || 0) + 1;
    if (!p.ok && streaks[p.name] >= failBudget) failing.push(p);
  }
  const alerts = [];
  if (probes.length > 0 && failing.length === probes.length) {
    alerts.push({ key: 'probe:all', severity: 'P1', title: `every Ebda host is failing (${probes.length}/${probes.length}) from outside Cloudflare`, detail: failing.slice(0, 4).map((p) => `${p.name}: ${p.error || p.status}`).join('; ') });
  } else {
    for (const p of failing) alerts.push({ key: `probe:${p.name}`, severity: 'P1', title: `${p.name} down (${p.error || `HTTP ${p.status}`}, ${streaks[p.name]} checks in a row)`, detail: p.url });
  }
  // a failed probe says nothing about its FX age: that key is UNKNOWN (stays open, never "resolved"), like unknownPrefixes
  const unknownKeys = [];
  for (const p of probes) {
    if (p.fx && !p.ok) { unknownKeys.push(`probe:${p.name}-fx`); continue; }
    const a = fxStaleAlert(p, nowMs);
    if (a) alerts.push(a);
  }
  return { alerts, streaks, unknownKeys };
}

/**
 * External watchdog for a daily-cron value (Ebda Chat FX rate, 2026-11-12). The worker alarms on staleness itself, but that alarm cannot
 * fire when its own cron is dead, so the outside probe reads /health `fxAgeHours` too. p.fx = { ageHours, maxHours, noDataUntil } is
 * set by the prober only for a probe configured with fxMaxAgeHours. Alerts (P1, key probe:<name>-fx, deduped by decide()) when
 * ageHours > maxHours; a null/missing age is "no data yet" and alerts only from noDataUntil (ISO) on. A probe that itself failed says
 * nothing about FX: evaluateProbeAlerts reports its key in `unknownKeys` so decide() keeps it open (no false "resolved").
 */
export function fxStaleAlert(p, nowMs) {
  if (!p.fx || !p.ok) return null;
  const { ageHours, maxHours, noDataUntil } = p.fx;
  // a malformed noDataUntil must not silently disable the alert: no grace period, and say so
  const graceOk = !noDataUntil || !Number.isNaN(Date.parse(noDataUntil));
  if (!graceOk) console.error(`prod-watch: ${p.name} fxNoDataUntil "${noDataUntil}" is not a date; no grace period applied`);
  const key = `probe:${p.name}-fx`;
  if (ageHours === null || ageHours === undefined || Number.isNaN(Number(ageHours))) {
    if (noDataUntil && graceOk && !(nowMs >= Date.parse(noDataUntil))) return null;
    return { key, severity: 'P1', title: `${p.name} FX rate has no observation (fxAgeHours null after ${noDataUntil}): the daily FX cron never wrote a row`, detail: p.url };
  }
  if (Number(ageHours) <= maxHours) return null;
  return { key, severity: 'P1', title: `${p.name} FX rate is stale (${Number(ageHours).toFixed(1)} h old, limit ${maxHours} h): the daily FX cron is not running`, detail: p.url };
}

/**
 * Dedupe + budget. state = {sent:{key:{first,last,n}}, day:{date,count}, open:[keys]}. Policy (Ahmad 2026-11-05: Telegram only for an
 * unhealed P1 + ONE daily digest):
 *   - a P1 key sends once when it opens, re-sends only after `repeatMs` while still firing, sends one "resolved" when it clears;
 *   - P2 never messages: it is listed in the digest;
 *   - a key whose source could not be read this run (`unknownPrefixes`) stays open: unknown never resolves;
 *   - at most `dailyBudget` messages a day; past it, alerts fold into the digest (the 'probe:all' P1 is exempt: an outage always gets through).
 * Returns {messages:[text], digestItems:[alert], state}.
 */
export const KEY_REPEAT_MS = { 'probe:wa-fx': 24 * 3600000 }; // a stale daily value re-pages once a day, not every 6 h, so it cannot eat the budget
export function decide(alerts, state, nowMs, { repeatMs = 6 * 3600000, dailyBudget = 6, unknownPrefixes = [], unknownKeys = [], keyRepeatMs = KEY_REPEAT_MS } = {}) {
  const st = { sent: { ...(state.sent || {}) }, day: { ...(state.day || {}) }, open: [...(state.open || [])], digest: [...(state.digest || [])] };
  const today = new Date(nowMs).toISOString().slice(0, 10);
  if (st.day.date !== today) st.day = { date: today, count: 0 };
  const messages = [];
  const firing = new Set(alerts.map((a) => a.key));
  const send = (text, exempt) => {
    if (!exempt && st.day.count >= dailyBudget) return false;
    messages.push(text);
    st.day.count++;
    return true;
  };
  for (const a of alerts) {
    const prev = st.sent[a.key];
    if (a.severity !== 'P1') {
      if (!st.digest.some((d) => d.key === a.key)) st.digest.push({ key: a.key, title: a.title, at: nowMs });
      continue;
    }
    const due = !prev || !st.open.includes(a.key) || nowMs - prev.last >= (keyRepeatMs[a.key] ?? repeatMs);
    if (!due) continue;
    const text = `P1 ${a.title}${a.detail ? `\n${a.detail}` : ''}`;
    if (send(text, a.key === 'probe:all')) st.sent[a.key] = { first: prev && st.open.includes(a.key) ? prev.first : nowMs, last: nowMs, n: (prev?.n || 0) + 1 };
    else st.digest.push({ key: a.key, title: `(over budget) ${a.title}`, at: nowMs });
    if (!st.open.includes(a.key)) st.open.push(a.key);
  }
  for (const k of [...st.open]) {
    if (firing.has(k)) continue;
    if (unknownKeys.includes(k) || unknownPrefixes.some((p) => k.startsWith(p))) continue; // its source was unreadable this run: unknown is not resolved
    st.open = st.open.filter((x) => x !== k);
    if (st.sent[k]) send(`resolved: ${k}`, false);
  }
  return { messages, state: st };
}

/** The once-a-day digest text, then the digest list empties. */
export function digestText(state, extraLines = []) {
  const items = state.digest || [];
  const lines = [`Ebda prod watch, daily digest ${new Date().toISOString().slice(0, 10)}`];
  lines.push(items.length ? `${items.length} non-paging item(s) in the last 24 h:` : 'No non-paging items in the last 24 h.');
  for (const d of items.slice(0, 15)) lines.push(`- ${d.title}`);
  if (items.length > 15) lines.push(`- ... and ${items.length - 15} more`);
  return [...lines, ...extraLines].join('\n');
}

// ---------- the brain's copy of production state (HANDS-COORD / AI OS primary operator, 2026-11-10) ----------
// prod-watch alerts become brain findings with the brain's own kinds. Probe failures are 'prod-outage' (the brain's outage class);
// log rules get a 'prod-' kind so the brain treats them as code problems; the drill is digest-only.
const BRAIN_KIND = [
  ['probe:', 'prod-outage'],
  ['storefront-5xx', 'prod-5xx'],
  ['api-429', 'prod-429'],
  ['exceptions:', 'prod-exception'],
  ['logs-silent:', 'prod-logs-silent'],
  ['alert-drill:', 'alert-drill'],
];
export function brainKind(key) {
  const hit = BRAIN_KIND.find(([p]) => key === p || key.startsWith(p));
  return hit ? hit[1] : `prod-${String(key).split(':')[0]}`;
}

/**
 * The COMPLETE listing prod-watch sends to the brain each run: { findings, reconcile }. A key absent from the listing resolves in the
 * brain, except under reconcile.keep: when the logs could not be read, the log rules said nothing, so their findings stay as they are.
 */
export function brainListing(alerts, { logsRead }) {
  const findings = alerts.map((a) => ({
    source: 'prod-watch',
    kind: brainKind(a.key),
    key: a.key,
    title: String(a.title).slice(0, 500),
    ...(a.severity ? { severity: a.severity } : {}),
    ...(a.detail ? { detail: { text: String(a.detail).slice(0, 2000) } } : {}),
  }));
  return { findings, reconcile: { source: 'prod-watch', ...(logsRead ? {} : { keep: [...LOG_ALERT_PREFIXES] }) } };
}

/**
 * Which alerts THIS GitHub-hosted run messages (ruling AIOS-7). The brain's cron owns the probe alerts while it answers; this run then
 * messages only what the brain cannot see (the R2 log rules) and leaves the probe keys untouched in its own state. When the brain does
 * not answer (a Cloudflare-wide failure takes it down with what it watches), this run messages the probe alerts too.
 */
export function messageScope(alerts, { brainUp, logsRead }) {
  return {
    alerts: brainUp ? alerts.filter((a) => !a.key.startsWith('probe:')) : alerts,
    unknownPrefixes: [...(logsRead ? [] : LOG_ALERT_PREFIXES), ...(brainUp ? ['probe:'] : [])],
  };
}
