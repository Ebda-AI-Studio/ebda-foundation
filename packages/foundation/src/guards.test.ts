import { describe, expect, it } from 'vitest';
import { countRule, navIssues } from './guards';

describe('design guard rules', () => {
  it('G1 raw palette', () => {
    expect(countRule('G1', '<p className="text-red-500 bg-emerald-50/10">')).toBe(2);
    expect(countRule('G1', '<p className="text-destructive-ink bg-primary/10">')).toBe(0);
    expect(countRule('G1', 'className="hover:text-gray-900 dark:bg-blue-900/30"')).toBe(2);
    expect(countRule('G1', '// text-red-500 in a comment\nconst a = 1;')).toBe(0);
  });
  it('G2 one-off sizes', () => {
    expect(countRule('G2', 'className="text-[13px] sm:text-sm"')).toBe(1);
    expect(countRule('G2', 'className="text-xs"')).toBe(0);
  });
  it('G3 hex', () => {
    expect(countRule('G3', "style={{ color: '#a6b0ac' }}")).toBe(1);
    expect(countRule('G3', "href='#abc'")).toBe(0);
  });
  it('G4 bare rounded', () => {
    expect(countRule('G4', 'className="rounded border"')).toBe(1);
    expect(countRule('G4', 'className="rounded-md rounded-full"')).toBe(0);
    expect(countRule('G4', 'className="sm:rounded"')).toBe(1);
  });
  it('G5 tracking', () => {
    expect(countRule('G5', 'className="tracking-tight font-bold"')).toBe(1);
    expect(countRule('G5', 'className="tracking-normal"')).toBe(0);
  });
  it('G6 nav items', () => {
    const bad = '<Link data-ui="nav" className="flex min-h-9 rounded-lg" />';
    const good = '<Link data-ui="nav" className={navItemClasses({ kind: "rail", active })} />';
    expect(navIssues('a.tsx', bad, ['navItemClasses'])).toEqual(['a.tsx:1']);
    expect(navIssues('a.tsx', good, ['navItemClasses'])).toEqual([]);
  });
});
