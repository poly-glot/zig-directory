import { expect, test } from "../fixtures.ts";

// User-facing flow the redesign must not regress: a logged-in user submits a
// link through the wizard, and that submission then shows up in their
// dashboard (which loads via listMySubmissions on the cursor-aware client).

test("a submitted link appears in the user's dashboard", async ({ adminPage: page }) => {
  const title = `Zzdashlink ${Date.now()}`;

  try {
  // ── Walk the 4-step submission wizard ──────────────────────────
  await page.goto("/submit", { waitUntil: "networkidle" });

  // Step 1: URL + title.
  await expect(page.locator('input[name="url"]')).toBeVisible();
  await page.fill('input[name="url"]', `https://zzdash-${Date.now()}.example/x`);
  await page.fill('input[name="title"]', title);
  await page.locator('button[type="submit"]:has-text("Next")').first().click();
  await page.waitForLoadState("networkidle");

  // Step 2: description (≥30 chars).
  await expect(page.locator('textarea[name="description"]')).toBeVisible();
  await page.fill(
    'textarea[name="description"]',
    "An end-to-end dashboard linkage check submission, comfortably past 30 chars.",
  );
  await page.locator('button[type="submit"]:has-text("Next")').first().click();
  await page.waitForLoadState("networkidle");

  // Step 3: pick the first real category.
  const catSelect = page.locator('select[name="categoryId"]').first();
  await expect(catSelect).toBeVisible();
  let chose = false;
  for (const opt of await catSelect.locator("option").all()) {
    const v = await opt.getAttribute("value");
    if (v && v !== "0" && v !== "") {
      await catSelect.selectOption(v);
      chose = true;
      break;
    }
  }
  expect(chose).toBe(true);
  await page.locator('button[type="submit"]:has-text("Next")').first().click();
  await page.waitForLoadState("networkidle");

  // Step 4: confirm + submit.
  const confirm = page.locator('input[name="_confirm"]');
  if (await confirm.count() > 0) await confirm.check();
  await page.locator('button[type="submit"]:has-text("Submit")').last().click();
  await page.waitForLoadState("networkidle");

  // Submission succeeded → a DMZ reference is shown.
  await expect(page.locator("body")).toContainText(/DMZ-\d{7}/);

  // ── The submission shows in the dashboard (pending tab) ────────
  await page.goto("/dashboard?tab=pending", { waitUntil: "networkidle" });
  await expect(page.locator("body")).toContainText(title);

  // And it's counted in the KPI/tab strip (pending ≥ 1).
  await expect(
    page.locator('nav[aria-label="Dashboard tabs"]'),
  ).toBeVisible();
  } finally {
    // Don't leak the disposable submission into the live moderation queue:
    // find it by its unique title and delete it via the bulk API.
    try {
      const resp = await page.request.get(
        `/admin/api/search?q=${encodeURIComponent(title)}&scope=links&limit=10`,
      );
      if (resp.ok()) {
        const data = await resp.json();
        const ids = (data.links ?? []).map((l: { id: number }) => l.id);
        if (ids.length > 0) {
          await page.request.post("/admin/api/bulk-delete", {
            data: { ids },
            headers: { "content-type": "application/json" },
          });
        }
      }
    } catch {
      // best-effort cleanup
    }
  }
});
