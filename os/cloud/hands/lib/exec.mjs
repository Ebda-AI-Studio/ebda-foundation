// One way to run a child process: no shell, a wall-clock cap, the whole process group killed on timeout (only the
// group this module started, never a pattern kill), output capped so a chatty test run cannot fill memory.
import { spawn } from 'node:child_process';

const CAP = 256 * 1024;

function tail(s) {
  return s.length > CAP ? s.slice(-CAP) : s;
}

/**
 * exec(cmd, args, { cwd, env, timeoutMs, onLine }) -> { code, stdout, stderr, timedOut }
 * onLine(line) receives each stdout line as it arrives (stream-json parsing).
 * timeoutMs: undefined = no cap; a number <= 0 (or not finite) = already expired, nothing is started.
 * fd3: a string written to the child's file descriptor 3 then closed (a credential that must not be in the env).
 */
export function exec(cmd, args = [], opts = {}) {
  if (opts.timeoutMs !== undefined && !(Number.isFinite(opts.timeoutMs) && opts.timeoutMs > 0)) {
    return Promise.resolve({ code: 124, stdout: '', stderr: 'time cap already reached', timedOut: true });
  }
  return new Promise((resolve) => {
    let stdout = '';
    let stderr = '';
    let buf = '';
    let timedOut = false;
    let child;
    try {
      child = spawn(cmd, args, { cwd: opts.cwd, env: opts.env ?? process.env, stdio: opts.fd3 !== undefined ? ['ignore', 'pipe', 'pipe', 'pipe'] : ['ignore', 'pipe', 'pipe'], detached: true });
      if (opts.fd3 !== undefined) {
        child.stdio[3].on('error', () => {});
        child.stdio[3].end(opts.fd3);
      }
    } catch (e) {
      resolve({ code: 127, stdout: '', stderr: String(e?.message ?? e), timedOut: false });
      return;
    }
    const kill = (sig) => {
      try {
        process.kill(-child.pid, sig);
      } catch {
        /* already gone */
      }
    };
    const timer = opts.timeoutMs
      ? setTimeout(() => {
          timedOut = true;
          kill('SIGTERM');
          setTimeout(() => kill('SIGKILL'), 10_000).unref();
        }, opts.timeoutMs)
      : null;
    child.stdout.on('data', (d) => {
      const s = d.toString();
      stdout = tail(stdout + s);
      if (opts.onLine) {
        buf += s;
        let i;
        while ((i = buf.indexOf('\n')) >= 0) {
          const line = buf.slice(0, i);
          buf = buf.slice(i + 1);
          if (line.trim()) opts.onLine(line);
        }
      }
    });
    child.stderr.on('data', (d) => {
      stderr = tail(stderr + d.toString());
    });
    child.on('error', (e) => {
      stderr = tail(stderr + String(e?.message ?? e));
    });
    child.on('close', (code) => {
      if (timer) clearTimeout(timer);
      if (opts.onLine && buf.trim()) opts.onLine(buf);
      resolve({ code: code ?? (timedOut ? 124 : 1), stdout, stderr, timedOut });
    });
  });
}
