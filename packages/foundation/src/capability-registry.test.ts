import { describe, expect, it } from 'vitest';
import { checkRegistry } from './capability-registry';
import { cfg, entry } from '../../../test/helpers/capability-fixture';
import type { Capability } from './capability';

const run = (es: Capability[], names?: string[]) =>
  checkRegistry(es.map((e, i) => ({ name: names?.[i] ?? `${e.id}.capability.json`, json: e })), cfg);
const rules = (es: Capability[], names?: string[]) => run(es, names).violations.map((v) => `${v.rule}|${v.key}`);

describe('checkRegistry', () => {
  it('a valid entry has no violations', () => expect(run([entry()]).violations).toEqual([]));
  it('schema failure becomes a violation keyed by file name and drops the entry', () => {
    const r = checkRegistry([{ name: 'x.capability.json', json: { id: 'nope' } }], cfg);
    expect(r.violations.map((v) => v.rule)).toEqual(['schema']);
    expect(r.violations[0]!.key).toBe('x.capability.json');
    expect(r.entries).toEqual([]);
  });
  it('never throws on non-object json', () => {
    expect(checkRegistry([{ name: 'a', json: null }], cfg).violations[0]!.rule).toBe('schema');
  });
  it('id-filename', () => expect(rules([entry()], ['wrong.capability.json'])).toEqual(['id-filename|orders.list']));
  it('two files declaring one id yield id-duplicate on the second', () => {
    const r = run([entry(), entry()], ['orders.list.capability.json', 'copy.capability.json']);
    expect(r.violations.filter((v) => v.rule === 'id-duplicate')).toHaveLength(1);
    expect(r.entries).toHaveLength(1);
  });
  it('lifecycle: in-pr needs pr, planned needs plan, live needs neither', () => {
    expect(rules([entry({ status: 'in-pr' })])).toEqual(['lifecycle|orders.list']);
    expect(rules([entry({ status: 'planned' })])).toEqual(['lifecycle|orders.list']);
    expect(rules([entry({ status: 'in-pr', pr: 'ebda-store#1' })])).toEqual([]);
    expect(rules([entry({ status: 'planned', plan: 'docs/x.md' })])).toEqual([]);
  });
  it('a free entry whose api has POST fails policy-free-writes', () => {
    expect(rules([entry({ api: ['POST /stores/:id/orders'] })])).toEqual(['policy-free-writes|orders.list']);
  });
  it('a flagged read-only POST on a free entry passes (templates.sync)', () => {
    expect(rules([entry({ id: 'templates.sync', api: ['POST /templates/sync'], readOnlyPost: { routes: ['POST /templates/sync'], reason: 'only pulls Meta template list' } })])).toEqual([]);
  });
  it('readOnlyPost excuses only the routes it names: a second, real POST in the entry still fails', () => {
    const e = entry({ id: 'templates.sync', api: ['POST /s/sync', 'POST /s/products'], readOnlyPost: { routes: ['POST /s/sync'], reason: 'pull only' } });
    expect(rules([e])).toEqual(['policy-free-writes|templates.sync']);
  });
  it('readOnlyPost matches routes after normalisation (case, trailing slash, param name)', () => {
    const e = entry({ id: 'templates.sync', api: ['post /s/:id/sync/'], readOnlyPost: { routes: ['POST /s/:storeId/sync'], reason: 'pull only' } });
    expect(rules([e])).toEqual([]);
  });
  it('readOnlyPost naming a route that is not a POST in api fails readonlypost-unknown-route', () => {
    expect(rules([entry({ api: ['GET /a'], readOnlyPost: { routes: ['POST /nope'], reason: 'r' } })])).toEqual(['readonlypost-unknown-route|orders.list POST /nope']);
    expect(rules([entry({ api: ['GET /a'], readOnlyPost: { routes: ['GET /a'], reason: 'r' } })])).toEqual(['readonlypost-unknown-route|orders.list GET /a']);
  });
  it('the readOnlyPost flag never excuses PUT, PATCH or DELETE', () => {
    expect(rules([entry({ api: ['PATCH /x'], readOnlyPost: { routes: ['PATCH /x'], reason: 'r' } })]).sort()).toEqual(['policy-free-writes|orders.list', 'readonlypost-unknown-route|orders.list PATCH /x']);
  });
  it('must-confirm patterns run on the normalised route (trailing slash, case, double slashes, param names)', () => {
    const strict = { ...cfg, mustConfirm: [{ method: 'POST', pattern: '/refund$' }, { pattern: '^/s/:_/pay$' }] };
    const run2 = (api: string) => checkRegistry([{ name: 'orders.list.capability.json', json: entry({ policy: 'preview', api: [api] }) }], strict).violations.map((v) => v.rule);
    expect(run2('POST /x/refund/')).toContain('policy-must-confirm');
    expect(run2('post //x//refund')).toContain('policy-must-confirm');
    expect(run2('POST /x/ref%75nd')).toContain('policy-must-confirm');
    expect(run2('GET /s/:storeId/pay')).toContain('policy-must-confirm');
    expect(run2('GET /s/[id]/pay')).toContain('policy-must-confirm');
  });
  it('a wildcard screen that covers every page ("/*") or has a wildcard mid-path fails screen-wildcard; /x/* is fine', () => {
    expect(rules([entry({ screens: ['/*'] })])).toEqual(['screen-wildcard|orders.list /*']);
    expect(rules([entry({ screens: ['/', '/stores/*/x'] })])).toEqual(['screen-wildcard|orders.list /stores/*/x']);
    expect(rules([entry({ screens: ['/stores/[id]/marketing/*'] })])).toEqual([]);
  });
  it('policy-must-confirm: a cfg pattern match and any DELETE need confirm or forbidden', () => {
    expect(rules([entry({ policy: 'preview', api: ['POST /stores/:id/refunds'] })])).toEqual(['policy-must-confirm|orders.list']);
    expect(rules([entry({ policy: 'preview', api: ['DELETE /stores/:id/x'] })])).toEqual(['policy-must-confirm|orders.list']);
    expect(rules([entry({ policy: 'confirm', api: ['DELETE /stores/:id/x'] })])).toEqual([]);
  });
  it('policy-irreversible', () => {
    expect(rules([entry({ policy: 'preview', api: [], undo: { class: 'irreversible' } })])).toEqual(['policy-irreversible|orders.list']);
    expect(rules([entry({ policy: 'confirm', api: [], undo: { class: 'irreversible' } })])).toEqual([]);
  });
  it('operator-only entry with policy confirm fails operator-forbidden; no code fails operator-reason', () => {
    expect(rules([entry({ roles: ['super_admin'], policy: 'confirm', api: [], operatorReason: { code: 'legal', text: 't', validUnderRule: true } })])).toEqual(['operator-forbidden|orders.list']);
    expect(rules([entry({ roles: ['operator'], policy: 'forbidden', api: [] })])).toEqual(['operator-reason|orders.list']);
    expect(rules([entry({ roles: ['operator'], policy: 'forbidden', api: [], operatorReason: { code: 'abuse', text: 't', validUnderRule: true } })])).toEqual([]);
  });
  it('a live entry with 2 Arabic questions fails questions-count', () => {
    expect(rules([entry({ questions: { ar: ['a', 'b'], en: ['a'] } })])).toEqual(['questions-count|orders.list']);
    expect(rules([entry({ questions: { ar: ['a', 'b', 'c'], en: [] } })])).toEqual(['questions-count|orders.list']);
    expect(rules([entry({ questions: { ar: ['a', 'b', 'c', 'd', 'e', 'f', 'g'], en: ['a'] } })])).toEqual(['questions-count|orders.list']);
  });
  it('planned entries need only one question per language', () => {
    expect(rules([entry({ status: 'planned', plan: 'p', questions: { ar: ['a'], en: ['a'] } })])).toEqual([]);
    expect(rules([entry({ status: 'planned', plan: 'p', questions: { ar: [], en: ['a'] } })])).toEqual(['questions-count|orders.list']);
  });
  it('undo-unclassified', () => expect(rules([entry({ undo: { class: 'unclassified' } })])).toEqual(['undo-unclassified|orders.list']));
});
