import { test, expect } from '../fixtures';

// ---------------------------------------------------------------------------
// Public pages — redesigned chrome
// ---------------------------------------------------------------------------

test.describe('Deno App - Homepage (redesign)', () => {
  test('renders sticky pill header, hero, categories list, recent cards, KPI strip, footer', async ({ page }) => {
    await page.goto('/', { waitUntil: 'networkidle' });

    // Chrome — sticky header with brand + inline search + nav
    await expect(page.locator('.site-header')).toBeVisible();
    await expect(page.locator('.site-header .brand')).toContainText('DMOZSTYLE');
    await expect(page.locator('.site-header .hsearch input[name="q"]')).toBeVisible();

    // Hero block
    await expect(page.locator('.hero')).toBeVisible();
    await expect(page.locator('.hero .display, .hero h1')).toBeVisible();

    // SEC.01 categories list-rows
    const catRows = page.locator('li.list-row[data-kind="category"]');
    await expect(catRows.first()).toBeVisible();
    expect(await catRows.count()).toBeGreaterThanOrEqual(1);

    // SEC.02 cards (3-up grid)
    const cards = page.locator('.cards .card');
    await expect(cards.first()).toBeVisible();
    expect(await cards.count()).toBeGreaterThanOrEqual(1);

    // Footer with 4-column grid
    await expect(page.locator('.site-footer .footer-grid')).toBeVisible();
  });

  test('shows top-level categories with non-zero subtree counts', async ({ page }) => {
    await page.goto('/', { waitUntil: 'networkidle' });
    const rows = page.locator('li.list-row[data-kind="category"]');
    expect(await rows.count()).toBeGreaterThanOrEqual(3);

    const texts = await rows.allTextContents();
    const anyNonZero = texts.some((t) => {
      const m = t.match(/(\d+(?:,\d+)*)\s*links?/i);
      return m !== null && parseInt(m[1].replace(/,/g, ''), 10) > 0;
    });
    expect(anyNonZero).toBe(true);
  });
});

test.describe('Deno App - Category page (redesign)', () => {
  test('/category/arts shows cat-hero, list-rows, and pagination', async ({ page }) => {
    await page.goto('/category/arts', { waitUntil: 'networkidle' });

    // Crumbs visible
    await expect(page.locator('nav.crumbs').first()).toBeVisible();

    // Cat-hero with category title
    await expect(page.locator('.cat-hero')).toBeVisible();
    await expect(page.locator('.cat-hero .display, .cat-hero h1')).toContainText(/arts/i);

    // List-rows for either subcategories or links
    const rows = page.locator('li.list-row');
    expect(await rows.count()).toBeGreaterThanOrEqual(1);
  });

  test('container category /category/arts surfaces non-zero subtree counts', async ({ page }) => {
    await page.goto('/category/arts', { waitUntil: 'networkidle' });
    const linkRows = page.locator('li.list-row[data-kind="link"]');
    if (await linkRows.count() > 0) {
      // Listings present: pagination should appear
      await expect(page.locator('.pager').first()).toBeVisible();
    }
    // Either way, the hero meta-stack should advertise a non-zero indexed-link count
    const heroText = await page.locator('.cat-hero').textContent();
    const m = heroText?.match(/(\d+(?:,\d+)*)/g);
    expect(m && m.some((s) => parseInt(s.replace(/,/g, ''), 10) > 0)).toBe(true);
  });

  test('next page link advances to a different first listing', async ({ page }) => {
    await page.goto('/category/arts', { waitUntil: 'networkidle' });
    const firstSel = 'li.list-row[data-kind="link"] .ttl';
    // /category/arts may have zero direct link rows (only subcategories) —
    // count() first; textContent() on a 0-element locator hangs the test.
    if (await page.locator(firstSel).count() === 0) test.skip();
    const initial = await page.locator(firstSel).first().textContent();

    const next = page.locator('.pager a.next, .pager a:has-text("Next")').first();
    if (await next.count() === 0) test.skip();
    await next.click();
    await page.waitForLoadState('networkidle');

    const after = await page.locator(firstSel).first().textContent();
    expect(after).not.toBe(initial);
  });

  test('offset cap: deep page renders the cap message', async ({ page }) => {
    await page.goto('/category/arts?page=500', { waitUntil: 'networkidle' });
    await expect(page.locator('.banner.error, .banner').first()).toContainText(/OffsetTooLarge|Pagination/);
  });
});

test.describe('Deno App - Category toolbar (Slice 6)', () => {
  test('/category/arts renders cat-toolbar with density-seg + sort dropdown', async ({ page }) => {
    await page.goto('/category/arts', { waitUntil: 'networkidle' });
    // CSS Modules hash class names per build; match by stable substring.
    await expect(page.locator('[class*="_toolbar"]').first()).toBeVisible();
    const seg = page.locator('[role="group"][aria-label="Row density"]');
    await expect(seg).toBeVisible();
    await expect(page.locator('select[name="sort"]').first()).toBeVisible();
    expect(await seg.locator('button').count()).toBeGreaterThanOrEqual(3);
  });

  test('Category sort dropdown carries ?sort= when changed', async ({ page }) => {
    await page.goto('/category/arts', { waitUntil: 'networkidle' });
    const select = page.locator('select[name="sort"]').first();
    if (await select.count() === 0) test.skip();
    await Promise.all([
      page.waitForURL(/\bsort=az\b/, { timeout: 8000 }).catch(() => {}),
      select.selectOption('az'),
    ]);
    if (!page.url().includes('sort=az')) {
      await page.locator('form:has(select[name="sort"]) button[type="submit"]').first().click();
      await page.waitForLoadState('networkidle');
    }
    expect(page.url()).toContain('sort=az');
  });
});

test.describe('Deno App - Search facets (Slice 5)', () => {
  test('search returns category results for /search?q=music', async ({ page }) => {
    // Use a query known to return results in the seeded DMOZ data.
    // ("docker" returns no results in this corpus.) The redesigned search
    // renders a Categories results section (CategoriesSection) — the old
    // faceted sidebar with `_facets`/`_facet` classes was removed in a prior
    // redesign — so assert the category results themselves.
    await page.goto('/search?q=music', { waitUntil: 'networkidle' });
    const categoryLinks = page.locator('a[href^="/category/"]');
    expect(await categoryLinks.count()).toBeGreaterThanOrEqual(1);
  });

  test('Sort dropdown carries ?sort= when changed', async ({ page }) => {
    await page.goto('/search?q=docker', { waitUntil: 'networkidle' });
    const select = page.locator('select[name="sort"]');
    if (await select.count() === 0) test.skip();
    // selectOption fires the inline onchange in chromium, which auto-submits
    // the form. Wait for either the URL to change or a load to finish.
    await Promise.all([
      page.waitForURL(/\bsort=recent\b/, { timeout: 8000 }).catch(() => {}),
      select.selectOption('recent'),
    ]);
    // If the auto-submit didn't take, fall back to clicking Apply.
    if (!page.url().includes('sort=recent')) {
      await page.locator('form:has(select[name="sort"]) button[type="submit"]').click();
      await page.waitForLoadState('networkidle');
    }
    expect(page.url()).toContain('sort=recent');
  });

  test('Recent queries chip appears after a search', async ({ page }) => {
    // RecentQueries is a CSS-Module island — chip class is `_chip_<hash>`.
    const chipSel = 'a[class*="_chip"]';
    // First visit seeds localStorage with "archive".
    await page.goto('/search?q=archive', { waitUntil: 'networkidle' });
    // Second visit with a different q — both should now show as chips.
    await page.goto('/search?q=encyclopedia', { waitUntil: 'networkidle' });
    // Wait for the island to mount and read localStorage.
    await page.waitForFunction(
      (sel) => document.querySelectorAll(sel).length >= 2,
      chipSel,
      { timeout: 4000 },
    ).catch(() => {});
    expect(await page.locator(chipSel).count()).toBeGreaterThanOrEqual(1);
  });
});

test.describe('Deno App - Search (redesign)', () => {
  test('returns results for "cannabis" with mark-highlighted hits', async ({ page }) => {
    await page.goto('/search?q=cannabis', { waitUntil: 'networkidle' });

    // Search hero with pill input pre-populated
    const hero = page.locator('[class*="_hero_"]').first();
    await expect(hero).toBeVisible();
    const input = hero.locator('input[name="q"]');
    await expect(input).toHaveValue('cannabis');

    // Results — either categories list-rows or listings result articles
    const articles = page.locator('article.result');
    const catRows = page.locator('li.list-row[data-kind="category"]');
    const total = await articles.count() + await catRows.count();
    expect(total).toBeGreaterThanOrEqual(1);

    // Highlighting via <mark>
    if (await articles.count() > 0) {
      const marks = page.locator('article.result mark');
      expect(await marks.count()).toBeGreaterThanOrEqual(1);
    }
  });
});

test.describe('Deno App - Auth pages (redesign)', () => {
  test('login page has email + password fields and Sign-in button', async ({ page }) => {
    await page.goto('/auth/login', { waitUntil: 'networkidle' });
    await expect(page.locator('input[name="email"]')).toBeVisible();
    await expect(page.locator('input[name="password"]')).toBeVisible();
    const submit = page.locator('main form button[type="submit"]');
    await expect(submit).toBeVisible();
    await expect(submit).toContainText(/sign in/i);
  });

  test('register page has email, username, password, confirm', async ({ page }) => {
    await page.goto('/auth/register', { waitUntil: 'networkidle' });
    await expect(page.locator('input[name="email"]')).toBeVisible();
    await expect(page.locator('input[name="username"]')).toBeVisible();
    await expect(page.locator('input[name="password"]')).toBeVisible();
    await expect(page.locator('input[name="confirmPassword"]')).toBeVisible();
  });
});

// ---------------------------------------------------------------------------
// Link detail — new in Slice 2a
// ---------------------------------------------------------------------------

test.describe('Deno App - Link detail (Slice 2a)', () => {
  test('/link/:id renders shell + record + adjacent', async ({ page }) => {
    // Home-page cards now link directly to the external URL in a new tab,
    // so we navigate to /link/:id directly. Link id 1 is a stable seed.
    await page.goto('/link/1', { waitUntil: 'networkidle' });
    await expect(page).toHaveURL(/\/link\/\d+/);

    const shell = page.locator('[class*="_shell_"]').first();
    const aside = page.locator('[class*="_aside_"]').first();
    await expect(shell).toBeVisible();
    await expect(aside).toBeVisible();
    await expect(shell.locator('.display, h1').first()).toBeVisible();
    // Record aside surfaces: DMZ id, status (records default to "approved"),
    // and a "Submitted by" row defaulted to "—" for legacy imports.
    await expect(aside).toContainText(/DMZ-/);
    await expect(aside).toContainText(/Approved/);
    await expect(aside).toContainText(/Submitted by/);

    // Visit-site CTA
    const visit = shell.locator('a.btn:has-text("Visit site")').first();
    await expect(visit).toBeVisible();
    await expect(visit).toHaveAttribute('target', '_blank');
  });

  test('/link/9999999999 returns 404', async ({ page }) => {
    const resp = await page.goto('/link/9999999999', {
      waitUntil: 'networkidle',
    });
    expect(resp?.status()).toBe(404);
  });
});

// ---------------------------------------------------------------------------
// Static pages — new in Slice 1
// ---------------------------------------------------------------------------

test.describe('Deno App - Static pages (redesign)', () => {
  test('/about renders principles list-rows', async ({ page }) => {
    await page.goto('/about', { waitUntil: 'networkidle' });
    await expect(page.locator('main h1, main .display').first()).toBeVisible();
    const rows = page.locator('li.list-row');
    expect(await rows.count()).toBeGreaterThanOrEqual(3);
  });

  test('/privacy renders TOC and a numbered section', async ({ page }) => {
    await page.goto('/privacy', { waitUntil: 'networkidle' });
    await expect(page.locator('.legal .toc')).toBeVisible();
    const tocLinks = page.locator('.legal .toc a');
    expect(await tocLinks.count()).toBeGreaterThanOrEqual(3);
    await expect(page.locator('.legal article h2').first()).toBeVisible();
  });

  test('/terms renders TOC and a numbered section', async ({ page }) => {
    await page.goto('/terms', { waitUntil: 'networkidle' });
    await expect(page.locator('.legal .toc')).toBeVisible();
    await expect(page.locator('.legal article h2').first()).toBeVisible();
  });

  test('404 fallback renders 404 + suggestions', async ({ page }) => {
    const resp = await page.goto('/this-route-does-not-exist', {
      waitUntil: 'networkidle',
    });
    expect(resp?.status()).toBe(404);
    await expect(page.locator('.notfound .big')).toContainText('404');
    // Suggested categories list
    const rows = page.locator('li.list-row[data-kind="category"]');
    expect(await rows.count()).toBeGreaterThanOrEqual(1);
  });
});
