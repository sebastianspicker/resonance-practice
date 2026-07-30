/** Default unit/integration Vitest configuration, excluding service E2E tests. */
import { configDefaults, defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    environment: 'node',
    setupFiles: ['tests/vitest.setup.ts'],
    fileParallelism: false,
    exclude: [...configDefaults.exclude, 'tests/e2e/**'],
    coverage: {
      provider: 'v8',
      reporter: ['text', 'text-summary', 'lcov'],
      reportsDirectory: './coverage',
      include: ['src/**/*.ts'],
      // The compiled entrypoint is exercised by CI's readiness probe and process-level E2E lane.
      exclude: ['src/types.ts', 'src/index.ts'],
      thresholds: {
        statements: 85,
        branches: 75,
        functions: 90,
        lines: 85,
      },
    },
  }
});
