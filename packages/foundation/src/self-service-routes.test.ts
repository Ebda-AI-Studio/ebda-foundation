import { describe, expect, it } from 'vitest';
import { checkSelfServiceRoutes } from './self-service-routes';
import type { CodeFacts } from './capability-coverage';
import { entry } from '../../../test/helpers/capability-fixture';

const facts: CodeFacts = { pages: [], routes: [{ method: 'POST', path: '/platform/config', kind: 'operator' }] };
const ok = { id: 'platform.config', roles: ['super_admin' as const], policy: 'forbidden' as const, api: ['POST /platform/config'], operatorReason: { code: 'platform-config' as const, text: 't', validUnderRule: true } };
const run = (es = [entry(ok)], f = facts) => checkSelfServiceRoutes(f, es).map((v) => `${v.rule}|${v.key}`);

describe('checkSelfServiceRoutes', () => {
  it('an unclaimed operator route is superadmin-route-unreasoned', () => {
    expect(run([entry({ api: [] })])).toEqual(['superadmin-route-unreasoned|POST /platform/config']);
  });
  it('claimed with a code, forbidden and operator-only roles: clean', () => expect(run()).toEqual([]));
  it('claimed but policy confirm still fails', () => {
    expect(run([entry({ ...ok, policy: 'confirm' })])).toEqual(['superadmin-route-unreasoned|POST /platform/config']);
  });
  it('claimed with no reason code fails', () => {
    expect(run([entry({ ...ok, operatorReason: { code: null, text: 't', validUnderRule: true } })])).toEqual(['superadmin-route-unreasoned|POST /platform/config']);
  });
  it('claimed by an entry that also lists owner fails', () => {
    expect(run([entry({ ...ok, roles: ['super_admin', 'owner'] })])).toEqual(['superadmin-route-unreasoned|POST /platform/config']);
  });
  it('path spelling differences still match the claim', () => {
    expect(run([entry({ ...ok, api: ['post /platform/config/'] })])).toEqual([]);
  });
  it('merchant and public routes are ignored', () => {
    expect(run([entry({ api: [] })], { pages: [], routes: [{ method: 'GET', path: '/x', kind: 'merchant' }] })).toEqual([]);
  });
  it('validUnderRule false is operator-reason-invalid keyed by id', () => {
    expect(run([entry({ ...ok, operatorReason: { code: 'platform-config', text: 't', validUnderRule: false } })])).toEqual(['operator-reason-invalid|platform.config']);
  });
});
