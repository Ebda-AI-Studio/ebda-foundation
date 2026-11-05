// The real exec: no shell, a wall-clock cap that kills the process group it started, line streaming.
import { describe, expect, it } from 'vitest';
import { exec } from '../lib/exec.mjs';

describe('exec', () => {
  it('streams stdout lines and returns the exit code', async () => {
    const lines = [];
    const r = await exec('node', ['-e', 'console.log("a");console.log("b");process.exit(3)'], { onLine: (l) => lines.push(l) });
    expect(r).toMatchObject({ code: 3, timedOut: false });
    expect(lines).toEqual(['a', 'b']);
  });
  it('kills the whole group at the cap (a grandchild cannot keep it alive)', async () => {
    const t = Date.now();
    const r = await exec('node', ['-e', 'require("child_process").spawn("sleep",["30"],{stdio:"inherit"});setTimeout(()=>{},30000)'], { timeoutMs: 300 });
    expect(r.timedOut).toBe(true);
    expect(Date.now() - t).toBeLessThan(5000);
  });
  it('arguments are never shell-interpreted', async () => {
    const r = await exec('node', ['-e', 'console.log(process.argv[1])', '$(echo pwned); ls'], {});
    expect(r.stdout.trim()).toBe('$(echo pwned); ls');
  });
});

describe('exec time caps (M-1)', () => {
  it('a cap of 0 (or negative / NaN) is already expired: nothing starts', async () => {
    for (const t of [0, -5, Number.NaN]) {
      const r = await exec('node', ['-e', 'require("fs").writeFileSync("/dev/null","x")'], { timeoutMs: t });
      expect(r).toMatchObject({ timedOut: true, code: 124 });
    }
  });
  it('fd3 hands a secret to the child without putting it in the env', async () => {
    const r = await exec('node', ['-e', 'const s=require("fs").readFileSync(3,"utf8");console.log(s.length, JSON.stringify(process.env).includes(s))'], { fd3: 'sekret', env: { PATH: process.env.PATH } });
    expect(r.stdout.trim()).toBe('6 false');
  });
});
