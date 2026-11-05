// Auto-merge is bound to the ACTUAL diff, never to the declared class (review I-2 / security S2). A job of a
// pre-approved kind may merge only when every changed path is inside that kind's allowlist and no changed path looks
// sensitive, destructive, protected, or defines how tests run (S4). Anything outside = PR + one question.
import { DESTRUCTIVE, SENSITIVE } from './policy.mjs';

/** Paths a fix must never auto-merge: CI and repo governance (.github/, CODEOWNERS, .husky/), env, deploy config,
 *  migrations, container build, and AGENT INSTRUCTIONS (CLAUDE.md, AGENTS.md, GEMINI.md, .claude/, .agents/,
 *  .cursor/, .codex/, ...): an auto-merged edit there would steer every later hands run and developer session on the
 *  repo (re-review N-1). Per-repo extras (protectedPaths, e.g. os/** in the foundation repo) and any file the hands'
 *  own repo commands name are added by protectedFor(). */
export const PROTECTED = /(^|\/)(\.github\/|\.env|wrangler\.(json|jsonc|toml)$|migrations?\/|prisma\/schema|Dockerfile$|\.gitattributes$|\.gitmodules$|\.npmrc$|\.yarnrc|CODEOWNERS$|\.husky\/|(CLAUDE|AGENTS|GEMINI|COPILOT)\.md$|\.(claude|agents|cursor|codex|windsurf|continue|aider[^/]*)(\/|$)|\.cursorrules$|\.windsurfrules$|\.clinerules)/i;

/** Simple glob -> RegExp ("**" any depth, "*" one segment). Anchored at the repo root. */
export function globToRegExp(glob) {
  const esc = String(glob).replace(/[.+^${}()|[\]\\]/g, '\\$&').replace(/\*\*\/?/g, '\u0000').replace(/\*/g, '[^/]*').replace(/\?/g, '[^/]').replace(/\u0000/g, '.*');
  return new RegExp(`^${esc}$`);
}

/**
 * Extra protected paths for one repo: its config's protectedPaths globs, plus every repo-relative file the hands' own
 * commands (install / test / format / mergeGate) name, so a fix can never rewrite what the hands execute or read.
 */
export function protectedFor(repoCfg = {}) {
  const res = (repoCfg.protectedPaths ?? []).map(globToRegExp);
  const named = new Set();
  for (const k of ['install', 'test', 'format', 'mergeGate']) {
    for (const a of repoCfg[k] ?? []) {
      if (/^\{|^-|^[a-z]+$/i.test(a) && !a.includes('/') && !/\.[a-z0-9]+$/i.test(a)) continue; // flags, placeholders, bare words
      const p = a.replace(/^\.\//, '');
      if (!p.startsWith('/') && !p.includes('{') && !p.includes('..')) named.add(p);
    }
  }
  return [...res, ...[...named].map((p) => new RegExp(`^${p.replace(/[.+^${}()|[\]\\*?]/g, '\\$&')}$`))];
}

/** Files that define WHAT the allowed test command runs (S4). Touching one = question. package.json is special-cased
 *  for dependency bumps (only dependency fields may change). */
export const TEST_DEFINITION = /(^|\/)(package\.json|(vitest|jest|playwright|cypress|karma|mocha|ava|babel|tsup|vite|webpack|rollup|turbo|nx|lerna)\.config\.[cm]?[jt]s$|jest\.config\.json|\.mocharc[^/]*|pytest\.ini|tox\.ini|setup\.cfg|conftest\.py|pyproject\.toml|Makefile|justfile|turbo\.json|nx\.json|tsconfig[^/]*\.json|\.nvmrc|\.node-version)$/;

const MANIFESTS = /(^|\/)(package\.json|package-lock\.json|npm-shrinkwrap\.json|yarn\.lock|pnpm-lock\.yaml|bun\.lockb?|requirements[^/]*\.txt|poetry\.lock|Pipfile\.lock|go\.mod|go\.sum|Cargo\.toml|Cargo\.lock|Gemfile\.lock|composer\.lock)$/;
const DOCS = /(^|\/)[^/]+\.(md|mdx)$|^docs\//;
const TESTS = /(^|\/)(__tests__|tests?|spec|e2e)\/|\.(test|spec)\.[cm]?[jt]sx?$|_test\.(go|py)$|(^|\/)test_[^/]+\.py$/;

export const KIND_PATHS = {
  docs: DOCS,
  'dep-bump': MANIFESTS,
  'dependency-advisory': MANIFESTS,
  'cve-bump': MANIFESTS,
  'lockfile-drift': MANIFESTS,
  test: TESTS,
  tests: TESTS,
  'flaky-test': TESTS,
  // lint / format: any non-sensitive path, but ONLY when the diff is verified formatting-only (job.mjs)
  lint: /./,
  'lint-autofix': /./,
  format: /./,
};
export const FORMAT_KINDS = new Set(['lint', 'lint-autofix', 'format']);
const DEP_KINDS = new Set(['dep-bump', 'dependency-advisory', 'cve-bump', 'lockfile-drift']);
const DEP_FIELDS = new Set(['dependencies', 'devDependencies', 'optionalDependencies', 'peerDependencies', 'overrides', 'resolutions', 'pnpm']);

/** package.json: true when only dependency fields differ (scripts, test config, bin, etc. are untouched). */
export function packageJsonDepsOnly(baseText, newText) {
  let a;
  let b;
  try {
    a = JSON.parse(baseText);
    b = JSON.parse(newText);
  } catch {
    return false;
  }
  const keys = new Set([...Object.keys(a ?? {}), ...Object.keys(b ?? {})]);
  for (const k of keys) {
    if (DEP_FIELDS.has(k)) {
      if (k === 'pnpm') {
        // pnpm.overrides only
        const pa = { ...(a.pnpm ?? {}) };
        const pb = { ...(b.pnpm ?? {}) };
        delete pa.overrides;
        delete pb.overrides;
        if (JSON.stringify(pa) !== JSON.stringify(pb)) return false;
      }
      continue;
    }
    if (JSON.stringify(a[k]) !== JSON.stringify(b[k])) return false;
  }
  return true;
}

/**
 * changes: [{ path, type: 'write'|'delete', base?: Buffer|null, buf?: Buffer }]. Returns { ok, reason }.
 * ok = every path is allowed for the kind AND nothing sensitive/destructive/protected/test-defining is touched.
 */
export function diffAllowsAutoMerge(kind, changes, extraProtected = []) {
  const k = String(kind ?? '').toLowerCase();
  const allow = KIND_PATHS[k];
  if (!allow) return { ok: false, reason: `class ${k} has no path allowlist` };
  if (!changes.length) return { ok: false, reason: 'empty diff' };
  for (const c of changes) {
    const p = c.path;
    const lp = p.toLowerCase();
    if (!allow.test(p)) return { ok: false, reason: `${p} is outside what a ${k} fix may change` };
    if (PROTECTED.test(p) || extraProtected.some((re) => re.test(p))) return { ok: false, reason: `the fix touches ${p}` };
    if (DESTRUCTIVE.test(lp) || SENSITIVE.test(lp)) return { ok: false, reason: `${p} is a sensitive path` };
    if (TEST_DEFINITION.test(p)) {
      const depsOnly = DEP_KINDS.has(k) && /(^|\/)package\.json$/.test(p) && c.type === 'write' && c.base && packageJsonDepsOnly(c.base.toString('utf8'), c.buf.toString('utf8'));
      if (!depsOnly) return { ok: false, reason: `${p} defines how tests run` };
    }
    if (c.type === 'delete' && !FORMAT_KINDS.has(k) && !DOCS.test(p)) return { ok: false, reason: `the fix deletes ${p}` };
  }
  return { ok: true, reason: `every changed path fits ${k}` };
}

/** True when the diff touches a file that defines the test command (beyond a deps-only package.json bump). */
export function touchesTestDefinition(changes, kind) {
  return changes.some((c) => TEST_DEFINITION.test(c.path) && !(DEP_KINDS.has(String(kind)) && /(^|\/)package\.json$/.test(c.path) && c.type === 'write' && c.base && packageJsonDepsOnly(c.base.toString('utf8'), c.buf.toString('utf8'))));
}

// Built-in secret scan (always runs; gitleaks runs too when installed). A hit blocks the push.
const SECRET_PATTERNS = [
  ['GitHub token', /\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36}\b|\bgithub_pat_[A-Za-z0-9_]{60,}\b/],
  ['Anthropic key', /\bsk-ant-[A-Za-z0-9_-]{20,}/],
  ['AWS access key', /\b(AKIA|ASIA)[0-9A-Z]{16}\b/],
  ['private key', /-----BEGIN [A-Z ]*PRIVATE KEY-----/],
  ['Slack token', /\bxox[abposr]-[A-Za-z0-9-]{10,}/],
  ['Stripe live key', /\b(sk|rk)_live_[A-Za-z0-9]{20,}/],
  ['Google API key', /\bAIza[0-9A-Za-z_-]{35}\b/],
  ['Telegram bot token', /\b\d{8,10}:[A-Za-z0-9_-]{35}\b/],
  ['generic credential assignment', /(api[_-]?key|secret|token|passw(or)?d)["']?\s*[:=]\s*["'][A-Za-z0-9+/_=-]{24,}["']/i],
];

/** Returns the names of the patterns that hit (never the matched text). */
export function scanSecrets(text) {
  const s = String(text ?? '');
  return SECRET_PATTERNS.filter(([, re]) => re.test(s)).map(([n]) => n);
}
