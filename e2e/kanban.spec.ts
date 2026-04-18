import { test, expect } from "@playwright/test";

const WAIT_UNTIL = "domcontentloaded" as const;

test.describe("Kanban Board", () => {
  test.beforeEach(async ({ page }) => {
    await page.goto("/kanban", { waitUntil: WAIT_UNTIL });
    await page.waitForSelector("#main-content");
  });

  test("renders kanban page without errors", async ({ page }) => {
    await expect(page.locator("#main-content")).toBeVisible();
    await expect(page.locator(".phx-error")).toHaveCount(0);
  });

  test("shows kanban columns with headers", async ({ page }) => {
    // Columns: Ideation, Unassigned, To Do, In Progress, Review, Done
    for (const col of ["Ideation", "Unassigned", "To Do", "In Progress", "Review", "Done"]) {
      await expect(page.locator(`text=${col}`).first()).toBeVisible();
    }
  });

  test("shows action buttons", async ({ page }) => {
    // PATROL_SCAN, DEPLOY_TASK, SHOW_ARCHIVE buttons
    await expect(page.locator("text=DEPLOY_TASK")).toBeVisible();
    await expect(page.locator("text=PATROL_SCAN")).toBeVisible();
  });

  test("cards display with title and status", async ({ page }) => {
    // Cards show CLICK_TO_VIEW_PLAN text
    const cards = page.locator("text=CLICK_TO_VIEW_PLAN");
    const count = await cards.count();
    expect(count).toBeGreaterThan(0);
  });

  test("card shows plan and run info", async ({ page }) => {
    // Cards have RUN_ID and STATUS fields
    const runIds = page.locator("text=RUN_ID");
    const count = await runIds.count();
    expect(count).toBeGreaterThan(0);
  });

  test("no JavaScript errors on page", async ({ page }) => {
    const errors: string[] = [];
    page.on("pageerror", (err) => errors.push(err.message));
    await page.waitForTimeout(2000);
    expect(errors).toHaveLength(0);
  });
});
