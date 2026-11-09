// report-refusal.mjs: the call entrypoint.sh makes before exit 3, so the brain can raise the P1 (N-3 / egress lock minor).
import { spawnSync } from 'node:child_process';
import { createServer } from 'node:http';
import { describe, expect, it } from 'vitest';

const SCRIPT = new URL('../lib/report-refusal.mjs', import.meta.url).pathname;

function listen() {
  return new Promise((resolve) => {
    const got = [];
    const server = createServer((req, res) => {
      let body = '';
      req.on('data', (c) => (body += c));
      req.on('end', () => {
        got.push({ method: req.method, url: req.url, auth: req.headers.authorization, body: JSON.parse(body) });
        res.writeHead(200).end('{"ok":true}');
      });
    });
    server.listen(0, '127.0.0.1', () => resolve({ got, port: server.address().port, close: () => server.close() }));
  });
}

describe('report-refusal.mjs', () => {
  it('POSTs the run id and reason to /hands/refused with the hands token', async () => {
    const s = await listen();
    const r = await new Promise((res) => {
      import('node:child_process').then(({ spawn }) => {
        const p = spawn(process.execPath, [SCRIPT, 'no CAP_NET_ADMIN'], { env: { PATH: process.env.PATH, BRAIN_URL: `http://127.0.0.1:${s.port}`, HANDS_TOKEN: 'tok', HANDS_RUN_ID: 'run_1' } });
        p.on('close', (code) => res(code));
      });
    });
    s.close();
    expect(r).toBe(0);
    expect(s.got).toEqual([{ method: 'POST', url: '/hands/refused', auth: 'Bearer tok', body: { runId: 'run_1', reason: 'no CAP_NET_ADMIN' } }]);
  });
  it('never fails the entrypoint: an unreachable brain exits 0, a missing env does nothing', () => {
    const a = spawnSync(process.execPath, [SCRIPT, 'x'], { env: { PATH: process.env.PATH, BRAIN_URL: 'http://127.0.0.1:9', HANDS_TOKEN: 't', HANDS_RUN_ID: 'r' }, encoding: 'utf8' });
    expect(a.status).toBe(0);
    expect(a.stderr).not.toContain('t\n');
    const b = spawnSync(process.execPath, [SCRIPT], { env: { PATH: process.env.PATH }, encoding: 'utf8' });
    expect(b.status).toBe(0);
  });
});
