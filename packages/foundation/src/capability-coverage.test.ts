import { describe, expect, it } from 'vitest';
import { checkCoverage, pageMatches, type CodeFacts } from './capability-coverage';
import { entry } from '../../../test/helpers/capability-fixture';

const facts = (over: Partial<CodeFacts> = {}): CodeFacts => ({ pages: [], routes: [], ...over });
const ids = (f: CodeFacts, es = [entry()]) => checkCoverage(f, es).map((v) => `${v.rule}|${v.key}`);

describe('checkCoverage', () => {
  it('route with trailing slash and another param name is covered, not uncovered', () => {
    expect(ids(facts({ routes: [{ method: 'GET', path: '/stores/:storeId/orders/', kind: 'merchant' }] }))).toEqual([]);
  });
  it('an encoded path resolves to the same claim', () => {
    const e = entry({ api: ['GET /orders'] });
    expect(ids(facts({ routes: [{ method: 'GET', path: '/ord%65rs', kind: 'merchant' }] }), [e])).toEqual([]);
  });
  it('a public route needs no entry', () => {
    expect(ids(facts({ routes: [{ method: 'GET', path: '/public/x', kind: 'public' }] }), [entry({ api: [] })])).toEqual([]);
  });
  it('an unclaimed merchant route is route-uncovered keyed METHOD path', () => {
    expect(ids(facts({ routes: [{ method: 'post', path: '/stores/:id/zzz', kind: 'merchant' }] }), [entry({ api: [] })])).toEqual(['route-uncovered|POST /stores/:id/zzz']);
  });
  it('planned entry naming an unbuilt api is not dangling; the same entry live is', () => {
    const planned = entry({ status: 'planned', plan: 'p', api: ['POST /not-built'] });
    const live = entry({ api: ['POST /not-built'] });
    expect(ids(facts(), [planned])).toEqual([]);
    expect(ids(facts(), [live])).toEqual(['route-dangling|orders.list POST /not-built']);
  });
  it('page pattern with wildcard covers sub-paths', () => {
    const e = entry({ screens: ['/stores/[id]/marketing/*'], api: [] });
    expect(ids(facts({ pages: ['/stores/[id]/marketing/seo'] }), [e])).toEqual([]);
  });
  it('uncovered page and uncovered mcp tool and plan gate each yield one violation', () => {
    const f = facts({ pages: ['/nope'], mcpTools: ['merchant_x'], planGates: ['seo'] });
    expect(ids(f, [entry({ api: [] })])).toEqual(['page-uncovered|/nope', 'tool-uncovered|merchant_x', 'plangate-uncovered|seo']);
  });
  it('mcpTools undefined skips the tool check', () => {
    expect(ids(facts(), [entry({ api: [] })])).toEqual([]);
  });
  it('a claimed tool and gate are covered', () => {
    const e = entry({ api: [], mcpTool: 'merchant_x', planGate: 'seo' });
    expect(ids(facts({ mcpTools: ['merchant_x'], planGates: ['seo'] }), [e])).toEqual([]);
  });
});

it('an entry listing several mcp tools ("a; b") covers each', () => {
  const e = entry({ api: [], mcpTool: 'admin_list; admin_get' });
  expect(ids(facts({ mcpTools: ['admin_list', 'admin_get'] }), [e])).toEqual([]);
});

describe('pageMatches', () => {
  it('folds [id] and :id', () => expect(pageMatches('/stores/:id/x', '/stores/[storeId]/x')).toBe(true));
  it('exact otherwise', () => expect(pageMatches('/a', '/a/b')).toBe(false));
  it('ignores a trailing slash', () => expect(pageMatches('/a/', '/a')).toBe(true));
});
