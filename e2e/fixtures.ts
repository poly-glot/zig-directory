import {
  test as base,
  expect,
  type BrowserContext,
  type Page,
} from '@playwright/test';

/** App base URL — kept here so individual spec files don't reinvent it. */
export const BASE_URL = 'http://127.0.0.1:8000';

/**
 * Log in as the seed admin user and persist `dmoz_session` on the
 * browser context so subsequent page.goto() calls are authenticated.
 *
 * The HTTP layer issues the cookie via Set-Cookie on a 303; we follow
 * up by registering the cookie on the test context (the request was
 * made with maxRedirects: 0 so the cookie isn't lost).
 */
export async function loginAsAdmin(page: Page, context: BrowserContext) {
  const response = await page.request.post(`${BASE_URL}/auth/login`, {
    form: { email: 'admin@dmoz.org', password: 'admin123' },
    maxRedirects: 0,
  });
  const setCookie = response.headers()['set-cookie'] ?? '';
  const match = setCookie.match(/dmoz_session=([^;]+)/);
  expect(match, 'Login should return a dmoz_session cookie').toBeTruthy();
  await context.addCookies([
    { name: 'dmoz_session', value: match![1], domain: '127.0.0.1', path: '/' },
  ]);
}

/**
 * `test` with an `adminPage` fixture: a Page pre-authenticated as the
 * seed admin. Replaces hand-rolled `beforeEach(loginAsAdmin)` blocks.
 */
export const test = base.extend<{ adminPage: Page }>({
  adminPage: async ({ page, context }, use) => {
    await loginAsAdmin(page, context);
    await use(page);
  },
});

export { expect };
