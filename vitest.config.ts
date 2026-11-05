import { defineConfig } from 'vitest/config';

// parity/foundation-parity.test.ts is a TEMPLATE that runs inside a consumer (it needs foundation.lock.json); test/cli.test.ts runs it against a synced fixture.
export default defineConfig({ test: { include: ['packages/**/*.test.ts', 'test/**/*.test.ts'] } });
