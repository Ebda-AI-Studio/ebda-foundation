// Credential + process hygiene for one job (security S1/S4, review I-3).
//   - Every hands git call: hooks off, fsmonitor off, file:// protocol off, no credential helper, no system config, an
//     empty global config, no prompt. git only ever runs in trees the hands own (the fresh commit clone), never in the
//     tree Claude edited, except the clone + rev-parse BEFORE Claude runs.
//   - The GitHub token reaches exactly two kinds of process: git clone/fetch/push (through a per-job GIT_ASKPASS helper,
//     the token in that one process's env) and gh / the merge gate (GH_TOKEN in that one process's env). Never Claude,
//     never the repo's install/test/format commands.
//   - Untrusted commands (Claude, the repo's commands) get an allowlisted env and, in the container, run as a separate
//     unprivileged user (setpriv), so they cannot read the hands' memory, /proc environ or the commit tree.
import { chmod, mkdir, writeFile } from 'node:fs/promises';
import { join } from 'node:path';

export const SAFE_GIT = ['-c', 'core.hooksPath=/dev/null', '-c', 'core.fsmonitor=false', '-c', 'credential.helper=', '-c', 'core.sshCommand=false', '-c', 'protocol.file.allow=never', '-c', 'protocol.ext.allow=never'];

/** Env keys an untrusted command may inherit. Everything else (tokens included) is dropped. */
const PASS_ENV = ['PATH', 'LANG', 'LC_ALL', 'LC_CTYPE', 'TERM', 'TMPDIR', 'TZ', 'CI', 'NODE_ENV'];

export function untrustedEnv(env, extra = {}) {
  const out = {};
  for (const k of PASS_ENV) if (env[k] !== undefined) out[k] = env[k];
  return { ...out, ...extra };
}

/** Per-job private dir with an askpass helper and an empty global git config. Mode 700 (root-owned in the container). */
export async function prepareJobSecrets(tmpDir) {
  await mkdir(tmpDir, { recursive: true, mode: 0o700 });
  await chmod(tmpDir, 0o700);
  const askpass = join(tmpDir, 'askpass.sh');
  await writeFile(askpass, '#!/bin/sh\nprintf \'%s\\n\' "$HANDS_ASKPASS_TOKEN"\n', { mode: 0o700 });
  const gitconfig = join(tmpDir, 'gitconfig');
  await writeFile(gitconfig, '', { mode: 0o600 });
  return { askpass, gitconfig, ghConfigDir: join(tmpDir, 'gh') };
}

/** Environment for a hands git call. auth=true adds the askpass helper + the token for this one process. */
export function gitEnv(env, secrets, { token, auth = false } = {}) {
  return {
    PATH: env.PATH ?? '/usr/local/bin:/usr/bin:/bin',
    HOME: join(secrets.gitconfig, '..'),
    GIT_CONFIG_NOSYSTEM: '1',
    GIT_CONFIG_GLOBAL: secrets.gitconfig,
    GIT_TERMINAL_PROMPT: '0',
    ...(auth && token ? { GIT_ASKPASS: secrets.askpass, HANDS_ASKPASS_TOKEN: token } : {}),
  };
}

/**
 * Wrap an untrusted command so it runs as an unprivileged user (container) or unchanged (Mac).
 * role 'claude' (Claude Code, which holds the OAuth token in its memory) runs as the sandbox user; role 'tests' (the repo's own
 * test / format commands, i.e. code Claude may have written) runs as a DIFFERENT uid, so it cannot read the Claude process's
 * memory or /proc. Without HANDS_TEST_USER both use the sandbox user (Mac, older images).
 */
export function asSandbox(cfg, cmd, args, role = 'claude') {
  if (!cfg.sandboxUser) return [cmd, args];
  const u = role === 'tests' && cfg.testUser ? cfg.testUser : cfg.sandboxUser;
  return ['setpriv', ['--reuid', u, '--regid', u, '--init-groups', '--', cmd, ...args]];
}

/** Clone URL. With a token the user is x-access-token and the password comes from askpass (never in the URL). */
export function cloneUrl(host, slug, token) {
  const u = new URL(`${host.replace(/\/+$/, '')}/${slug}.git`);
  if (token && u.protocol === 'https:') u.username = 'x-access-token';
  return u.toString();
}
