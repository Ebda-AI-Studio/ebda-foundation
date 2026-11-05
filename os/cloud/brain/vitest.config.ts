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
          INGEST_TOKEN: 'test-ingest-token',
          TELEGRAM_WEBHOOK_SECRET: 'test-tg-secret',
          TELEGRAM_CHAT_ID: '4242',
          TELEGRAM_BOT_TOKEN: 'test-bot-token',
          OS_ORGS: 'org-a org-b',
          HEALTH_TARGETS: '[{"url":"https://api.example.test/health","kind":"api"},{"url":"https://shop.example.test/checkout","kind":"money"}]',
        },
      },
    }),
  ],
  test: { include: ['test/**/*.test.ts'] },
});
