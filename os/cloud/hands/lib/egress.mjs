// Container egress allowlist (ruling F-I8). Everything untrusted (Claude, the repo's install / test / format commands)
// reaches the network only through this proxy, which the hands run as root on 127.0.0.1. Allowed hosts: github.com,
// api.github.com, codeload.github.com, objects.githubusercontent.com, registry.npmjs.org, api.anthropic.com and the brain
// host. Anything else gets 403 and is logged. The kernel side (non-root uids may only talk to loopback) is applied by
// entrypoint.sh, because a proxy variable alone is something hostile code can simply ignore.
import { createServer } from 'node:http';
import net from 'node:net';

export const DEFAULT_ALLOW = ['github.com', 'api.github.com', 'codeload.github.com', 'objects.githubusercontent.com', 'registry.npmjs.org', 'api.anthropic.com'];

/** HANDS_EGRESS_ALLOW (comma/space list) extends the defaults; the brain host is added by the container start. */
export function allowList(extra = '') {
  return [...new Set([...DEFAULT_ALLOW, ...String(extra).split(/[\s,]+/).map((h) => h.trim().toLowerCase()).filter((h) => /^[a-z0-9.-]+$/.test(h))])];
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
