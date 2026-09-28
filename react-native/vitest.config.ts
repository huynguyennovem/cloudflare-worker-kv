import { fileURLToPath } from 'node:url';
import { defineConfig } from 'vitest/config';

export default defineConfig({
  resolve: {
    alias: {
      // The peer dependency is never installed here; tests use an in-memory stub.
      '@react-native-async-storage/async-storage': fileURLToPath(
        new URL('./test/helpers/asyncStorageStub.ts', import.meta.url),
      ),
    },
  },
  test: {
    environment: 'node',
    include: ['test/**/*.test.ts'],
    restoreMocks: true,
  },
});
