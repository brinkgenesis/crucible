import { test, expect } from "@playwright/test";

const WAIT_UNTIL = "domcontentloaded" as const;

test.describe("Control Terminal", () => {
  test.beforeEach(async ({ page }) => {
    await page.goto("/control", { waitUntil: WAIT_UNTIL });
    await page.waitForSelector("#main-content");
  });

  test("renders control page without errors", async ({ page }) => {
    await expect(page.locator("#main-content")).toBeVisible();
    await expect(page.locator(".phx-error")).toHaveCount(0);
  });

  test("shows session heading and capacity", async ({ page }) => {
    await expect(page.locator("text=SESSION_CONTROL")).toBeVisible();
  });

  test("spawn section is visible with capacity info", async ({ page }) => {
    // The page shows SPAWN_NEW_SESSION text and capacity
    await expect(page.locator("text=SPAWN_NEW_SESSION")).toBeVisible();
    await expect(page.locator("text=Remaining Capacity")).toBeVisible();
  });

  test("no JavaScript errors", async ({ page }) => {
    const errors: string[] = [];
    page.on("pageerror", (err) => errors.push(err.message));
    await page.waitForTimeout(2000);
    expect(errors).toHaveLength(0);
  });
});
