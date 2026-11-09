// Container egress (ruling F-I8, tightened by RR-egress-roles). Everything untrusted reaches the network only through proxies the
// hands run as root on 127.0.0.1, one per ROLE:
//   claude  Claude Code           CONNECT to api.anthropic.com (+ HANDS_EGRESS_ALLOW) only. No GitHub, no registry.
//   tests   install / test / fmt  CONNECT to NOTHING; npm gets a local registry MIRROR that forwards GET/HEAD to registry.npmjs.org
//                                 and refuses every other method, so an injected `npm publish` (attacker token) or a gist / files
//                                 upload has no path. (The hands' own git clone / push / gh run as root, outside the proxies.)
// Anything else gets 403 and is logged. The kernel side (non-root uids may only talk to loopback) is applied by
// entrypoint.sh, because a proxy variable alone is something hostile code can simply ignore.
import { createServer, request as httpRequest } from 'node:http';
import { request as httpsRequest } from 'node:https';
import net from 'node:net';

/** Claude Code reaches ONLY the model API (it has no GitHub credential and needs no registry). Extras: HANDS_EGRESS_ALLOW. */
export const CLAUDE_ALLOW = ['api.anthropic.com'];

/** HANDS_EGRESS_ALLOW (comma/space list) extends the Claude list; the brain host is added by the container start. */
export function claudeAllowList(extra = '') {
  return [...new Set([...CLAUDE_ALLOW, ...String(extra).split(/[\s,]+/).map((h) => h.trim().toLowerCase()).filter((h) => /^[a-z0-9.-]+$/.test(h))])];
}

export function hostAllowed(host, allow) {
  const h = String(host ?? '').toLowerCase().replace(/\.$/, '');
  return allow.includes(h);
}

/** Starts the proxy; resolves { port, close, denied } (denied = hosts refused so far, for the log). */
export function startProxy({ allow, log = () => {} }) {
  const denied = new Set();
  const server = createServer((req, res) => {
    // plain-HTTP proxying is not needed by any allowed host (all are TLS): refuse
    denied.add(`http:${req.headers.host ?? '?'}`);
    log(`egress denied (plain http): ${req.headers.host ?? '?'}`);
    res.writeHead(403).end('egress: plain http is not allowed');
  });
  server.on('connect', (req, socket, head) => {
    const [host, portStr] = String(req.url).split(':');
    const port = Number(portStr || 443);
    if (!hostAllowed(host, allow) || port !== 443) {
      denied.add(`${host}:${port}`);
      log(`egress denied: ${host}:${port}`);
      socket.end('HTTP/1.1 403 Forbidden\r\n\r\n');
      return;
    }
    const up = net.connect(port, host, () => {
      socket.write('HTTP/1.1 200 Connection Established\r\n\r\n');
      if (head?.length) up.write(head);
      up.pipe(socket);
      socket.pipe(up);
    });
    const done = () => {
      up.destroy();
      socket.destroy();
    };
    up.on('error', done);
    socket.on('error', done);
  });
  return new Promise((resolve) => {
    server.listen(0, '127.0.0.1', () => resolve({ port: server.address().port, denied, close: () => new Promise((r) => server.close(r)) }));
  });
}

/** Env that points a child at the proxy (node needs NODE_USE_ENV_PROXY for its own fetch). */
export function proxyEnv(port) {
  const u = `http://127.0.0.1:${port}`;
  return { HTTPS_PROXY: u, HTTP_PROXY: u, ALL_PROXY: u, https_proxy: u, http_proxy: u, NO_PROXY: '127.0.0.1,localhost', NODE_USE_ENV_PROXY: '1' };
}

/** Local registry mirror for the tests role: GET/HEAD only, forwarded to the real registry, credentials stripped. Anything that
 *  writes (npm publish = PUT, dist-tag, deprecate, unpublish = DELETE) is 405 and recorded. */
export function startRegistryMirror({ upstream = { host: 'registry.npmjs.org', port: 443, tls: true }, log = () => {} } = {}) {
  const denied = new Set();
  const server = createServer((req, res) => {
    if (req.method !== 'GET' && req.method !== 'HEAD') {
      denied.add(`${req.method} ${String(req.url).split('?')[0]}`);
      log(`registry write refused: ${req.method} ${String(req.url).split('?')[0]}`);
      res.writeHead(405, { allow: 'GET, HEAD' }).end('registry mirror is read-only');
      return;
    }
    if (!String(req.url).startsWith('/')) {
      res.writeHead(400).end('bad path');
      return;
    }
    const headers = { host: upstream.host, accept: req.headers.accept ?? '*/*', 'user-agent': req.headers['user-agent'] ?? 'npm' };
    for (const h of ['accept-encoding', 'npm-command', 'npm-session', 'if-none-match', 'if-modified-since']) if (req.headers[h]) headers[h] = req.headers[h];
    const up = (upstream.tls ? httpsRequest : httpRequest)({ host: upstream.host, port: upstream.port, method: req.method, path: req.url, headers }, (r) => {
      res.writeHead(r.statusCode ?? 502, r.headers);
      r.pipe(res);
    });
    up.on('error', () => res.headersSent || res.writeHead(502).end('upstream error'));
    up.end();
  });
  return new Promise((resolve) => {
    server.listen(0, '127.0.0.1', () => resolve({ port: server.address().port, denied, close: () => new Promise((r) => server.close(r)) }));
  });
}

/** Env for the tests role: no direct network (the proxy refuses every CONNECT), npm reads through the mirror. */
export function testsEnv(proxyPort, mirrorPort) {
  return { ...proxyEnv(proxyPort), npm_config_registry: `http://127.0.0.1:${mirrorPort}/` };
}

// ---- F-03: the model-API forwarder -------------------------------------------------------------------------------------------------
// Claude runs with ANTHROPIC_BASE_URL pointing here (plain HTTP on 127.0.0.1). The forwarder is the ONLY way to the model API and it is also the
// METER (RR-hands-api-auth, money re-review C1):
//   - it REQUIRES the per-run key: api mode = a random placeholder (generated per run, handed to Claude only), compared in constant time; max mode =
//     our OAuth bearer. Any other local process (the tests uid, a postinstall) has no key and gets 401, so it cannot spend through the forwarder (C2);
//   - POST /v1/messages and /v1/messages/count_tokens only; the body must be JSON, its `model` must be the model routed for the ACTIVE job (anything
//     else, e.g. opus on a sonnet run, is refused), `max_tokens` is clamped to the per-kind ceiling, `inference_geo` is refused (a 1.1x price tier);
//   - once the active job's metered spend reaches its budget, further calls are refused (429) so a runaway job cannot keep spending (I2);
//   - it sets the real credential itself (api mode: Claude only ever holds the placeholder) and meters each response's real `usage`
//     (input, output, cache read, cache writes split 5m / 1h; streaming or not) through `onMeter`, as it happens;
//   - it asks upstream for an uncompressed body (identity) so the usage can be read.
// NOT VERIFIED: that Claude Code 2.1.309 works end to end with a placeholder key and a loopback base URL (deploy smoke; HANDS_ANTHROPIC_FORWARDER=0
// falls back to a direct key and CONNECT, metered only from the result event).
import { randomBytes, timingSafeEqual } from 'node:crypto';
import { costOf, priceTable } from './prices.mjs';

export const ANTHROPIC_PLACEHOLDER_KEY = 'sk-ant-api03-hands-local-placeholder-not-a-real-key';
/** A fresh unguessable placeholder per run (C2). */
export const newRunKey = () => `sk-ant-api03-hands-${randomBytes(24).toString('hex')}`;
const FWD_PATHS = new Set(['/v1/messages', '/v1/messages/count_tokens']);
const FWD_PASS = ['content-type', 'accept', 'anthropic-version', 'anthropic-beta', 'user-agent', 'x-app'];

function safeEqual(a, b) {
  const x = Buffer.from(String(a ?? ''));
  const y = Buffer.from(String(b ?? ''));
  return x.length === y.length && timingSafeEqual(x, y);
}

/** Usage of one response body: JSON ({usage}) or SSE (message_start usage + message_delta output_tokens). null when none is found. */
export function usageFromResponse(text) {
  const t = String(text ?? '');
  try {
    const j = JSON.parse(t);
    if (j && typeof j === 'object' && j.usage) return { model: j.model, usage: j.usage };
  } catch {
    /* maybe SSE */
  }
  let usage = null;
  let model;
  for (const line of t.split('\n')) {
    if (!line.startsWith('data:')) continue;
    let ev;
    try {
      ev = JSON.parse(line.slice(5).trim());
    } catch {
      continue;
    }
    if (ev.type === 'message_start' && ev.message?.usage) {
      usage = { ...ev.message.usage };
      model = ev.message.model;
    } else if (ev.type === 'message_delta' && ev.usage) {
      usage = { ...(usage ?? {}), ...ev.usage };
    }
  }
  return usage ? { model, usage } : null;
}

export function startAnthropicForwarder({ mode, secret, runKey, upstream = { host: 'api.anthropic.com', port: 443, tls: true }, log = () => {}, maxBody = 16 * 1024 * 1024, maxTokensCeiling = 16000, prices = priceTable(), onMeter = () => {} }) {
  const denied = new Set();
  const perJob = new Map();
  const jobCalls = new Map();
  const jobTok = new Map();
  let active = null; // { id, model, budgetUsd }
  let totalUsd = 0;
  let calls = 0;
  const refuse = (res, code, why, what) => {
    denied.add(what);
    log(`model API request refused: ${what} (${why})`);
    res.writeHead(code, { 'content-type': 'application/json' }).end(JSON.stringify({ type: 'error', error: { type: code === 429 ? 'rate_limit_error' : 'permission_error', message: `hands forwarder: ${why}` } }));
  };
  const server = createServer((req, res) => {
    const path = String(req.url ?? '').split('?')[0];
    const what = `${req.method} ${path}`;
    // the per-run credential first: nothing else is looked at for a caller that does not hold it
    if (mode === 'api') {
      if (!safeEqual(req.headers['x-api-key'], runKey)) return refuse(res, 401, 'missing or wrong run key', what);
    } else {
      if (req.headers['x-api-key']) return refuse(res, 401, 'an API key is not allowed in max mode', what);
      if (!safeEqual(req.headers.authorization, `Bearer ${secret}`)) return refuse(res, 401, 'missing or wrong credential', what);
    }
    if (req.method !== 'POST') return refuse(res, 405, 'only POST', what);
    if (!FWD_PATHS.has(path)) return refuse(res, 403, 'path not allowed (messages only)', what);
    if (!active) return refuse(res, 409, 'no active job', what);
    const job = active;
    let size = 0;
    const chunks = [];
    req.on('data', (c) => {
      size += c.length;
      if (size > maxBody) req.destroy();
      else chunks.push(c);
    });
    req.on('end', () => {
      if (size > maxBody) return refuse(res, 413, 'body too large', what);
      let body;
      try {
        body = JSON.parse(Buffer.concat(chunks).toString('utf8'));
      } catch {
        return refuse(res, 400, 'body is not JSON', what);
      }
      if (!body || typeof body !== 'object' || Array.isArray(body)) return refuse(res, 400, 'body is not an object', what);
      if (body.inference_geo !== undefined) return refuse(res, 403, 'inference_geo is not allowed (price tier)', what);
      if (body.model !== job.model) return refuse(res, 403, `model ${String(body.model).slice(0, 60)} is not this run's routed model ${job.model}`, what);
      if (job.budgetUsd !== undefined && (perJob.get(job.id) ?? 0) >= job.budgetUsd) return refuse(res, 429, `job budget $${job.budgetUsd.toFixed(2)} spent`, what);
      if (path === '/v1/messages' && typeof body.max_tokens === 'number' && body.max_tokens > maxTokensCeiling) body.max_tokens = maxTokensCeiling;
      const out = Buffer.from(JSON.stringify(body));
      const headers = { host: upstream.host, 'accept-encoding': 'identity', 'content-length': String(out.length) };
      for (const h of FWD_PASS) if (req.headers[h]) headers[h] = req.headers[h];
      if (mode === 'api') headers['x-api-key'] = secret; // the placeholder (or any other key) never reaches Anthropic
      else headers.authorization = `Bearer ${secret}`;
      const up = (upstream.tls ? httpsRequest : httpRequest)({ host: upstream.host, port: upstream.port, method: 'POST', path: req.url, headers }, (r) => {
        res.writeHead(r.statusCode ?? 502, r.headers);
        const seen = [];
        let seenBytes = 0;
        r.on('data', (c) => {
          res.write(c);
          if (seenBytes < 32 * 1024 * 1024) {
            seen.push(c);
            seenBytes += c.length;
          }
        });
        r.on('end', () => {
          res.end();
          if (path !== '/v1/messages' || (r.statusCode ?? 0) >= 400) return;
          const got = usageFromResponse(Buffer.concat(seen).toString('utf8'));
          if (!got) {
            log(`model API response for job ${job.id} had no usage block (metered as unknown)`);
            return;
          }
          const m = costOf(got.usage, got.model ?? job.model, prices);
          perJob.set(job.id, (perJob.get(job.id) ?? 0) + m.costUsd);
          totalUsd += m.costUsd;
          calls++;
          jobCalls.set(job.id, (jobCalls.get(job.id) ?? 0) + 1);
          const t = jobTok.get(job.id) ?? { inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0 };
          for (const k of Object.keys(t)) t[k] += m[k];
          jobTok.set(job.id, t);
          try {
            onMeter({ jobId: job.id, ...m });
          } catch (e) {
            log(`meter callback failed: ${e?.message ?? e}`);
          }
        });
      });
      up.on('error', () => res.headersSent || res.writeHead(502).end('upstream error'));
      up.end(out);
    });
  });
  return new Promise((resolve) => {
    server.listen(0, '127.0.0.1', () =>
      resolve({
        port: server.address().port,
        denied,
        /** the job whose calls are allowed and metered: its routed model id and dollar budget */
        begin: (j) => { active = { id: j.id, model: j.model, budgetUsd: j.budgetUsd }; perJob.set(j.id, perJob.get(j.id) ?? 0); },
        /** what the job cost as metered at the forwarder */
        end: (id) => { const usd = perJob.get(id) ?? 0; active = null; return { usd, calls: jobCalls.get(id) ?? 0, ...(jobTok.get(id) ?? { inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0 }) }; },
        spent: () => ({ totalUsd, calls }),
        close: () => new Promise((r) => server.close(r)),
      }),
    );
  });
}
