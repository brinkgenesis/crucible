import { describe, expect, it } from "vitest";
import { MiniMaxProvider } from "../src/providers.js";

describe("MiniMaxProvider", () => {
  it("health check uses configured model", async () => {
    const provider = new MiniMaxProvider("test-key", "https://example.invalid/v1", "MiniMax-Custom");
    let calledModel = "";

    (provider as unknown as { _client: unknown })._client = {
      chat: {
        completions: {
          create: async ({ model }: { model: string }) => {
            calledModel = model;
            return { choices: [{ message: { content: "ok" } }], usage: {} };
          },
        },
      },
    };

    const ok = await provider.healthCheck();
    expect(ok).toBe(true);
    expect(calledModel).toBe("MiniMax-Custom");
  });
});
