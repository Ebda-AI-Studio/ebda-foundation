// Own config so the repo-root vitest config (packages/**) is not inherited. Plain Node: every leaf is mocked.
import { defineConfig } from 'vitest/config';

export default defineConfig({ test: { include: ['test/**/*.test.mjs'], environment: 'node' } });
