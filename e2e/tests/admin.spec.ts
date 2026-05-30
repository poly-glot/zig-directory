import { test, expect } from '../fixtures';

// ---------------------------------------------------------------------------
// Admin pages — all tests require admin auth (adminPage fixture).
// ---------------------------------------------------------------------------

test.describe('Deno App - Admin (requires auth)', () => {
  test('dashboard shows KPI strip with numeric values', async ({ adminPage }) => {
    await adminPage.goto('/admin', { waitUntil: 'networkidle' });
    const strip = adminPage.locator('.kpi-strip').first();
    await expect(strip).toBeVisible();
    const cells = strip.locator('.kpi-cell');
    expect(await cells.count()).toBeGreaterThanOrEqual(3);
    const firstValue = await cells.first().locator('.h1').textContent();
    expect(firstValue?.trim()).toMatch(/\S/);
  });

  test('categories admin renders inside admin-shell', async ({ adminPage }) => {
    await adminPage.goto('/admin/categories', { waitUntil: 'networkidle' });
    await expect(adminPage.locator('.admin-shell')).toBeVisible();
    await expect(adminPage.locator('.admin-tabs').first()).toBeVisible();

    // Root-cause fix for the prior flake: `networkidle` can resolve before the
    // server-rendered table body is attached to the DOM under suite-level load.
    // Wait explicitly for the table's first row (or, when categories are
    // empty, a list-row main link) to be visible BEFORE counting.
    const firstRow = adminPage
      .locator('table.admin-table tbody tr, main .list-row, main a')
      .first();
    await expect(firstRow).toBeVisible();

    const tableRows = await adminPage.locator('table.admin-table tbody tr').count();
    const items = await adminPage.locator('main a, main .list-row').count();
    expect(tableRows + items).toBeGreaterThanOrEqual(1);
  });

  test('links admin: + New link navigates to the create page', async ({ adminPage }) => {
    await adminPage.goto('/admin/links', { waitUntil: 'networkidle' });
    await expect(adminPage.locator('.admin-shell')).toBeVisible();
    // "+ New link" is now a link to a dedicated submit-style create page,
    // not an inline panel.
    await adminPage.getByRole('link', { name: '+ New link' }).click();
    await expect(adminPage).toHaveURL(/\/admin\/links\/new/);
    await expect(adminPage.locator('form input[name="url"]')).toBeVisible();
  });

  test('users admin shows admin@dmoz.org', async ({ adminPage }) => {
    await adminPage.goto('/admin/users', { waitUntil: 'networkidle' });
    await expect(adminPage.locator('.admin-shell')).toBeVisible();
    await expect(adminPage.getByText('admin@dmoz.org')).toBeVisible();
  });

  test('users admin role-cycle button reflects 3-state cycle', async ({ adminPage }) => {
    // Slice 4b: each non-self row renders a button whose label encodes
    // the NEXT role in the cycle user → editor → admin → user.
    await adminPage.goto('/admin/users', { waitUntil: 'networkidle' });

    // Find a row whose Actions cell carries a real button (i.e. not the
    // seeded self row, which renders "—"). Read the current role from
    // its 3rd <td>, derive the expected next-label, assert the button
    // text matches. This is invariant to whatever role state the seed
    // user happens to hold on any given run — no mutation, no ordering
    // assumptions, just the static cycle rule on what's already rendered.
    const actionableRow = adminPage
      .locator('table.admin-table tbody tr')
      .filter({ has: adminPage.locator('button[type="submit"]:not(.danger)') })
      .first();
    if (await actionableRow.count() === 0) test.skip();

    await expect(actionableRow).toBeVisible();
    const role = (await actionableRow.locator('td').nth(2).innerText())
      .trim()
      .toLowerCase();
    expect(['user', 'editor', 'admin']).toContain(role);

    const cycle: Record<string, string> = {
      user: 'Promote → editor',
      editor: 'Promote → admin',
      admin: 'Reset to user',
    };
    const button = actionableRow.locator('button[type="submit"]').first();
    await expect(button).toHaveText(cycle[role]);
    await expect(button).toHaveAttribute(
      'title',
      'Cycle role: user → editor → admin → user',
    );
  });

  test('links admin shows status filter chips + Status column header', async ({ adminPage }) => {
    // Use the known seed category id 447 (Anime under Arts). The redesign
    // replaced the <select name="status"> dropdown with URL-driven chips.
    await adminPage.goto('/admin/links?category=447', { waitUntil: 'networkidle' });
    const chips = adminPage.locator('.admin-chips');
    await expect(chips).toBeVisible();
    await expect(chips.locator('a', { hasText: 'Pending' })).toBeVisible();
    await expect(
      adminPage.locator('table.admin-table thead th', { hasText: 'Status' }),
    ).toBeVisible();
  });

  test('integrity admin renders index rows', async ({ adminPage }) => {
    await adminPage.goto('/admin/integrity', { waitUntil: 'networkidle' });
    await expect(adminPage.locator('h1').first()).toBeVisible();
    // Any tabular structure with at least one row, or list-rows
    const rows = await adminPage.locator('table tbody tr, .list-row').count();
    expect(rows).toBeGreaterThanOrEqual(1);
  });

  test('integrity Run-verifier-now is a button submit', async ({ adminPage }) => {
    await adminPage.goto('/admin/integrity', { waitUntil: 'networkidle' });
    const btn = adminPage.locator('button:has-text("Run verifier")').first();
    if (await btn.count() === 0) test.skip();
    await btn.click();
    await adminPage.waitForLoadState('networkidle');
    await expect(adminPage.locator('.banner.error')).toHaveCount(0);
  });

  test('shell shows attached tabs with active state', async ({ adminPage }) => {
    await adminPage.goto('/admin/links', { waitUntil: 'networkidle' });
    const tabs = adminPage.locator('.admin-tabs');
    await expect(tabs).toBeVisible();
    await expect(tabs.locator('a', { hasText: 'Links' })).toHaveClass(/active/);
  });

  test('PageHeader breadcrumb renders', async ({ adminPage }) => {
    await adminPage.goto('/admin/links', { waitUntil: 'networkidle' });
    // PageHeader renders a `nav.crumbs` breadcrumb + an `h1.display` title.
    const crumbs = adminPage.locator('nav[aria-label="Breadcrumb"]');
    await expect(crumbs).toContainText('Directory');
    await expect(crumbs).toContainText('Admin');
    await expect(adminPage.locator('h1.display')).toContainText('Links');
  });

  test('create-link page renders the submit-style form', async ({ adminPage }) => {
    await adminPage.goto('/admin/links/new', { waitUntil: 'networkidle' });
    await expect(adminPage.locator('h1.display')).toContainText('Create link');
    await expect(adminPage.locator('form input[name="url"]')).toBeVisible();
    await expect(adminPage.locator('form input[name="title"]')).toBeVisible();
  });

  test('create-category page renders the submit-style form', async ({ adminPage }) => {
    await adminPage.goto('/admin/categories/new', { waitUntil: 'networkidle' });
    await expect(adminPage.locator('h1.display')).toContainText('Create category');
    await expect(adminPage.locator('form input[name="name"]')).toBeVisible();
    await expect(adminPage.locator('form input[name="slug"]')).toBeVisible();
  });

  test('edit page can change status and category', async ({ adminPage }) => {
    // Use a seed link known to exist.
    await adminPage.goto('/admin/links/1/edit', { waitUntil: 'networkidle' });

    // Status <select> is visible and editable.
    await expect(adminPage.locator('select[name="status"]')).toBeVisible();

    // Drive the CategoryPicker through its visible UI. The picker is an
    // @preact/signals island: signal state only updates on real input events.
    // Use the "clear" button (rendered when a category is preselected) to
    // wipe the prefilled label, then type via keyboard so each keystroke
    // fires the onInput handler that drives the debounced search fetch.
    await adminPage.getByRole('button', { name: 'clear' }).click();
    const picker = adminPage.locator('#edit-category');
    await expect(picker).toBeVisible();
    await picker.focus();

    // Root-cause fix for the prior flake: visibility-with-bumped-timeout was
    // a band-aid. The picker debounces input and only renders results once
    // the /admin/api/category-search fetch resolves. Wait for that exact
    // response, then assert visibility on the now-loaded result — this
    // synchronises on what we actually depend on, not on a wall clock.
    const searchResponse = adminPage.waitForResponse(
      (resp) =>
        /\/admin\/api\/category-search\b/.test(resp.url()) && resp.status() === 200,
    );
    await adminPage.keyboard.type('anime', { delay: 50 });
    await searchResponse;

    const result = adminPage.locator('ul li button', { hasText: 'Anime' }).first();
    await expect(result).toBeVisible();
    await result.click();

    // Hidden select inside the picker should now carry the chosen id (447 or 27878).
    await expect(adminPage.locator('select[name="categoryId"]')).toHaveValue(/\d+/);

    await adminPage.locator('select[name="status"]').selectOption('approved');
    await adminPage.getByRole('button', { name: 'Save changes' }).click();

    await adminPage.waitForLoadState('networkidle');
    await expect(adminPage.locator('.banner.success')).toContainText('Link updated');
  });
});
