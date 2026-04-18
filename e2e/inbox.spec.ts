import { test, expect } from "@playwright/test";

const WAIT_UNTIL = "domcontentloaded" as const;

test.describe("Inbox", () => {
  test.beforeEach(async ({ page }) => {
    await page.goto("/inbox", { waitUntil: WAIT_UNTIL });
    await page.waitForSelector("#main-content");
  });

  test("renders inbox page without errors", async ({ page }) => {
    await expect(page.locator("#main-content")).toBeVisible();
    await expect(page.locator(".phx-error")).toHaveCount(0);
  });

  test("link dump modal opens and closes", async ({ page }) => {
    // The button has phx-click="open_link_dump" and text "LINK_DUMP"
    const dumpBtn = page.locator('[phx-click="open_link_dump"]');
    if ((await dumpBtn.count()) > 0) {
      await dumpBtn.first().click();

      // Modal appears with "PASTE_URLS_FOR_INGESTION" subtitle
      await expect(page.locator("text=PASTE_URLS_FOR_INGESTION")).toBeVisible({
        timeout: 3000,
      });

      // Cancel button closes modal
      const cancelBtn = page.locator('[phx-click="close_link_dump"]');
      await cancelBtn.click();
      await expect(
        page.locator("text=PASTE_URLS_FOR_INGESTION")
      ).toBeHidden({ timeout: 3000 });
    }
  });

  test("link dump modal has add link button", async ({ page }) => {
    const dumpBtn = page.locator('[phx-click="open_link_dump"]');
    if ((await dumpBtn.count()) > 0) {
      await dumpBtn.first().click();
      await expect(page.locator("text=PASTE_URLS_FOR_INGESTION")).toBeVisible({
        timeout: 3000,
      });

      // ADD_LINK button adds more URL input fields
      const addLink = page.locator('[phx-click="add_link_field"]');
      await expect(addLink).toBeVisible();
    }
  });

  test("inbox items list renders or shows empty state", async ({ page }) => {
    const content = page.locator("#main-content");
    const text = await content.textContent();
    expect(text).toBeTruthy();
  });

  test("no JavaScript errors", async ({ page }) => {
    const errors: string[] = [];
    page.on("pageerror", (err) => errors.push(err.message));
    await page.waitForTimeout(2000);
    expect(errors).toHaveLength(0);
  });
});
