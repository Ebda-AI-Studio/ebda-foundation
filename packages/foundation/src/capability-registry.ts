import { capabilitySchema, type Capability, type GuardConfig, type Violation } from './capability';

const splitApi = (a: string): { method: string; path: string } => {
  const m = /^(\S+)\s+(.*)$/.exec(a.trim());
  return { method: (m ? m[1]! : '').toUpperCase(), path: m ? m[2]! : a };
};

/** Registry-internal rules. Pure: never throws on bad JSON (a schema failure is a violation and the entry is dropped). */
export function checkRegistry(files: { name: string; json: unknown }[], cfg: GuardConfig): { entries: Capability[]; violations: Violation[] } {
  const entries: Capability[] = [];
  const violations: Violation[] = [];
  const seen = new Set<string>();
  const add = (rule: string, key: string, message: string) => violations.push({ rule, key, message });
  const mustConfirm = cfg.mustConfirm.map((m) => ({ method: m.method?.toUpperCase(), re: new RegExp(m.pattern) }));

  for (const f of files) {
    const parsed = capabilitySchema.safeParse(f.json);
    if (!parsed.success) {
      add('schema', f.name, `${f.name}: ${parsed.error.issues.map((i) => `${i.path.join('.')} ${i.message}`).join('; ')}`);
      continue;
    }
    const e = parsed.data;
    if (f.name !== `${e.id}.capability.json`) add('id-filename', e.id, `${f.name} must be named ${e.id}.capability.json`);
    if (seen.has(e.id)) {
      add('id-duplicate', e.id, `${f.name} repeats id ${e.id}`);
      continue;
    }
    seen.add(e.id);
    entries.push(e);

    if (e.status === 'in-pr' && !e.pr) add('lifecycle', e.id, 'in-pr needs pr');
    if (e.status === 'planned' && !e.plan) add('lifecycle', e.id, 'planned needs plan');

    const apis = e.api.map(splitApi);
    // readOnlyPost excuses POST only, with its written reason; PUT/PATCH/DELETE are always writes.
    const writes = apis.some((a) => a.method !== 'GET' && !(a.method === 'POST' && e.readOnlyPost));
    if (e.policy === 'free' && writes) add('policy-free-writes', e.id, 'policy free but an api method writes (declare readOnlyPost with a reason if it only reads)');

    const needsConfirm = apis.some((a) => a.method === 'DELETE' || mustConfirm.some((m) => (!m.method || m.method === a.method) && m.re.test(a.path)));
    if (needsConfirm && e.policy !== 'confirm' && e.policy !== 'forbidden') add('policy-must-confirm', e.id, 'money, customer messaging and deletes need confirm or forbidden');

    if (e.undo.class === 'irreversible' && (e.policy === 'free' || e.policy === 'preview')) add('policy-irreversible', e.id, 'irreversible actions are always confirm or forbidden');

    const operatorOnly = e.roles.length > 0 && e.roles.every((r) => r === 'super_admin' || r === 'operator');
    if (operatorOnly) {
      if (e.policy !== 'forbidden') add('operator-forbidden', e.id, 'operator-only capability must be forbidden to the assistant');
      if (!e.operatorReason?.code) add('operator-reason', e.id, 'operator-only capability needs operatorReason.code');
    }

    const { ar, en } = e.questions;
    const ok = e.status === 'live' ? ar.length >= 3 && ar.length <= 6 && en.length >= 1 && en.length <= 3 : ar.length >= 1 && en.length >= 1;
    if (!ok) add('questions-count', e.id, `questions out of range (ar ${ar.length}, en ${en.length})`);

    if (e.undo.class === 'unclassified') add('undo-unclassified', e.id, 'undo class not set');
  }
  return { entries, violations };
}
