import { defineConfig } from '@playwright/test';

/**
 * Playwright config — two projects:
 *
 * - `chromium` runs the normal feature suite under `tests/`.
 * - `cold-boot` runs `tests/cold-boot.spec.ts` only. It is isolated
 *   because the test SIGTERMs the dmozdb process and respawns it
 *   to measure boot latency — running it alongside the feature suite
 *   tears the database out from under the other tests.
 *
 * Caller is expected to have dmozdb + the Deno app already running on
 * 127.0.0.1:8080 and 127.0.0.1:8000 respectively before invoking
 * `npm test`. The cold-boot project assumes dmozdb at the standard
 * data directory and re-launches it; the feature project assumes
 * the existing instance stays up.
 */
export default defineConfig({
  testDir: './tests',
  timeout: 30_000,
  retries: 1,
  // Single worker: parallel files overload the Deno SSR layer in dev mode
  // (vite + Fresh) and cause cascading goto timeouts under 5-worker load.
  // The original single-file suite was implicitly serial; keep that. Each
  // test still gets a fresh browser context, so no shared state.
  workers: 1,
  use: {
    baseURL: 'http://127.0.0.1:8000',
    screenshot: 'only-on-failure',
    trace: 'on-first-retry',
  },
  projects: [
    {
      name: 'chromium',
      testIgnore: ['**/cold-boot.spec.ts'],
      use: { browserName: 'chromium', headless: true },
    },
    {
      // Runs AFTER chromium completes. The cold-boot test SIGTERMs the
      // dmozdb process and respawns it to measure boot latency — running
      // it before/alongside chromium would tear the database out from
      // under the feature suite.
      name: 'cold-boot',
      testMatch: ['**/cold-boot.spec.ts'],
      dependencies: ['chromium'],
      use: { browserName: 'chromium', headless: true },
      retries: 0,
    },
  ],
});
