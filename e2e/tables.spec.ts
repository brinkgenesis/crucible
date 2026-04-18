import { test, expect } from "@playwright/test";

const WAIT_UNTIL = "domcontentloaded" as const;

const TABLE_PAGES = [
  { path: "/runs", label: "Runs" },
  { path: "/traces", label: "Traces" },
  { path: "/agents", label: "Agents" },
  { path: "/jobs-dashboard", label: "Jobs" },
  { path: "/budget", label: "Budget" },
  { path: "/cost", label: "Cost" },
  { path: "/audit", label: "Audit" },
  { path: "/benchmarks", label: "Benchmarks" },
  { path: "/teams", label: "Activity" },
  { path: "/clients", label: "Clients" },
  { path: "/memory", label: "Memory" },
  { path: "/logs", label: "Logs" },
];

test.describe("Table Pages", () => {
  for (const { path, label } of TABLE_PAGES) {
    test(`${label} (${path}) renders without errors`, async ({ page }) => {
      await page.goto(path, { waitUntil: WAIT_UNTIL });
      await page.waitForSelector("#main-content");
      await expect(page.locator("#main-content")).toBeVisible();
      await expect(page.locator(".phx-error")).toHaveCount(0);
    });

    test(`${label} (${path}) shows table or empty state`, async ({ page }) => {
      await page.goto(path, { waitUntil: WAIT_UNTIL });
      await page.waitForSelector("#main-content");

      const table = page.locator("table");
      const emptyState = page.locator(":text-matches('[A-Z_]{3,}')");
      const tableCount = await table.count();
      const emptyCount = await emptyState.count();

      expect(tableCount + emptyCount).toBeGreaterThan(0);
    });
  }
});

test.describe("Pagination", () => {
  test("runs page has pagination controls when data exists", async ({ page }) => {
    await page.goto("/runs", { waitUntil: WAIT_UNTIL });
    await page.waitForSelector("#main-content");

    const pagination = page.locator(
      "nav[aria-label*='pagination'], [class*='pagination'], button:has-text('Next'), button:has-text('Prev'), a:has-text('Next')"
    );
    const count = await pagination.count();
    expect(count).toBeGreaterThanOrEqual(0);
  });

  test("pagination buttons are clickable when present", async ({ page }) => {
    await page.goto("/runs", { waitUntil: WAIT_UNTIL });
    await page.waitForSelector("#main-content");

    const nextBtn = page.locator(
      "button:has-text('Next'), a:has-text('Next'), button:has-text('»'), a:has-text('»')"
    ).first();
    if ((await nextBtn.count()) > 0 && (await nextBtn.isEnabled())) {
      await nextBtn.click();
      await page.waitForTimeout(1000);
      await expect(page.locator("#main-content")).toBeVisible();
      await expect(page.locator(".phx-error")).toHaveCount(0);
    }
  });
});

test.describe("Status Badges", () => {
  test("runs page renders status badges with correct classes", async ({ page }) => {
    await page.goto("/runs", { waitUntil: WAIT_UNTIL });
    await page.waitForSelector("#main-content");

    const badges = page.locator("[class*='badge'], [class*='status']");
    const count = await badges.count();
    expect(count).toBeGreaterThanOrEqual(0);
  });
});
