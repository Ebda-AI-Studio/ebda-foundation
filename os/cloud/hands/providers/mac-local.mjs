// Provider `mac-local` (fallback / on demand). The brain cannot reach into the Mac, so this provider is PULL-ONLY:
// the brain never starts a run on it. The Mac, when awake, runs `run-batch.mjs --claim` from launchd
// (providers/launchd/com.ebda.os.hands-mac-local.plist, installed by Task 5); the brain's POST /hands/claim applies the
// same usage guard and hands over queued nightly jobs. With HANDS_PROVIDER=mac-local the brain's nightly cron starts
// nothing and urgent jobs are queued for the Mac with one message. Worker-compatible ESM: no node: imports.
export const NAME = 'mac-local';

export function createMacLocalProvider() {
  return {
    name: NAME,
    pullOnly: true,
    async start() {
      throw new Error('mac-local is pull-only: the Mac claims queued work with POST /hands/claim');
    },
  };
}
