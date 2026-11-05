#!/usr/bin/env node
// Engine-free Dockerfile validation (the host has no Docker daemon; Apple `container` builds are optional).
// Checks: known instructions + line continuations, base image pinned by digest, every ARG used in FROM declared,
// multi-stage, COPY sources exist in the build context (os/), no credential baked in (ENV/ARG/RUN), non-root USER,
// exec-form ENTRYPOINT, pinned tool versions. Exit 1 with the problems listed.
import { existsSync, readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const CONTEXT = resolve(HERE, '..', '..'); // os/

export function checkDockerfile(text, context = CONTEXT) {
  const problems = [];
  const KNOWN = new Set(['FROM', 'RUN', 'CMD', 'LABEL', 'EXPOSE', 'ENV', 'ADD', 'COPY', 'ENTRYPOINT', 'VOLUME', 'USER', 'WORKDIR', 'ARG', 'ONBUILD', 'STOPSIGNAL', 'HEALTHCHECK', 'SHELL']);
  const logical = [];
  let cur = '';
  for (const raw of text.split('\n')) {
    const line = raw.replace(/\s+$/, '');
    if (!cur && (line.trim() === '' || line.trim().startsWith('#'))) continue;
    if (line.endsWith('\\')) {
      cur += line.slice(0, -1) + ' ';
      continue;
    }
    logical.push((cur + line).trim());
    cur = '';
  }
  if (cur) problems.push('dangling line continuation at end of file');
  const args = new Map();
  const froms = [];
  let user = null;
  let entry = null;
  for (const l of logical) {
    const [ins, ...rest] = l.split(/\s+/);
    const I = ins.toUpperCase();
    const body = rest.join(' ');
    if (!KNOWN.has(I)) problems.push(`unknown instruction: ${ins}`);
    if (I === 'ARG') {
      const [k, v] = body.split('=');
      args.set(k, v ?? '');
    }
    if (I === 'FROM') {
      froms.push(body);
      const img = body.split(/\s+/)[0].replace(/\$\{(\w+)\}/g, (_, k) => args.get(k) ?? `\${${k}}`);
      if (img.includes('${')) problems.push(`FROM uses an undeclared ARG: ${body}`);
      else if (!froms.slice(0, -1).some((f) => f.split(/\s+AS\s+/i)[1] === img) && !/@sha256:[0-9a-f]{64}$/.test(img)) problems.push(`base image not pinned by digest: ${img}`);
    }
    if (I === 'COPY' && !body.startsWith('--from=')) {
      const parts = body.split(/\s+/).filter((p) => !p.startsWith('--'));
      for (const src of parts.slice(0, -1)) if (!existsSync(join(context, src))) problems.push(`COPY source missing in context os/: ${src}`);
    }
    if ((I === 'ENV' || I === 'ARG') && /(TOKEN|SECRET|PASSWORD|API_KEY)\w*=\S+/i.test(body)) problems.push(`credential-like value baked into the image: ${l.slice(0, 80)}`);
    if (I === 'RUN' && /(ghp_|github_pat_|sk-ant-|CLAUDE_CODE_OAUTH_TOKEN=)/.test(body)) problems.push('credential in a RUN line');
    if (I === 'USER') user = body;
    if (I === 'ENTRYPOINT') entry = body;
  }
  if (froms.length < 2) problems.push('expected a multi-stage build');
  if (!user || /^(root|0)(:|$)/.test(user)) problems.push('final stage must switch to a non-root USER');
  if (!entry) problems.push('no ENTRYPOINT');
  else {
    try {
      if (!Array.isArray(JSON.parse(entry))) throw new Error();
    } catch {
      problems.push('ENTRYPOINT must be exec form (JSON array)');
    }
  }
  if (!/CLAUDE_CODE_VERSION=\d+\.\d+\.\d+/.test(text)) problems.push('Claude Code version not pinned');
  if (!/GH_VERSION=\d+\.\d+\.\d+/.test(text) || !/sha256sum -c/.test(text)) problems.push('gh not pinned + checksum-verified');
  return problems;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const p = checkDockerfile(readFileSync(join(HERE, 'Dockerfile'), 'utf8'));
  if (p.length) {
    console.error(`Dockerfile: ${p.length} problem(s)\n- ${p.join('\n- ')}`);
    process.exit(1);
  }
  console.log('Dockerfile: OK (engine-free checks)');
}
