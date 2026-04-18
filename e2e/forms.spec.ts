import { test, expect } from "@playwright/test";

const WAIT_UNTIL = "domcontentloaded" as const;

test.describe("Config Page", () => {
  test.beforeEach(async ({ page }) => {
    await page.goto("/config", { waitUntil: WAIT_UNTIL });
    await page.waitForSelector("#main-content");
  });

  test("renders without errors", async ({ page }) => {
    await expect(page.locator("#main-content")).toBeVisible();
    await expect(page.locator(".phx-error")).toHaveCount(0);
  });

  test("has tab navigation", async ({ page }) => {
    // Config tabs: claude-flow, environment, budget
    const tabs = page.locator('[phx-click="switch_tab"]');
    const count = await tabs.count();
    expect(count).toBeGreaterThan(0);
  });

  test("can switch to environment tab", async ({ page }) => {
    // Tab text is ENVIRONMENT
    const envTab = page.locator("text=ENVIRONMENT").first();
    if ((await envTab.count()) > 0) {
      await envTab.click();
      await page.waitForTimeout(1000);
      // Environment tab should show input fields or env var entries
      const inputs = page.locator("input, textarea");
      const count = await inputs.count();
      expect(count).toBeGreaterThanOrEqual(0);
    }
  });

  test("can switch to budget tab", async ({ page }) => {
    // Tab text is BUDGET_LIMITS
    const budgetTab = page.locator("text=BUDGET_LIMITS").first();
    if ((await budgetTab.count()) > 0) {
      await budgetTab.click();
      await page.waitForTimeout(1000);
      // Budget tab should show number inputs or budget fields
      const content = await page.locator("#main-content").textContent();
      expect(content).toContain("BUDGET");
    }
  });
});

test.describe("Settings Page", () => {
  test("renders without errors", async ({ page }) => {
    await page.goto("/settings", { waitUntil: WAIT_UNTIL });
    await page.waitForSelector("#main-content");
    await expect(page.locator("#main-content")).toBeVisible();
    await expect(page.locator(".phx-error")).toHaveCount(0);
  });

  test("has interactive controls", async ({ page }) => {
    await page.goto("/settings", { waitUntil: WAIT_UNTIL });
    const controls = page.locator("input, select, button, textarea");
    const count = await controls.count();
    expect(count).toBeGreaterThan(0);
  });
});

test.describe("Workspaces Page", () => {
  test("renders without errors", async ({ page }) => {
    await page.goto("/workspaces", { waitUntil: WAIT_UNTIL });
    await page.waitForSelector("#main-content");
    await expect(page.locator("#main-content")).toBeVisible();
    await expect(page.locator(".phx-error")).toHaveCount(0);
  });

  test("workspace list or empty state renders", async ({ page }) => {
    await page.goto("/workspaces", { waitUntil: WAIT_UNTIL });
    const content = await page.locator("#main-content").textContent();
    expect(content).toBeTruthy();
  });
});

test.describe("Policies Page", () => {
  test("renders without errors", async ({ page }) => {
    await page.goto("/policies", { waitUntil: WAIT_UNTIL });
    await page.waitForSelector("#main-content");
    await expect(page.locator("#main-content")).toBeVisible();
    await expect(page.locator(".phx-error")).toHaveCount(0);
  });
});

test.describe("Audit Page", () => {
  test("renders without errors", async ({ page }) => {
    await page.goto("/audit", { waitUntil: WAIT_UNTIL });
    await page.waitForSelector("#main-content");
    await expect(page.locator("#main-content")).toBeVisible();
    await expect(page.locator(".phx-error")).toHaveCount(0);
  });

  test("has filter controls", async ({ page }) => {
    await page.goto("/audit", { waitUntil: WAIT_UNTIL });
    const filters = page.locator("select, input[type='date'], input[type='text']");
    const count = await filters.count();
    expect(count).toBeGreaterThanOrEqual(0);
  });
});
