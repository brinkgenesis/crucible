/**
 * @license MIT
 * Per-model pricing data (USD per million tokens).
 * Updated: 2026-02. Check provider pricing pages for latest rates.
 * @since 2026-04
 * @see {@link ./strategy.ts}
 */

export interface ModelPricing {
  inputPerMillion: number;
  outputPerMillion: number;
  cacheReadPerMillion?: number;
  cacheWritePerMillion?: number;
}

export interface ModelEntry {
  id: string;
  provider: string;
  displayName: string;
  pricing: ModelPricing;
  contextWindow: number;
  maxOutput: number;
}

export const MODELS: Record<string, ModelEntry> = {
  "claude-opus-4-6": {
    id: "claude-opus-4-6",
    provider: "anthropic",
    displayName: "Claude Opus 4.6",
    pricing: { inputPerMillion: 15.0, outputPerMillion: 75.0, cacheReadPerMillion: 1.5, cacheWritePerMillion: 18.75 },
    contextWindow: 200_000,
    maxOutput: 32_000,
  },
  "claude-sonnet-4-6": {
    id: "claude-sonnet-4-6",
    provider: "anthropic",
    displayName: "Claude Sonnet 4.6",
    pricing: { inputPerMillion: 3.0, outputPerMillion: 15.0, cacheReadPerMillion: 0.3, cacheWritePerMillion: 3.75 },
    contextWindow: 200_000,
    maxOutput: 16_000,
  },
  "claude-sonnet-4-5-20250929": {
    id: "claude-sonnet-4-5-20250929",
    provider: "anthropic",
    displayName: "Claude Sonnet 4.5",
    pricing: { inputPerMillion: 3.0, outputPerMillion: 15.0, cacheReadPerMillion: 0.3, cacheWritePerMillion: 3.75 },
    contextWindow: 200_000,
    maxOutput: 16_000,
  },
  "claude-haiku-4-5-20251001": {
    id: "claude-haiku-4-5-20251001",
    provider: "anthropic",
    displayName: "Claude Haiku",
    pricing: { inputPerMillion: 0.8, outputPerMillion: 4.0, cacheReadPerMillion: 0.08, cacheWritePerMillion: 1.0 },
    contextWindow: 200_000,
    maxOutput: 8_192,
  },
  "MiniMax-M2": {
    id: "MiniMax-M2",
    provider: "minimax",
    displayName: "MiniMax M2",
    pricing: { inputPerMillion: 0.15, outputPerMillion: 0.6 },
    contextWindow: 204_000,
    maxOutput: 131_000,
  },
  "gemini-2.5-flash": {
    id: "gemini-2.5-flash",
    provider: "google",
    displayName: "Gemini 2.5 Flash",
    pricing: { inputPerMillion: 0.075, outputPerMillion: 0.3 },
    contextWindow: 1_000_000,
    maxOutput: 8_192,
  },
  "local-ollama": {
    id: "local-ollama",
    provider: "ollama",
    displayName: "Local (Ollama)",
    pricing: { inputPerMillion: 0, outputPerMillion: 0 },
    contextWindow: 128_000,
    maxOutput: 8_192,
  },
};

import { createLogger } from "./utils/logger.js";

const logger = createLogger("router:cost-table");

export function estimateCost(
  modelId: string,
  inputTokens: number,
  outputTokens: number,
  cacheReadTokens = 0,
  cacheWriteTokens = 0,
): number {
  const model = MODELS[modelId];
  if (!model) {
    logger.warn(`[cost-table] Unknown model "${modelId}" — cost will be 0. Add it to MODELS.`);
    return 0;
  }

  const { inputPerMillion, outputPerMillion, cacheReadPerMillion = 0, cacheWritePerMillion = 0 } = model.pricing;
  return (
    (inputTokens / 1_000_000) * inputPerMillion +
    (outputTokens / 1_000_000) * outputPerMillion +
    (cacheReadTokens / 1_000_000) * cacheReadPerMillion +
    (cacheWriteTokens / 1_000_000) * cacheWritePerMillion
  );
}
