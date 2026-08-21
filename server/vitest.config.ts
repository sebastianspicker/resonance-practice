/** Runs the compact server unit and boundary suite. */
import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    environment: 'node',
    setupFiles: ['tests/vitest.setup.ts'],
    fileParallelism: false,
  }
});
