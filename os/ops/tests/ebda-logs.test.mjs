// Fixture tests for lib/ebda-logs-core.mjs: the aggregates the reader prints, and the alert rules + dedupe the prod watch runs.
// Each rule has a fixture that MUST fire and one that must NOT.
import assert from 'node:assert';
import {
  parseKeyWindow, keysInWindow, dayPrefixes, normalizePath, matches, aggregate, callers,
  evaluateLogAlerts, evaluateProbeAlerts, decide, digestText, DEFAULT_RULES, LOG_ALERT_PREFIXES, brainListing, brainKind,
} from '../lib/ebda-logs-core.mjs';

const T0 = Date.UTC(2026, 10, 10, 12, 0, 0);
let ray = 0;
const fetchRec = (script, url, status, o = {}) => ({ ScriptName: script, Outcome: o.outcome || 'ok', EventTimestampMs: o.ts ?? T0, Exceptions: o.ex || [], Logs: o.logs || [], Event: { RayID: o.ray || `r${ray++}`, Request: { URL: url, Method: 'GET' }, Response: { Status: status } } });
const cronRec = (script, ts = T0) => ({ ScriptName: script, Outcome: 'ok', EventTimestampMs: ts, Exceptions: [], Logs: [], Event: { Cron: '* * * * *', ScheduledTimeMs: ts } });
const rpcRec = (script, m) => ({ ScriptName: script, Outcome: 'ok', EventTimestampMs: T0, Exceptions: [], Logs: [], Event: { RPCMethod: m } });
const heartbeat = [cronRec('ebda-api'), cronRec('ebda-status')];
const many = (n, f) => Array.from({ length: n }, (_, i) => f(i));

// --- keys and windows
const w = parseKeyWindow('workers/20261110/20261110T000047Z_20261110T000150Z_7b91ed37.log.gz');
assert.equal(w.startMs, Date.UTC(2026, 10, 10, 0, 0, 47));
assert.equal(w.endMs, Date.UTC(2026, 10, 10, 0, 1, 50));
assert.equal(parseKeyWindow('workers/x.log'), null);
assert.deepEqual(keysInWindow(['workers/20261110/20261110T000047Z_20261110T000150Z_a.log.gz', 'workers/20261110/20261110T050000Z_20261110T050100Z_b.log.gz'], Date.UTC(2026, 10, 10, 0, 1), Date.UTC(2026, 10, 10, 0, 2)).length, 1);
assert.deepEqual(dayPrefixes(Date.UTC(2026, 10, 9, 23), Date.UTC(2026, 10, 10, 1)), ['workers/20261109/', 'workers/20261110/', 'workers/20261111/']);

// --- path normalisation and filters
assert.equal(normalizePath('https://api.ebda.app/api/v1/public/products/123456?x=1').path, '/api/v1/public/products/:id');
assert.equal(normalizePath('https://a.b/stores/0b9b8f8e-1111-2222-3333-444455556666/layout').path, '/stores/:id/layout');
assert.equal(normalizePath('https://a.b/products/mahshi-koronb').path, '/products/mahshi-koronb');
const r429 = fetchRec('ebda-api', 'https://api.ebda.app/api/v1/public/store/resolve?host=x', 429);
assert.ok(matches(r429, { status: '429' }));
assert.ok(matches(r429, { status: '4xx', script: 'ebda-web,ebda-api', path: '/store/resolve' }));
assert.ok(!matches(r429, { status: '5xx' }));
assert.ok(!matches(r429, { script: 'ebda-web' }));

// --- aggregate
const mix = [r429, fetchRec('ebda-web', 'https://s.ebda.app/', 500, { ex: [{ Name: 'Error', Message: 'boom' }], logs: [{ Level: 'error', Message: ['Failed to fetch store for domain s.ebda.app: 429'] }] }), rpcRec('ebda-api', 'apply'), cronRec('ebda-status')];
const a = aggregate(mix);
assert.equal(a.total, 4);
assert.deepEqual(a.byScriptStatus.find(([k]) => k === 'ebda-api|429'), ['ebda-api|429', 1]);
assert.equal(a.errPaths.length, 2);
assert.deepEqual(a.errPaths.find(([k]) => k.startsWith('429')), ['429|ebda-api|api.ebda.app/api/v1/public/store/resolve', 1]);
assert.equal(a.exceptions[0][0], 'ebda-web|Error: boom');
assert.equal(a.errorLogs.length, 1);
assert.deepEqual(a.rpc, [['ebda-api|apply', 1]]);
assert.equal(a.timings.cpu, null);
const timed = aggregate([{ ...cronRec('x'), CPUTimeMs: 3, WallTimeMs: 40 }, { ...cronRec('x'), CPUTimeMs: 9, WallTimeMs: 90 }]);
assert.equal(timed.timings.cpu.p95, 9);

// --- callers by shared RayID
const shared = [fetchRec('ebda-web', 'https://s.ebda.app/', 500, { ray: 'R1' }), fetchRec('ebda-api', 'https://api.ebda.app/api/v1/public/store/resolve', 429, { ray: 'R1' }), fetchRec('ebda-api', 'https://api.ebda.app/x', 429, { ray: 'R2' })];
assert.deepEqual(Object.fromEntries(callers(shared, aggregate(shared), 'ebda-api', 429)), { 'ebda-web': 1, 'direct (no peer in the logs)': 1 });

// --- rule: storefront 5xx
const sf5xx = [...heartbeat, ...many(90, (i) => fetchRec('ebda-web', 'https://s.ebda.app/', 200)), ...many(10, () => fetchRec('ebda-web', 'https://s.ebda.app/', 500))];
assert.ok(evaluateLogAlerts(sf5xx, sf5xx).some((x) => x.key === 'storefront-5xx' && x.severity === 'P1'), 'MUST fire: 10% storefront 5xx');
const sfFew = [...heartbeat, ...many(500, () => fetchRec('ebda-web', 'https://s.ebda.app/', 200)), ...many(6, () => fetchRec('ebda-web', 'https://s.ebda.app/', 500))];
assert.ok(!evaluateLogAlerts(sfFew, sfFew).some((x) => x.key === 'storefront-5xx'), 'must NOT fire: 6/506 (1.2%) under the 2% rate');
const sf4 = [...heartbeat, ...many(4, () => fetchRec('ebda-web', 'https://s.ebda.app/', 500))];
assert.ok(!evaluateLogAlerts(sf4, sf4).some((x) => x.key === 'storefront-5xx'), 'must NOT fire: 4 errors is under the minimum count');

// --- rule: API 429
const api429 = [...heartbeat, ...many(5, () => fetchRec('ebda-api', 'https://api.ebda.app/api/v1/public/store/resolve', 429))];
const a429 = evaluateLogAlerts(api429, api429).find((x) => x.key === 'api-429');
assert.ok(a429 && a429.severity === 'P2', 'MUST fire as P2: 5 x 429');
assert.match(a429.detail, /store\/resolve/);
const api429many = [...heartbeat, ...many(25, () => fetchRec('ebda-api', 'https://api.ebda.app/api/v1/public/products', 429))];
assert.equal(evaluateLogAlerts(api429many, api429many).find((x) => x.key === 'api-429').severity, 'P1', 'MUST escalate to P1 at 20+');
const api429two = [...heartbeat, ...many(2, () => fetchRec('ebda-api', 'https://api.ebda.app/x', 429))];
assert.ok(!evaluateLogAlerts(api429two, api429two).some((x) => x.key === 'api-429'), 'must NOT fire: 2 x 429');

// --- rule: exception spike (non-ok outcomes; canceled is a client hang-up, not an exception)
const exc = [...heartbeat, ...many(12, () => fetchRec('ebda-orders', 'https://orders.ebda.app/', 500, { outcome: 'exception', ex: [{ Name: 'TypeError', Message: 'x is undefined' }] }))];
const ae = evaluateLogAlerts(exc, exc).find((x) => x.key === 'exceptions:ebda-orders');
assert.ok(ae, 'MUST fire: 12 exceptions');
assert.match(ae.detail, /TypeError/);
const canceled = [...heartbeat, ...many(30, () => fetchRec('ebda-web', 'https://s.ebda.app/', 0, { outcome: 'canceled' }))];
assert.ok(!evaluateLogAlerts(canceled, canceled).some((x) => x.key.startsWith('exceptions:')), 'must NOT fire: canceled outcomes');

// --- rule: silent pipeline
assert.ok(evaluateLogAlerts([], []).some((x) => x.key === 'logs-silent:all'), 'MUST fire: zero records in 30 min');
const noApi = [cronRec('ebda-status')];
assert.ok(evaluateLogAlerts(noApi, noApi).some((x) => x.key === 'logs-silent:ebda-api'), 'MUST fire: ebda-api silent');
assert.deepEqual(evaluateLogAlerts(heartbeat, heartbeat), [], 'must NOT fire anything on a quiet healthy window');

// --- probes: streak budget, and one message when everything is down
const up = { name: 'api', url: 'u', ok: true, status: 200 };
const down = (n) => ({ name: n, url: `https://${n}`, ok: false, status: 0, error: 'timeout after 10000ms' });
let ps = evaluateProbeAlerts([down('api'), { ...up, name: 'web' }], {});
assert.equal(ps.alerts.length, 0, 'must NOT fire on the first failure');
ps = evaluateProbeAlerts([down('api'), { ...up, name: 'web' }], { streaks: ps.streaks });
assert.deepEqual(ps.alerts.map((x) => x.key), ['probe:api'], 'MUST fire on the second consecutive failure');
ps = evaluateProbeAlerts([{ ...up }, { ...up, name: 'web' }], { streaks: ps.streaks });
assert.equal(ps.streaks.api, 0, 'a success resets the streak');
const allDown = evaluateProbeAlerts([down('a'), down('b'), down('c')], { streaks: { a: 1, b: 1, c: 1 } });
assert.deepEqual(allDown.alerts.map((x) => x.key), ['probe:all'], 'every host down = ONE probe:all alert');

// --- decide: dedupe, repeat, resolve, budget, P2 to digest, unknown never resolves
const p1 = { key: 'probe:api', severity: 'P1', title: 'api down' };
let d = decide([p1], {}, T0);
assert.equal(d.messages.length, 1);
d = decide([p1], d.state, T0 + 5 * 60000);
assert.equal(d.messages.length, 0, 'deduped while still firing');
d = decide([p1], d.state, T0 + 7 * 3600000);
assert.equal(d.messages.length, 1, 're-sent after 6 h');
d = decide([], d.state, T0 + 7 * 3600000 + 60000);
assert.deepEqual(d.messages, ['resolved: probe:api']);
d = decide([], d.state, T0 + 8 * 3600000);
assert.equal(d.messages.length, 0, 'resolved once');
const p2 = { key: 'api-429', severity: 'P2', title: 'API answered 429 5x' };
d = decide([p2], {}, T0);
assert.equal(d.messages.length, 0, 'P2 never messages');
assert.equal(d.state.digest.length, 1);
assert.match(digestText(d.state), /API answered 429 5x/);
let st = {};
for (let i = 0; i < 8; i++) st = decide([{ key: `probe:h${i}`, severity: 'P1', title: `h${i}` }], st, T0 + i).state;
assert.equal(st.day.count, 6, 'daily budget caps messages');
assert.ok(st.digest.some((x) => /over budget/.test(x.title)), 'over-budget alerts fold into the digest');
const outage = decide([{ key: 'probe:all', severity: 'P1', title: 'all down' }], st, T0 + 10);
assert.equal(outage.messages.length, 1, 'probe:all always gets through');
const logP1 = { key: 'storefront-5xx', severity: 'P1', title: 'sf 5xx' };
d = decide([logP1], {}, T0);
d = decide([], d.state, T0 + 60000, { unknownPrefixes: LOG_ALERT_PREFIXES });
assert.equal(d.messages.length, 0, 'unreadable logs do not resolve a log alert');
assert.ok(d.state.open.includes('storefront-5xx'));
assert.ok(DEFAULT_RULES.alwaysActive.includes('ebda-api'));

// brain listing (AI OS primary operator): every alert maps to a brain kind; the listing reconciles prod-watch only
assert.equal(brainKind('probe:api'), 'prod-outage');
assert.equal(brainKind('storefront-5xx'), 'prod-5xx');
assert.equal(brainKind('exceptions:ebda-api'), 'prod-exception');
assert.equal(brainKind('logs-silent:all'), 'prod-logs-silent');
assert.equal(brainKind('alert-drill:2026-11-10'), 'alert-drill');
let bl = brainListing([{ key: 'probe:api', severity: 'P1', title: 'api down', detail: 'HTTP 503' }], { logsRead: true });
assert.deepEqual(bl.reconcile, { source: 'prod-watch' }, 'logs read: everything absent resolves (must fire)');
assert.deepEqual(bl.findings[0], { source: 'prod-watch', kind: 'prod-outage', key: 'probe:api', title: 'api down', severity: 'P1', detail: { text: 'HTTP 503' } });
bl = brainListing([], { logsRead: false });
assert.deepEqual(bl.findings, []);
assert.deepEqual(bl.reconcile.keep, LOG_ALERT_PREFIXES, 'logs unread: log findings are kept, not resolved (must not fire)');

console.log('ebda-logs: PASS');
