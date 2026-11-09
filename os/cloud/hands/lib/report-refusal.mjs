// Best-effort "I refused to run" report to the brain, called by entrypoint.sh just before it exits 3 (the egress lock could not be
// applied). The brain turns it into a P1 message and puts the run's jobs back in the queue. A container that exits silently would
// leave only a failed-run row; this makes the platform gap (no CAP_NET_ADMIN, no ip6tables) loud on the first run.
// Runs as root (the rules only restrict the unprivileged uids), so the brain host is reachable. Never throws, never prints a token.
const { BRAIN_URL, HANDS_TOKEN, HANDS_RUN_ID } = process.env;
const reason = String(process.argv[2] ?? 'egress lock could not be applied').slice(0, 200);
if (BRAIN_URL && HANDS_TOKEN && HANDS_RUN_ID) {
  try {
    const r = await fetch(new URL('/hands/refused', BRAIN_URL), {
      method: 'POST',
      headers: { authorization: `Bearer ${HANDS_TOKEN}`, 'content-type': 'application/json' },
      body: JSON.stringify({ runId: HANDS_RUN_ID, reason }),
      signal: AbortSignal.timeout(10_000),
    });
    console.error(`hands: refusal reported to the brain (HTTP ${r.status})`);
  } catch (e) {
    console.error(`hands: could not report the refusal to the brain (${e?.name ?? 'error'})`);
  }
}
