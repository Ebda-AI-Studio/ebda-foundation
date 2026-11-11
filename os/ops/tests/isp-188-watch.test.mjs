// isp-188-watch: CIDR maths, findings from a fixture resolver, and the CLI's skip-if-unchanged state.
import assert from 'node:assert';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, writeFileSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { inCidr, checkHosts, toFindings, signature } from '../lib/isp188-core.mjs';

const R = '188.114.96.0/23';
assert.equal(inCidr('188.114.96.0', R), true);
assert.equal(inCidr('188.114.96.6', R), true);
assert.equal(inCidr('188.114.97.255', R), true);
assert.equal(inCidr('188.114.98.0', R), false);
assert.equal(inCidr('188.114.95.255', R), false);
assert.equal(inCidr('172.67.1.1', R), false);
assert.equal(inCidr('not-an-ip', R), false);

const fixture = { 'ebda.app': ['172.67.1.1', '104.21.2.2'], 'store.ebda.app': ['188.114.97.6'], 'ameliaaurum.com': ['104.21.9.9', '188.114.96.7'], 'down.example': [] };
const resolve = async (h) => { if (!(h in fixture)) throw new Error('NXDOMAIN'); return fixture[h]; };
const results = await checkHosts(['ebda.app', 'store.ebda.app', 'ameliaaurum.com', 'down.example', 'gone.example'], resolve, [R]);
const f = toFindings(results, [R]);
assert.deepEqual(f.filter((x) => x.kind === 'isp-block-range').map((x) => x.key), ['store.ebda.app', 'ameliaaurum.com']); // MUST fire
assert.equal(f.find((x) => x.key === 'ebda.app'), undefined); // must NOT fire on a clean host
assert.ok(f.filter((x) => x.kind === 'isp-block-range').every((x) => x.severity === 'P1' && x.source === 'isp-188'));
assert.deepEqual(f.filter((x) => x.kind === 'dns-unresolved').map((x) => x.key), ['down.example', 'gone.example']);
assert.deepEqual(f.find((x) => x.key === 'ameliaaurum.com').detail.blocked, ['188.114.96.7']);

// CLI: first run posts, second identical run is skipped, a change posts again, --force overrides
const dir = mkdtempSync(join(tmpdir(), 'isp188-'));
const bin = join(dirname(fileURLToPath(import.meta.url)), '..', 'isp-188-watch.mjs');
const run = (extra = [], fx = fixture) => {
  writeFileSync(join(dir, 'fx.json'), JSON.stringify(fx));
  execFileSync('node', [bin, '--fixture', join(dir, 'fx.json'), '--state', join(dir, 'state.json'), '--out', join(dir, 'out.json'), '--hosts', 'ebda.app,store.ebda.app', ...extra], { stdio: 'pipe' });
  return JSON.parse(readFileSync(join(dir, 'out.json'), 'utf8'));
};
assert.equal(run().length, 1);
assert.equal(run().length, 0); // unchanged: nothing posted
assert.equal(run(['--force']).length, 1);
assert.equal(run([], { ...fixture, 'store.ebda.app': ['172.67.5.5'] }).length, 0); // changed, now clean: no finding
assert.equal(run([], fixture).length, 1); // moved back into the range: alerts again
assert.notEqual(signature(results), signature(results.slice(1)));
console.log('isp-188-watch: all assertions passed');
