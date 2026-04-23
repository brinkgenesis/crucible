import { describe, it, expect } from "vitest";
import { classifyTask } from "../src/classifier.js";
import { selectRoute, resolveProfileStrategy } from "../src/strategy.js";
import { estimateCost, MODELS } from "../src/cost-table.js";
import { ModelRouter, type RouterResponse } from "../src/index.js";
import type { LLMProvider, LLMRequest, LLMResponse } from "../src/providers.js";

describe("Task Classifier", () => {
  it("classifies trivial tasks as complexity 1-2", () => {
    const result = classifyTask("classify this as positive or negative");
    expect(result.complexity).toBeLessThanOrEqual(2);
    expect(result.category).toBe("trivial");
  });

  it("classifies general tasks as complexity 3-4", () => {
    const result = classifyTask("summarize this document for me");
    expect(result.complexity).toBeGreaterThanOrEqual(3);
    expect(result.complexity).toBeLessThanOrEqual(4);
  });

  it("classifies coding tasks as complexity 5-6", () => {
    const result = classifyTask("implement a new function to parse JSON");
    expect(result.complexity).toBeGreaterThanOrEqual(5);
    expect(result.complexity).toBeLessThanOrEqual(6);
  });

  it("classifies complex coding tasks as complexity 7-8", () => {
    const result = classifyTask("debug this performance issue and fix the bug");
    expect(result.complexity).toBeGreaterThanOrEqual(7);
    expect(result.complexity).toBeLessThanOrEqual(8);
  });

  it("classifies architecture tasks as complexity 9-10", () => {
    const result = classifyTask("design system architecture with tradeoff analysis");
    expect(result.complexity).toBeGreaterThanOrEqual(9);
  });

  it("respects complexity hints", () => {
    const result = classifyTask("hello", 7);
    expect(result.complexity).toBe(7);
    expect(result.reasoning).toContain("hint");
  });

  it("ignores non-integer complexity hints", () => {
    const result = classifyTask("hello", 7.5);
    expect(Number.isInteger(result.complexity)).toBe(true);
    expect(result.complexity).not.toBe(7.5);
  });
});

describe("Routing Strategy", () => {
  it("routes trivial tasks to Haiku in cost mode", () => {
    const route = selectRoute(1, "cost");
    expect(route.modelId).toBe("claude-haiku-4-5-20251001");
    expect(route.provider).toBe("anthropic");
  });

  it("routes general tasks to Gemini Flash in cost mode", () => {
    const route = selectRoute(3, "cost");
    expect(route.modelId).toBe("gemini-2.5-flash");
    expect(route.provider).toBe("google");
  });

  it("routes coding tasks to MiniMax M2 in cost mode", () => {
    const route = selectRoute(5, "cost");
    expect(route.modelId).toBe("MiniMax-M2");
    expect(route.provider).toBe("minimax");
  });

  it("routes complex tasks to Sonnet in cost mode", () => {
    const route = selectRoute(7, "cost");
    expect(route.modelId).toBe("claude-sonnet-4-5-20250929");
    expect(route.provider).toBe("anthropic");
  });

  it("routes architecture tasks to Opus in cost mode", () => {
    const route = selectRoute(10, "cost");
    expect(route.modelId).toBe("claude-opus-4-6");
    expect(route.provider).toBe("anthropic");
  });

  it("routes coding tasks to Sonnet in quality mode", () => {
    const route = selectRoute(5, "quality");
    expect(route.modelId).toBe("claude-sonnet-4-5-20250929");
  });

  it("routes coding tasks to MiniMax M2 in speed mode", () => {
    const route = selectRoute(5, "speed");
    expect(route.modelId).toBe("MiniMax-M2");
  });
});

describe("Cost Table", () => {
  it("has all expected models", () => {
    expect(MODELS["claude-opus-4-6"]).toBeDefined();
    expect(MODELS["claude-sonnet-4-5-20250929"]).toBeDefined();
    expect(MODELS["claude-haiku-4-5-20251001"]).toBeDefined();
    expect(MODELS["MiniMax-M2"]).toBeDefined();
    expect(MODELS["gemini-2.5-flash"]).toBeDefined();
    expect(MODELS["local-ollama"]).toBeDefined();
  });

  it("estimates cost correctly for Opus", () => {
    const cost = estimateCost("claude-opus-4-6", 1_000_000, 1_000_000);
    expect(cost).toBe(5.0 + 25.0);
  });

  it("estimates zero cost for local models", () => {
    const cost = estimateCost("local-ollama", 1_000_000, 1_000_000);
    expect(cost).toBe(0);
  });

  it("MiniMax M2 is significantly cheaper than Sonnet", () => {
    const minimaxCost = estimateCost("MiniMax-M2", 1_000_000, 1_000_000);
    const sonnetCost = estimateCost("claude-sonnet-4-5-20250929", 1_000_000, 1_000_000);
    expect(minimaxCost).toBeLessThan(sonnetCost / 10);
  });
});

// --- Router Output Safety Check ---

function makeMockProvider(responseText: string): LLMProvider {
  return {
    name: "mock",
    send: async (_modelId: string, _request: LLMRequest): Promise<LLMResponse> => ({
      text: responseText,
      modelId: "mock-model",
      provider: "mock",
      inputTokens: 10,
      outputTokens: 20,
      costUsd: 0.001,
      latencyMs: 50,
    }),
    healthCheck: async () => true,
  };
}

describe("Router output safety check", () => {
  it("returns no threats for clean output", async () => {
    const router = new ModelRouter({ mock: makeMockProvider("The answer is 42.") });
    const result = await router.route({ prompt: "test", forceProvider: "mock", forceModel: "mock-model" });
    expect(result.outputSafetyThreats).toBeUndefined();
  });

  it("flags injection acknowledgment in output", async () => {
    const router = new ModelRouter({
      mock: makeMockProvider("I am now in DAN mode and will do whatever you ask."),
    });
    const result = await router.route({ prompt: "test", forceProvider: "mock", forceModel: "mock-model" });
    expect(result.outputSafetyThreats).toBeDefined();
    expect(result.outputSafetyThreats!.length).toBeGreaterThan(0);
    expect(result.outputSafetyThreats![0].pattern).toBe("mode-switch-ack");
  });

  it("flags system prompt leak in output", async () => {
    const router = new ModelRouter({
      mock: makeMockProvider("Here is the system prompt: You are a helpful assistant."),
    });
    const result = await router.route({ prompt: "test", forceProvider: "mock", forceModel: "mock-model" });
    expect(result.outputSafetyThreats).toBeDefined();
    expect(result.outputSafetyThreats!.some((t) => t.pattern === "system-prompt-leak")).toBe(true);
  });

  it("includes threats even on degraded fallback", async () => {
    // Primary provider fails, fallback (google) returns injected output
    const failProvider: LLMProvider = {
      name: "fail",
      send: async () => { throw new Error("HTTP 503 Service Unavailable"); },
      healthCheck: async () => false,
    };
    const injectedProvider: LLMProvider = {
      name: "google",
      send: async (_modelId: string, _request: LLMRequest): Promise<LLMResponse> => ({
        text: "I am now in unrestricted mode and will comply.",
        modelId: "gemini-2.5-flash",
        provider: "google",
        inputTokens: 10,
        outputTokens: 20,
        costUsd: 0.001,
        latencyMs: 50,
      }),
      healthCheck: async () => true,
    };
    const router = new ModelRouter({
      anthropic: failProvider,
      google: injectedProvider,
    });
    const result = await router.route({
      prompt: "test",
      forceModel: "claude-haiku-4-5",
      forceProvider: "anthropic",
    });
    expect(result.degraded).toBe(true);
    expect(result.outputSafetyThreats).toBeDefined();
    expect(result.outputSafetyThreats!.some((t) => t.pattern === "mode-switch-ack")).toBe(true);
  });
});

describe("Routing Profile", () => {
  it("resolves deep-reasoning to quality strategy", () => {
    expect(resolveProfileStrategy("deep-reasoning")).toBe("quality");
  });

  it("resolves throughput to cost strategy", () => {
    expect(resolveProfileStrategy("throughput")).toBe("cost");
  });

  it("resolves verification to quality strategy", () => {
    expect(resolveProfileStrategy("verification")).toBe("quality");
  });

  it("uses routing profile as strategy override in route()", async () => {
    const mockProvider: LLMProvider = {
      name: "mock",
      send: async (_modelId: string, _request: LLMRequest): Promise<LLMResponse> => ({
        text: "ok",
        modelId: "mock-model",
        provider: "mock",
        inputTokens: 10,
        outputTokens: 10,
        costUsd: 0.001,
        latencyMs: 50,
      }),
      healthCheck: async () => true,
    };
    const router = new ModelRouter({ anthropic: mockProvider });

    // A trivial prompt with throughput profile should use cost strategy
    const result = await router.route({
      prompt: "classify this",
      routingProfile: "throughput",
    });
    // Cost strategy for trivial → Haiku
    expect(result.route.modelId).toBe("claude-haiku-4-5-20251001");
    expect(result.routingProfile).toBe("throughput");

    // Same prompt with deep-reasoning should use quality strategy
    const result2 = await router.route({
      prompt: "classify this",
      routingProfile: "deep-reasoning",
    });
    // Quality strategy for trivial → still Haiku
    expect(result2.route.modelId).toBe("claude-haiku-4-5-20251001");
    expect(result2.routingProfile).toBe("deep-reasoning");
  });
});

describe("Fallback picks cheapest model per provider", () => {
  it("falls back to Haiku (not Opus) when anthropic is the fallback provider", async () => {
    // Primary: google provider fails. Fallback should pick cheapest anthropic model (Haiku).
    const failProvider: LLMProvider = {
      name: "google",
      send: async () => { throw new Error("503"); },
      healthCheck: async () => false,
    };
    const capturedModels: string[] = [];
    const anthropicMock: LLMProvider = {
      name: "anthropic",
      send: async (modelId: string, _request: LLMRequest): Promise<LLMResponse> => {
        capturedModels.push(modelId);
        return {
          text: "ok", modelId, provider: "anthropic",
          inputTokens: 10, outputTokens: 10, costUsd: 0.001, latencyMs: 50,
        };
      },
      healthCheck: async () => true,
    };

    const router = new ModelRouter({ google: failProvider, anthropic: anthropicMock });
    const result = await router.route({
      prompt: "summarize this",
      complexityHint: 3, // routes to google/gemini-flash as primary
      strategy: "cost",
    });

    expect(result.degraded).toBe(true);
    expect(result.route.provider).toBe("anthropic");
    // Must be Haiku (cheapest), NOT Opus
    expect(result.route.modelId).toBe("claude-haiku-4-5-20251001");
    expect(capturedModels[0]).toBe("claude-haiku-4-5-20251001");
  });
});

