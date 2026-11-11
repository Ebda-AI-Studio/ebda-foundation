// The brain's tests run inside workerd (the production runtime) through @cloudflare/vitest-plugin, against the same
// wrangler.jsonc that deploys it. Secrets below are TEST values for the local miniflare only.
import { cloudflareTest } from '@cloudflare/vitest-plugin';
import { defineConfig } from 'vitest/config';

export default defineConfig({
  plugins: [
    cloudflareTest({
      wrangler: { configPath: './wrangler.jsonc' },
      miniflare: {
        bindings: {
          GH_WEBHOOK_SECRET: 'test-gh-secret',
          RELAY_SECRET: 'test-relay-secret',
          HANDS_TOKEN: 'test-hands-token',
          HANDS_MAC_TOKEN: 'test-mac-token',
          // the legacy tests exercise the weekly-plan (max) guard; the api-mode tests set their own env
          HANDS_CLAUDE_AUTH: 'max',
          // the committed config deploys with HANDS_HALT=1 (RR-halt); the pipeline tests exercise the un-halted paths
          // (the halt itself is covered by cost-abuse F-01, which sets it explicitly)
          HANDS_HALT: '0',
          INGEST_TOKEN: 'test-ingest-token',
          TELEGRAM_WEBHOOK_SECRET: 'test-tg-secret',
          TELEGRAM_CHAT_ID: '4242',
          TELEGRAM_BOT_TOKEN: 'test-bot-token',
          OS_ORGS: 'org-a org-b',
          SOCIAL_LINK_SECRET: 'test-social-link-secret',
          SOCIAL_DECIDE_TOKEN: 'test-social-decide-token',
          HEALTH_TARGETS: '[{"url":"https://api.example.test/health","kind":"api"},{"url":"https://shop.example.test/checkout","kind":"money"}]',
        },
      },
    }),
  ],
  test: { include: ['test/**/*.test.ts'] },
});
