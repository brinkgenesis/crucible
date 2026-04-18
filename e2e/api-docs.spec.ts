import { test, expect } from "@playwright/test";

test.describe("Swagger UI / API Docs", () => {
  test("loads SwaggerUI page", async ({ page }) => {
    await page.goto("/api/docs", { waitUntil: "domcontentloaded" });
    // SwaggerUI renders its own container
    const swagger = page.locator("#swagger-ui, .swagger-ui, [class*='swagger']");
    await expect(swagger.first()).toBeVisible({ timeout: 10_000 });
  });

  test("displays API operation groups", async ({ page }) => {
    await page.goto("/api/docs", { waitUntil: "domcontentloaded" });
    // Wait for SwaggerUI to fully render its JS
    await page.waitForSelector(".swagger-ui", { timeout: 10_000 });
    // Give SwaggerUI time to parse the spec and render operations
    await page.waitForTimeout(2000);

    const groups = page.locator(".opblock-tag, .opblock-tag-section, .opblock");
    const count = await groups.count();
    expect(count).toBeGreaterThan(0);
  });

  test("can expand an operation", async ({ page }) => {
    await page.goto("/api/docs", { waitUntil: "domcontentloaded" });
    await page.waitForSelector(".swagger-ui", { timeout: 10_000 });
    await page.waitForTimeout(2000);

    const operation = page.locator(".opblock-summary").first();
    if ((await operation.count()) > 0) {
      await operation.click();
      const body = page.locator(".opblock-body").first();
      await expect(body).toBeVisible({ timeout: 3000 });
    }
  });
});
