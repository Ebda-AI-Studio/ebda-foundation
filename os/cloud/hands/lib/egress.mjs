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
// Claude runs with ANTHROPIC_BASE_URL pointing here (plain HTTP on loopback). The forwarder is the ONLY way to the model API: it allows
// POST /v1/messages and POST /v1/messages/count_tokens, refuses everything else (the Files API, GETs, other paths), and sets the credential
// itself: api mode replaces x-api-key with the real key (Claude only ever holds a placeholder, so a prompt-injected process has no key to
// steal and an attacker's key in a request is overwritten, never forwarded); max mode requires the request to carry exactly our OAuth bearer.
// The CONNECT proxy for Claude then has an empty allowlist: there is no direct TLS path to api.anthropic.com at all.
// NOT VERIFIED: that Claude Code 2.1.309 accepts a placeholder key / a loopback base URL end to end (deploy smoke; ruling RR-hands-api-auth).
// HANDS_ANTHROPIC_FORWARDER=0 falls back to CONNECT api.anthropic.com with the real credential in Claude's env.
export const ANTHROPIC_PLACEHOLDER_KEY = 'sk-ant-api03-hands-local-placeholder-not-a-real-key';
const FWD_PATHS = new Set(['/v1/messages', '/v1/messages/count_tokens']);
const FWD_PASS = ['content-type', 'accept', 'anthropic-version', 'anthropic-beta', 'user-agent', 'x-app', 'accept-encoding'];

export function startAnthropicForwarder({ mode, secret, upstream = { host: 'api.anthropic.com', port: 443, tls: true }, log = () => {}, maxBody = 16 * 1024 * 1024 }) {
  const denied = new Set();
  const refuse = (res, code, why, what) => {
    denied.add(what);
    log(`model API request refused: ${what} (${why})`);
    res.writeHead(code, { 'content-type': 'application/json' }).end(JSON.stringify({ error: { type: 'forbidden', message: `hands forwarder: ${why}` } }));
  };
  const server = createServer((req, res) => {
    const path = String(req.url ?? '').split('?')[0];
    const what = `${req.method} ${path}`;
    if (req.method !== 'POST') return refuse(res, 405, 'only POST', what);
    if (!FWD_PATHS.has(path)) return refuse(res, 403, 'path not allowed (messages only)', what);
    const apiKey = req.headers['x-api-key'];
    const auth = req.headers.authorization;
    if (mode === 'max') {
      if (apiKey) return refuse(res, 403, 'an API key is not allowed in max mode', what);
      if (auth !== `Bearer ${secret}`) return refuse(res, 403, 'authorization is not the configured token', what);
    }
    const headers = { host: upstream.host };
    for (const h of FWD_PASS) if (req.headers[h]) headers[h] = req.headers[h];
    if (mode === 'api') headers['x-api-key'] = secret; // the placeholder (or an attacker's key) never reaches Anthropic
    else headers.authorization = `Bearer ${secret}`;
    let size = 0;
    const chunks = [];
    req.on('data', (c) => {
      size += c.length;
      if (size > maxBody) {
        req.destroy();
        return;
      }
      chunks.push(c);
    });
    req.on('end', () => {
      if (size > maxBody) return refuse(res, 413, 'body too large', what);
      const body = Buffer.concat(chunks);
      headers['content-length'] = String(body.length);
      const up = (upstream.tls ? httpsRequest : httpRequest)({ host: upstream.host, port: upstream.port, method: 'POST', path: req.url, headers }, (r) => {
        res.writeHead(r.statusCode ?? 502, r.headers);
        r.pipe(res);
      });
      up.on('error', () => res.headersSent || res.writeHead(502).end('upstream error'));
      up.end(body);
    });
  });
  return new Promise((resolve) => {
    server.listen(0, '127.0.0.1', () => resolve({ port: server.address().port, denied, close: () => new Promise((r) => server.close(r)) }));
  });
}
