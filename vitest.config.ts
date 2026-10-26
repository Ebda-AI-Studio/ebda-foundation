import { defineConfig } from 'vitest/config';
export default defineConfig({
  test: { include: ['packages/*/src/**/*.test.ts', 'test/**/*.test.ts'], exclude: ['**/node_modules/**', 'test/.tmp/**'] },
});
