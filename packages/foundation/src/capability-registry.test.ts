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
    expect(rules([entry({ id: 'templates.sync', api: ['POST /templates/sync'], readOnlyPost: { reason: 'only pulls Meta template list' } })])).toEqual([]);
  });
  it('the readOnlyPost flag never excuses PUT, PATCH or DELETE', () => {
    expect(rules([entry({ api: ['PATCH /x'], readOnlyPost: { reason: 'r' } })])).toEqual(['policy-free-writes|orders.list']);
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
