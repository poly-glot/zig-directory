import { test, expect } from '../fixtures';

// ---------------------------------------------------------------------------
// Dashboard — new in Slice 4
// ---------------------------------------------------------------------------

test.describe('Deno App - /dashboard (Slice 4)', () => {
  test('unauthenticated GET /dashboard redirects to /auth/login', async ({ page }) => {
    await page.goto('/dashboard', { waitUntil: 'networkidle' });
    expect(page.url()).toContain('/auth/login');
    expect(page.url()).toContain('redirect=');
  });

  test('logged-in GET /dashboard shows tab strip with per-status counts', async ({ adminPage }) => {
    await adminPage.goto('/dashboard', { waitUntil: 'networkidle' });

    // Per-status counts now live in the TabStrip (the standalone kpi-strip
    // was removed in an earlier dashboard redesign).
    const tabs = adminPage.locator('nav[aria-label="Dashboard tabs"]');
    await expect(tabs).toBeVisible();
    // 5 tabs: All / Pending / Approved / Rejected / Account
    const tabLinks = tabs.locator('a');
    expect(await tabLinks.count()).toBe(5);
    await expect(tabLinks.first()).toContainText(/All/i);
  });

  test('Account tab renders displayName + bio fields', async ({ adminPage }) => {
    await adminPage.goto('/dashboard?tab=account', { waitUntil: 'networkidle' });
    await expect(adminPage.locator('input[name="displayName"]')).toBeVisible();
    await expect(adminPage.locator('textarea[name="bio"]')).toBeVisible();
    // Active tab marker — CSS Module `_active_<hash>` on the chosen <a>.
    await expect(
      adminPage.locator('nav[aria-label="Dashboard tabs"] a[class*="_active"]'),
    ).toContainText(/Account/i);
  });

  test('/profile redirects to /dashboard?tab=account', async ({ adminPage }) => {
    await adminPage.goto('/profile', { waitUntil: 'networkidle' });
    expect(adminPage.url()).toContain('/dashboard');
    expect(adminPage.url()).toContain('tab=account');
  });
});

// ---------------------------------------------------------------------------
// Submission wizard — new in Slice 3
// ---------------------------------------------------------------------------

test.describe('Deno App - /submit wizard (Slice 3)', () => {
  test('unauthenticated GET /submit redirects to /auth/login', async ({ page }) => {
    const resp = await page.goto('/submit', { waitUntil: 'networkidle' });
    // Fresh follows the redirect; final URL should be /auth/login with redirect query.
    expect(page.url()).toContain('/auth/login');
    expect(resp?.status()).toBeLessThan(500);
  });

  test('logged-in user walks 4 steps and lands on Done with a DMZ-* reference', async ({ adminPage }) => {
    const submissionTitle = 'Playwright Test Submission';
    try {
    await adminPage.goto('/submit', { waitUntil: 'networkidle' });
    // Step 1: URL + title
    await expect(adminPage.locator('input[name="url"]')).toBeVisible();
    await adminPage.fill('input[name="url"]', `https://example.test/${Date.now()}`);
    await adminPage.fill('input[name="title"]', submissionTitle);
    await adminPage.locator('button[type="submit"]:has-text("Next")').first().click();
    await adminPage.waitForLoadState('networkidle');

    // Step 2: description
    await expect(adminPage.locator('textarea[name="description"]')).toBeVisible();
    await adminPage.fill('textarea[name="description"]', 'A description that exceeds the 30-char minimum threshold.');
    await adminPage.locator('button[type="submit"]:has-text("Next")').first().click();
    await adminPage.waitForLoadState('networkidle');

    // Step 3: pick the first available category
    const catSelect = adminPage.locator('select[name="categoryId"]').first();
    await expect(catSelect).toBeVisible();
    // Choose a real option (the first that's not the placeholder)
    const options = await catSelect.locator('option').all();
    let chose = false;
    for (const opt of options) {
      const v = await opt.getAttribute('value');
      if (v && v !== '0' && v !== '') {
        await catSelect.selectOption(v);
        chose = true;
        break;
      }
    }
    expect(chose).toBe(true);
    await adminPage.locator('button[type="submit"]:has-text("Next")').first().click();
    await adminPage.waitForLoadState('networkidle');

    // Step 4: review + confirm + submit
    const confirm = adminPage.locator('input[name="_confirm"]');
    if (await confirm.count() > 0) await confirm.check();
    const submitBtn = adminPage.locator('button[type="submit"]:has-text("Submit")').last();
    await submitBtn.click();
    await adminPage.waitForLoadState('networkidle');

    // Done state shows DMZ-XXXXXXX reference number
    await expect(adminPage.locator('body')).toContainText(/DMZ-\d{7}/);
    } finally {
      // Don't leak the disposable submission(s) into the live moderation
      // queue — delete every link carrying the fixed test title.
      try {
        const resp = await adminPage.request.get(
          `/admin/api/search?q=${encodeURIComponent(submissionTitle)}&scope=links&limit=50`,
        );
        if (resp.ok()) {
          const data = await resp.json();
          const ids = (data.links ?? []).map((l: { id: number }) => l.id);
          if (ids.length > 0) {
            await adminPage.request.post('/admin/api/bulk-delete', {
              data: { ids },
              headers: { 'content-type': 'application/json' },
            });
          }
        }
      } catch {
        // best-effort cleanup
      }
    }
  });
});

// ---------------------------------------------------------------------------
// Profile (redesign)
// ---------------------------------------------------------------------------

test.describe('Deno App - Profile (redesign)', () => {
  test('shows the profile-card with displayName + bio fields', async ({ adminPage }) => {
    await adminPage.goto('/profile', { waitUntil: 'networkidle' });
    // /profile redirects to /dashboard?tab=account; the account form card is
    // the stable anchor (the standalone kpi-strip was removed in a redesign).
    // Two CSS-module-hashed cards exist (AccountForm + Editor-role panel).
    // Locate the AccountForm card by the field it contains rather than by
    // an unstable hashed class name.
    const accountCard = adminPage.locator('[class*="_card"]:has(input[name="displayName"])');
    await expect(accountCard).toBeVisible();
    await expect(accountCard.locator('input[name="displayName"]')).toBeVisible();
    await expect(accountCard.locator('textarea[name="bio"]')).toBeVisible();
  });

  test('admin viewer sees Editor/Admin role panel on dashboard Account tab', async ({ adminPage }) => {
    await adminPage.goto('/dashboard?tab=account', { waitUntil: 'networkidle' });
    // Slice 4b: Editor-role panel renders for editors and admins.
    await expect(adminPage.locator('body')).toContainText(/Admin role|Editor role/);
    await expect(adminPage.locator('body')).toContainText(/Active since/);
  });
});
