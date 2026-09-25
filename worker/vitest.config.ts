import { cloudflareTest } from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

// Tests declare their own bindings instead of reading wrangler.jsonc, so the
// deployment's settings (Worker name, vars such as CONFIG_KEY) never change
// what the tests exercise. Keep compatibilityDate in sync with wrangler.jsonc.
export default defineConfig({
  plugins: [
    cloudflareTest({
      main: "./src/index.ts",
      miniflare: {
        compatibilityDate: "2026-08-01",
        kvNamespaces: ["CONFIG_KV"],
        bindings: { CLIENT_KEY: "test-client-key" },
      },
    }),
  ],
});
