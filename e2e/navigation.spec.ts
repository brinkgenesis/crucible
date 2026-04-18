import { test, expect } from "@playwright/test";

const SIDEBAR_LINKS = [
  { path: "/", label: "DASHBOARD" },
  { path: "/control", label: "CONTROL" },
  { path: "/runs", label: "RUNS" },
  { path: "/kanban", label: "WORKFLOWS" },
  { path: "/inbox", label: "INBOX" },
  { path: "/briefing", label: "BRIEFING" },
  { path: "/content", label: "CONTENT" },
  { path: "/showcase", label: "SHOWCASE" },
  { path: "/clients", label: "CLIENTS" },
  { path: "/agents", label: "AGENTS" },
  { path: "/jobs-dashboard", label: "JOBS" },
  { path: "/teams", label: "ACTIVITY" },
  { path: "/benchmarks", label: "BENCHMARKS" },
  { path: "/research", label: "RESEARCH" },
  { path: "/memory", label: "MEMORY" },
  { path: "/budget", label: "BUDGET" },
  { path: "/cost", label: "TOKENS" },
  { path: "/logs", label: "LOGS" },
  { path: "/traces", label: "TRACES" },
  { path: "/remote", label: "REMOTE" },
  { path: "/codebase", label: "CODEBASE" },
  { path: "/token-flow", label: "TOKEN_FLOW" },
  { path: "/config", label: "CONFIG" },
  { path: "/router", label: "ROUTER" },
  { path: "/settings", label: "SETTINGS" },
  { path: "/workspaces", label: "WORKSPACES" },
  { path: "/audit", label: "AUDIT" },
  { path: "/policies", label: "POLICIES" },
];

// LiveView pages use websocket connections that can keep the page in a
// "loading" state. Use "domcontentloaded" instead of the default "load".
const WAIT_UNTIL = "domcontentloaded" as const;

test.describe("Sidebar Navigation", () => {
  for (const { path, label } of SIDEBAR_LINKS) {
    test(`navigates to ${label} (${path})`, async ({ page }) => {
      // Navigate directly — faster and avoids LiveView websocket stalls
      await page.goto(path, { waitUntil: WAIT_UNTIL });
      await expect(page.locator("#main-content")).toBeVisible();
      await expect(page.locator(".phx-error")).toHaveCount(0);
    });
  }
});

test.describe("Sidebar Link Click", () => {
  test("clicking a sidebar link navigates to target page", async ({ page }) => {
    await page.goto("/", { waitUntil: WAIT_UNTIL });
    await page.waitForSelector("#sidebar");

    const link = page.locator('#sidebar a[href="/runs"]');
    await link.click();
    await page.waitForURL("**/runs", { waitUntil: WAIT_UNTIL });
    await expect(page.locator("#main-content")).toBeVisible();
  });
});

test.describe("Top Bar", () => {
  test("logo links to dashboard", async ({ page }) => {
    await page.goto("/runs", { waitUntil: WAIT_UNTIL });
    const logo = page.locator('a:has-text("NERV_COMMAND_OS")');
    await expect(logo).toHaveAttribute("href", "/");
  });

  test("settings icon links to settings", async ({ page }) => {
    await page.goto("/", { waitUntil: WAIT_UNTIL });
    await page.click('a[aria-label="Settings"]');
    await page.waitForURL("**/settings", { waitUntil: WAIT_UNTIL });
  });

  test("router health icon links to router", async ({ page }) => {
    await page.goto("/", { waitUntil: WAIT_UNTIL });
    await page.click('a[aria-label="Router health"]');
    await page.waitForURL("**/router", { waitUntil: WAIT_UNTIL });
  });

  test("system status indicator is visible", async ({ page }) => {
    await page.goto("/", { waitUntil: WAIT_UNTIL });
    await expect(page.locator("text=SYSTEM_ONLINE")).toBeVisible();
  });
});

test.describe("Skip Link", () => {
  test("skip-to-content link exists and targets #main-content", async ({ page }) => {
    await page.goto("/", { waitUntil: WAIT_UNTIL });
    const skip = page.locator('a[href="#main-content"]');
    await expect(skip).toHaveCount(1);
    await expect(skip).toHaveText("SKIP_TO_CONTENT");
  });
});

test.describe("Execution Mode Toggle", () => {
  test("execution mode buttons exist with correct labels", async ({ page }) => {
    await page.goto("/", { waitUntil: WAIT_UNTIL });
    await expect(page.locator('button[data-execution-mode="subscription"]')).toHaveText(/TMUX/);
    await expect(page.locator('button[data-execution-mode="sdk"]')).toHaveText(/SDK/);
    await expect(page.locator('button[data-execution-mode="api"]')).toHaveText(/API/);
  });

  test("exactly one mode is active", async ({ page }) => {
    await page.goto("/", { waitUntil: WAIT_UNTIL });
    // Wait for LiveView websocket to connect and hook to mount
    await page.waitForFunction(
      () => document.querySelector('[data-execution-mode][data-active="true"]') !== null,
      { timeout: 5000 },
    );
    const active = page.locator('[data-execution-mode][data-active="true"]');
    await expect(active).toHaveCount(1);
  });

  test("mode buttons have aria-pressed attributes", async ({ page }) => {
    await page.goto("/", { waitUntil: WAIT_UNTIL });
    // All three buttons should have aria-pressed
    for (const mode of ["subscription", "sdk", "api"]) {
      const btn = page.locator(`button[data-execution-mode="${mode}"]`);
      const pressed = await btn.getAttribute("aria-pressed");
      expect(["true", "false"]).toContain(pressed);
    }
  });
});

test.describe("Mobile Sidebar", () => {
  test.use({ viewport: { width: 375, height: 812 } });

  test("sidebar is hidden on mobile by default", async ({ page }) => {
    await page.goto("/", { waitUntil: WAIT_UNTIL });
    const sidebar = page.locator("#sidebar");
    await expect(sidebar).toBeHidden();
  });

  test("hamburger toggle button is visible on mobile", async ({ page }) => {
    await page.goto("/", { waitUntil: WAIT_UNTIL });
    await page.waitForSelector("#main-content");
    // On mobile viewport, the hamburger button should be visible
    await expect(page.locator("#sidebar-toggle")).toBeVisible();
    // And the sidebar should be hidden
    const sidebarHidden = await page.locator("#sidebar").evaluate(
      (el) => el.classList.contains("hidden")
    );
    expect(sidebarHidden).toBe(true);
  });
});
