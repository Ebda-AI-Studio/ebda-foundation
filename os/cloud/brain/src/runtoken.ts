// F-06b: per-run hands credentials. The container's bearer is HMAC-SHA256(HANDS_TOKEN, "run:<runId>"): valid for that run's id and the
// jobs inside it, nothing else. HANDS_TOKEN itself is only the HMAC key (it is never a bearer), and the Mac has its own HANDS_MAC_TOKEN
// that can only claim as `mac-local`. A leaked container token therefore cannot outcome another run's jobs, claim, or post usage for
// another run.
import { timingSafeEqualStr } from './relay';

const enc = new TextEncoder();

export async function runToken(secret: string, runId: string): Promise<string> {
  const key = await crypto.subtle.importKey('raw', enc.encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const sig = new Uint8Array(await crypto.subtle.sign('HMAC', key, enc.encode(`run:${runId}`)));
  return [...sig].map((b) => b.toString(16).padStart(2, '0')).join('');
}

export async function runTokenValid(secret: string | undefined, runId: string, presented: string): Promise<boolean> {
  if (!secret || !runId || !presented) return false;
  return timingSafeEqualStr(presented, await runToken(secret, runId));
}
