import { test } from '../fixtures';

// ---------------------------------------------------------------------------
// Responsive screenshots — fresh artefacts under e2e/screenshots/redesign-*
// ---------------------------------------------------------------------------

test.describe('Deno App - Redesign screenshots', () => {
  const dir = '/workspaces/zig-directory/e2e/screenshots';

  test('home @ 1280', async ({ page }) => {
    await page.setViewportSize({ width: 1280, height: 900 });
    await page.goto('/', { waitUntil: 'networkidle' });
    await page.screenshot({ path: `${dir}/redesign-home-1280.png`, fullPage: true });
  });

  test('home @ 768', async ({ page }) => {
    await page.setViewportSize({ width: 768, height: 1024 });
    await page.goto('/', { waitUntil: 'networkidle' });
    await page.screenshot({ path: `${dir}/redesign-home-768.png`, fullPage: true });
  });

  test('home @ 480', async ({ page }) => {
    await page.setViewportSize({ width: 480, height: 800 });
    await page.goto('/', { waitUntil: 'networkidle' });
    await page.screenshot({ path: `${dir}/redesign-home-480.png`, fullPage: true });
  });

  test('category @ 1280', async ({ page }) => {
    await page.setViewportSize({ width: 1280, height: 1100 });
    await page.goto('/category/arts', { waitUntil: 'networkidle' });
    await page.screenshot({ path: `${dir}/redesign-category-1280.png`, fullPage: true });
  });

  test('search @ 1280', async ({ page }) => {
    await page.setViewportSize({ width: 1280, height: 1100 });
    await page.goto('/search?q=archive', { waitUntil: 'networkidle' });
    await page.screenshot({ path: `${dir}/redesign-search-1280.png`, fullPage: true });
  });

  test('search faceted @ 1280', async ({ page }) => {
    await page.setViewportSize({ width: 1280, height: 1100 });
    // Seed a recent query so the chip row is visible on the next page.
    await page.goto('/search?q=python', { waitUntil: 'networkidle' });
    await page.goto('/search?q=docker&sort=recent', { waitUntil: 'networkidle' });
    await page.screenshot({ path: `${dir}/redesign-search-faceted-1280.png`, fullPage: true });
  });

  test('about @ 1280', async ({ page }) => {
    await page.setViewportSize({ width: 1280, height: 1100 });
    await page.goto('/about', { waitUntil: 'networkidle' });
    await page.screenshot({ path: `${dir}/redesign-about-1280.png`, fullPage: true });
  });

  test('login @ 1280', async ({ page }) => {
    await page.setViewportSize({ width: 1280, height: 900 });
    await page.goto('/auth/login', { waitUntil: 'networkidle' });
    await page.screenshot({ path: `${dir}/redesign-login-1280.png`, fullPage: true });
  });

  test('404 @ 1280', async ({ page }) => {
    await page.setViewportSize({ width: 1280, height: 900 });
    await page.goto('/this-does-not-exist', { waitUntil: 'networkidle' });
    await page.screenshot({ path: `${dir}/redesign-404-1280.png`, fullPage: true });
  });

  test('admin dashboard @ 1280', async ({ adminPage }) => {
    await adminPage.setViewportSize({ width: 1280, height: 1100 });
    await adminPage.goto('/admin', { waitUntil: 'networkidle' });
    await adminPage.screenshot({ path: `${dir}/redesign-admin-1280.png`, fullPage: true });
  });

  test('link detail @ 1280', async ({ page }) => {
    await page.setViewportSize({ width: 1280, height: 1100 });
    // Navigate via the homepage's first card so the screenshot reflects a real link.
    await page.goto('/', { waitUntil: 'networkidle' });
    await page.locator('.cards .card').first().click();
    await page.waitForLoadState('networkidle');
    await page.screenshot({ path: `${dir}/redesign-link-1280.png`, fullPage: true });
  });

  test('submit wizard step 1 @ 1280', async ({ adminPage }) => {
    await adminPage.setViewportSize({ width: 1280, height: 1000 });
    await adminPage.goto('/submit', { waitUntil: 'networkidle' });
    await adminPage.screenshot({ path: `${dir}/redesign-submit-step1-1280.png`, fullPage: true });
  });

  test('dashboard @ 1280', async ({ adminPage }) => {
    await adminPage.setViewportSize({ width: 1280, height: 1100 });
    await adminPage.goto('/dashboard', { waitUntil: 'networkidle' });
    await adminPage.screenshot({ path: `${dir}/redesign-dashboard-1280.png`, fullPage: true });
  });

  test('admin links with status filter @ 1280', async ({ adminPage }) => {
    await adminPage.setViewportSize({ width: 1280, height: 1100 });
    await adminPage.goto('/admin/links', { waitUntil: 'networkidle' });
    // Pick a category so the table renders with the Status column visible.
    const catSelect = adminPage.locator('select[name="category"]').first();
    const opts = await catSelect.locator('option').all();
    for (const opt of opts) {
      const v = await opt.getAttribute('value');
      if (v && v !== '0' && v !== '') {
        await catSelect.selectOption(v);
        await adminPage.locator('button[type="submit"]:has-text("Filter")').first().click();
        await adminPage.waitForLoadState('networkidle');
        break;
      }
    }
    await adminPage.screenshot({ path: `${dir}/redesign-admin-links-1280.png`, fullPage: true });
  });
});
