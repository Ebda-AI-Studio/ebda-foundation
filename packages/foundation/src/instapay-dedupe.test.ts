import { describe, expect, it } from 'vitest';
import { D1DuplicateIndex, DEDUPE_SCHEMA_SQL, duplicateIndexContract, MemoryDuplicateIndex, type D1Like, type D1StatementLike } from './instapay-dedupe';

describe('MemoryDuplicateIndex', () => {
  duplicateIndexContract(async () => new MemoryDuplicateIndex(), { it, expect });
});

// the same contract on a REAL SQL engine (node:sqlite, Node >= 22.5) behind the D1 shape: INSERT OR IGNORE / changes semantics are real
let sqlite: typeof import('node:sqlite') | null = null;
try {
  sqlite = await import('node:sqlite');
} catch {
  sqlite = null;
}
function sqliteD1(calls: Array<{ sql: string; args: unknown[] }> = []): D1Like {
  const db = new sqlite!.DatabaseSync(':memory:');
  db.exec(DEDUPE_SCHEMA_SQL);
  let queue: Promise<void> = Promise.resolve();
  const stmt = (sql: string, args: unknown[] = []): D1StatementLike => ({
    bind: (...v) => stmt(sql, v),
    run: async () => {
      calls.push({ sql, args });
      return { meta: { changes: Number(db.prepare(sql).run(...(args as any[])).changes) } };
    },
    all: async <T,>() => {
      calls.push({ sql, args });
      return { results: db.prepare(sql).all(...(args as any[])) as T[] };
    },
  });
  return {
    prepare: (sql) => stmt(sql),
    // D1 serialises batches; so does this queue
    batch: (list) => {
      const run = async () => {
        db.exec('BEGIN');
        try {
          const out = [];
          for (const s of list) out.push(await s.run());
          db.exec('COMMIT');
          return out;
        } catch (e) {
          db.exec('ROLLBACK');
          throw e;
        }
      };
      const next = queue.then(run, run);
      queue = next.then(() => undefined, () => undefined);
      return next;
    },
  };
}

describe.skipIf(!sqlite)('D1DuplicateIndex on real SQLite', () => {
  duplicateIndexContract(async () => new D1DuplicateIndex(sqliteD1()), { it, expect });
  it('every statement is parameter-bound (no key or id is ever interpolated into SQL)', async () => {
    const calls: Array<{ sql: string; args: unknown[] }> = [];
    const d = new D1DuplicateIndex(sqliteD1(calls));
    await d.claim({ referenceKey: '123456789012', imageSha256: 'a'.repeat(64), product: 'chat', ownerId: 'o', paymentId: 'p' });
    await d.release({ referenceKey: '123456789012', imageSha256: 'a'.repeat(64), product: 'chat', ownerId: 'o', paymentId: 'p' });
    await d.burn({ referenceKey: '123456789012', imageSha256: 'a'.repeat(64), product: 'chat', ownerId: 'o', paymentId: 'p' });
    expect(calls.length).toBeGreaterThan(5);
    for (const c of calls) {
      expect(c.sql).not.toMatch(/123456789012|aaaaaaaa|'p'|'o'/);
      expect(c.sql.includes('?')).toBe(true);
    }
  });
  it('the schema CHECKs refuse an unknown kind or state', () => {
    const db = new sqlite!.DatabaseSync(':memory:');
    db.exec(DEDUPE_SCHEMA_SQL);
    expect(() => db.exec("INSERT INTO instapay_dedupe VALUES ('x','k','store','o','p','held',1)")).toThrow();
    expect(() => db.exec("INSERT INTO instapay_dedupe VALUES ('ref','k','store','o','p','weird',1)")).toThrow();
  });
  it('claim uses ONE batch for both inserts', async () => {
    let batches = 0;
    const inner = sqliteD1();
    const d = new D1DuplicateIndex({ prepare: inner.prepare, batch: async (l) => (batches++, inner.batch(l)) });
    await d.claim({ referenceKey: '123456789012', imageSha256: 'a'.repeat(64), product: 'store', ownerId: 'o', paymentId: 'p' });
    expect(batches).toBe(1);
  });
});
