import { expect, test } from "../fixtures.ts";

// End-to-end coverage of the /admin pages redesign: search, filter chips,
// cursor pagination, status badge, bulk actions (approve/reject + delete with
// type-to-confirm), and the categories breadcrumb. Mutating tests operate on
// disposable links they create + clean up, never on real moderation data.

const SEED_SUBCATEGORY = 447; // Anime (under Arts) — a non-root seed category.

test.describe("admin redesign — /admin/links", () => {
  test("search box debounces and writes ?q= to the URL", async ({ adminPage: page }) => {
    await page.goto("/admin/links", { waitUntil: "networkidle" });
    await page.locator(".admin-search-bar input").fill("computer");
    await page.waitForURL(/[?&]q=computer/, { timeout: 8000 });
    expect(new URL(page.url()).searchParams.get("q")).toBe("computer");
  });

  test("filter chip click switches status", async ({ adminPage: page }) => {
    await page.goto("/admin/links", { waitUntil: "networkidle" });
    await page.locator(".admin-chips a", { hasText: "Pending" }).first().click();
    await page.waitForURL(/[?&]status=pending/, { timeout: 8000 });
    expect(new URL(page.url()).searchParams.get("status")).toBe("pending");
  });

  test("status badge reveals inline transitions on hover", async ({ adminPage: page }) => {
    await page.goto("/admin/links", { waitUntil: "networkidle" });
    const badge = page.locator(".status-badge").first();
    await expect(badge).toBeVisible();
    await badge.hover();
    await expect(badge.locator("button").first()).toBeVisible();
  });

  test("cursor paginator: Next advances, Prev returns, Prev disabled on page 1", async ({ adminPage: page }) => {
    await page.goto("/admin/links", { waitUntil: "networkidle" });
    const prev = page.locator(".admin-paginator a", { hasText: "Prev" });
    const next = page.locator(".admin-paginator a", { hasText: "Next" });
    await expect(prev).toHaveAttribute("aria-disabled", "true");
    // The full corpus has >50 links, so Next is live on page 1.
    await expect(next).not.toHaveAttribute("aria-disabled", "true");
    await next.click();
    await page.waitForURL(/[?&]after_id=\d+/, { timeout: 8000 });
    await expect(
      page.locator(".admin-paginator a", { hasText: "Prev" }),
    ).not.toHaveAttribute("aria-disabled", "true");
    await page.locator(".admin-paginator a", { hasText: "Prev" }).click();
    await page.waitForLoadState("networkidle");
    await expect(
      page.locator(".admin-paginator a", { hasText: "Prev" }),
    ).toHaveAttribute("aria-disabled", "true");
  });

  // Create N disposable links sharing a unique searchable token; return the
  // token. (createLink defaults to approved status.)
  async function seedLinks(
    request: import("@playwright/test").APIRequestContext,
    n: number,
  ): Promise<string> {
    const token = "zzpwbulk" + Date.now() + Math.floor(Math.random() * 1e6);
    for (let i = 0; i < n; i++) {
      await request.post("/admin/links", {
        form: {
          _action: "create",
          categoryId: String(SEED_SUBCATEGORY),
          url: `https://${token}-${i}.example/x`,
          title: `${token} item ${i}`,
          description: "",
        },
        maxRedirects: 0,
      });
    }
    return token;
  }

  // Best-effort teardown: find every link still carrying the token and delete
  // it via the bulk API. Runs in a `finally` so disposable links never leak
  // into the live DB even when the test body throws mid-way.
  async function cleanupToken(
    request: import("@playwright/test").APIRequestContext,
    token: string,
  ): Promise<void> {
    try {
      const resp = await request.get(
        `/admin/api/search?q=${token}&scope=links&limit=50`,
      );
      if (!resp.ok()) return;
      const data = await resp.json();
      const ids = (data.links ?? []).map((l: { id: number }) => l.id);
      if (ids.length > 0) {
        await request.post("/admin/api/bulk-delete", {
          data: { ids },
          headers: { "content-type": "application/json" },
        });
      }
    } catch {
      // best-effort — never fail the test on cleanup
    }
  }

  test("bulk: select rows → bulk bar → Reject all → success toast", async ({ adminPage: page }) => {
    const token = await seedLinks(page.request, 3);
    try {
      await page.goto(`/admin/links?q=${token}`, { waitUntil: "networkidle" });
      const checkboxes = page.locator("input[data-bulk-id]");
      await expect(checkboxes).toHaveCount(3);

      for (let i = 0; i < 3; i++) await checkboxes.nth(i).check();
      const bar = page.locator(".admin-bulk-bar");
      await expect(bar).toBeVisible();
      await expect(bar).toContainText("3 selected");

      // Reject all → toast confirms the bulk-status RPC landed. (The island
      // then auto-reloads ~600ms later; asserting the toast first avoids
      // racing that navigation.)
      await bar.locator("button", { hasText: "Reject all" }).click();
      await expect(page.locator(".admin-toast-host")).toContainText(/of 3/, {
        timeout: 8000,
      });
    } finally {
      await cleanupToken(page.request, token);
    }
  });

  test("bulk: Delete is gated by type-to-confirm, then removes the rows", async ({ adminPage: page }) => {
    const token = await seedLinks(page.request, 2);
    try {
      await page.goto(`/admin/links?q=${token}`, { waitUntil: "networkidle" });
      const checkboxes = page.locator("input[data-bulk-id]");
      await expect(checkboxes).toHaveCount(2);
      for (let i = 0; i < 2; i++) await checkboxes.nth(i).check();

      await page.locator(".admin-bulk-bar button", { hasText: "Delete" })
        .click();
      const modal = page.locator(".confirm-modal");
      await expect(modal).toBeVisible();
      const deleteBtn = modal.locator("button", { hasText: "Delete" });
      // Primary button disabled until the exact phrase is typed.
      await expect(deleteBtn).toBeDisabled();
      await modal.locator("input").fill("delete 2 links");
      await expect(deleteBtn).toBeEnabled();
      await deleteBtn.click();
      await expect(page.locator(".admin-toast-host")).toContainText(/of 2/, {
        timeout: 8000,
      });
    } finally {
      // The test deletes them itself on success; this catches the failure path.
      await cleanupToken(page.request, token);
    }
  });
});

test.describe("admin redesign — /admin/categories", () => {
  test("breadcrumb drill-down: Open a category, breadcrumb fills, crumb jumps back", async ({ adminPage: page }) => {
    await page.goto("/admin/categories", { waitUntil: "networkidle" });
    await expect(page.locator(".admin-breadcrumb")).toBeVisible();
    // Drill into the first category via its Open action.
    const open = page.locator("table.admin-table tbody tr a", { hasText: "Open" }).first();
    await expect(open).toBeVisible();
    await open.click();
    await page.waitForURL(/[?&]parent=\d+/, { timeout: 8000 });
    // The root crumb (my literal "Top") always links to the bare categories
    // URL — unambiguous even when a real category is also named "Top".
    const rootCrumb = page.locator('.admin-breadcrumb a[href="/admin/categories"]');
    await expect(rootCrumb).toBeVisible();
    await rootCrumb.click();
    await page.waitForLoadState("networkidle");
    expect(new URL(page.url()).searchParams.get("parent")).toBeNull();
  });

  test("category search returns matches and hides the breadcrumb", async ({ adminPage: page }) => {
    await page.goto("/admin/categories", { waitUntil: "networkidle" });
    await page.locator(".admin-search-bar input").fill("arts");
    // waitForURL already waits for the navigation to commit; the breadcrumb
    // assertion auto-retries, so no extra load-state wait is needed.
    await page.waitForURL(/[?&]q=arts/, { timeout: 8000 });
    await expect(page.locator(".admin-breadcrumb")).toHaveCount(0);
  });
});
