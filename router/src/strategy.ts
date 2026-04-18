/**
 * Routing strategy: maps complexity scores to model selections.
 * Supports cost, quality, and speed optimization modes.
 */

export type RoutingStrategy = "cost" | "quality" | "speed";

export interface RouteDecision {
  modelId: string;
  provider: string;
  reason: string;
}

const COST_ROUTES: Record<string, RouteDecision> = {
  "1-2": {
    modelId: "claude-haiku-4-5-20251001",
    provider: "anthropic",
    reason: "Trivial task: Haiku is cheapest for classification/quick questions",
  },
  "3-4": {
    modelId: "gemini-2.5-flash",
    provider: "google",
    reason: "Simple task: Gemini Flash is cheapest for summarization/general work",
  },
  "5-6": {
    modelId: "MiniMax-M2",
    provider: "minimax",
    reason: "Coding task: MiniMax M2 is cost-efficient for implementation and tool-calling",
  },
  "7-8": {
    modelId: "claude-sonnet-4-5-20250929",
    provider: "anthropic",
    reason: "Complex task: Sonnet provides strong code review and debugging capabilities",
  },
  "9-10": {
    modelId: "claude-opus-4-6",
    provider: "anthropic",
    reason: "Architecture/reasoning: Opus provides the highest quality for complex decisions",
  },
};

const QUALITY_ROUTES: Record<string, RouteDecision> = {
  "1-2": {
    modelId: "claude-haiku-4-5-20251001",
    provider: "anthropic",
    reason: "Trivial: Haiku is sufficient quality for simple lookups",
  },
  "3-4": {
    modelId: "claude-sonnet-4-5-20250929",
    provider: "anthropic",
    reason: "Quality mode: Sonnet for even simple tasks to maximize output quality",
  },
  "5-6": {
    modelId: "claude-sonnet-4-5-20250929",
    provider: "anthropic",
    reason: "Quality mode: Sonnet for coding tasks to maximize correctness",
  },
  "7-8": {
    modelId: "claude-opus-4-6",
    provider: "anthropic",
    reason: "Quality mode: Opus for complex tasks to maximize reasoning quality",
  },
  "9-10": {
    modelId: "claude-opus-4-6",
    provider: "anthropic",
    reason: "Quality mode: Opus for architecture decisions, maximum capability",
  },
};

const SPEED_ROUTES: Record<string, RouteDecision> = {
  "1-2": {
    modelId: "claude-haiku-4-5-20251001",
    provider: "anthropic",
    reason: "Speed: Haiku has fastest time-to-first-token",
  },
  "3-4": {
    modelId: "gemini-2.5-flash",
    provider: "google",
    reason: "Speed: Gemini Flash has very fast inference",
  },
  "5-6": {
    modelId: "MiniMax-M2",
    provider: "minimax",
    reason: "Speed: MiniMax M2 is 2x faster than Sonnet for coding",
  },
  "7-8": {
    modelId: "claude-sonnet-4-5-20250929",
    provider: "anthropic",
    reason: "Speed: Sonnet balances capability with reasonable latency",
  },
  "9-10": {
    modelId: "claude-opus-4-6",
    provider: "anthropic",
    reason: "Speed: Opus is required for this complexity, no faster alternative",
  },
};

function getComplexityBucket(complexity: number): string {
  if (complexity <= 2) return "1-2";
  if (complexity <= 4) return "3-4";
  if (complexity <= 6) return "5-6";
  if (complexity <= 8) return "7-8";
  return "9-10";
}

/** Phase-aware routing profiles for the reasoning sandwich pattern.
 *  - "deep-reasoning": planning/architecture phases → quality strategy
 *  - "throughput": implementation phases → cost strategy
 *  - "verification": review/verification phases → quality strategy
 *  - "scout": exploration phases → speed strategy
 *  - "yolo-classifier": real-time tool call risk classification → cost strategy (complexity 2, cheapest model)
 */
export type RoutingProfile = "deep-reasoning" | "throughput" | "verification" | "scout" | "yolo-classifier";

/** Maps a routing profile to its underlying strategy. */
export function resolveProfileStrategy(profile: RoutingProfile): RoutingStrategy {
  switch (profile) {
    case "deep-reasoning": return "quality";
    case "throughput": return "cost";
    case "verification": return "quality";
    case "scout": return "speed";
    case "yolo-classifier": return "cost";
  }
}

export function selectRoute(
  complexity: number,
  strategy: RoutingStrategy = "cost"
): RouteDecision {
  const bucket = getComplexityBucket(complexity);

  switch (strategy) {
    case "quality":
      return QUALITY_ROUTES[bucket];
    case "speed":
      return SPEED_ROUTES[bucket];
    case "cost":
    default:
      return COST_ROUTES[bucket];
  }
}

// ---------------------------------------------------------------------------
// API-based execution model selection
// ---------------------------------------------------------------------------

export interface ApiPhaseModelConfig {
  /** Anthropic model ID for the Messages API. */
  model: string;
  /** Max output tokens per API call. */
  maxTokens: number;
  /** Extended thinking budget tokens. */
  thinkingBudget: number;
  /** Target context window budget (tokens) — guides compaction thresholds. */
  contextBudget: number;
}

/**
 * Select the optimal Anthropic model for API-based phase execution.
 *
 * For the API execution path, we use Anthropic models directly. The routing
 * profile determines which model and token budget to use:
 *
 * - deep-reasoning (plan): Opus 4.6 for architecture/planning decisions
 * - throughput (implement): Sonnet 4.6 for cost-efficient code generation
 * - verification (review): Sonnet 4.6 with lower output budget
 */
export function selectModelForApiPhase(routingProfile?: string): ApiPhaseModelConfig {
  switch (routingProfile) {
    case "deep-reasoning":
      return {
        model: "claude-opus-4-6",
        maxTokens: 8192,
        thinkingBudget: 16_000,
        contextBudget: 180_000,
      };
    case "throughput":
      return {
        model: "claude-sonnet-4-6",
        maxTokens: 16_384,
        thinkingBudget: 10_000,
        contextBudget: 160_000,
      };
    case "verification":
      return {
        model: "claude-sonnet-4-6",
        maxTokens: 4096,
        thinkingBudget: 8_000,
        contextBudget: 120_000,
      };
    default:
      return {
        model: "claude-sonnet-4-6",
        maxTokens: 8192,
        thinkingBudget: 10_000,
        contextBudget: 160_000,
      };
  }
}

/**
 * Adaptive context window selection based on task complexity.
 *
 * Estimates whether a task needs a large context window based on:
 * - Number of files in the plan (more files → more context needed)
 * - Phase type (implement needs more than plan/review)
 * - Explicit hints from the plan note
 *
 * Returns a context budget that can be used to configure compaction thresholds.
 */
export function adaptiveContextBudget(
  routingProfile: string | undefined,
  estimatedFiles: number,
  estimatedSteps: number,
): number {
  const base = selectModelForApiPhase(routingProfile);

  // Scale context budget based on task complexity signals.
  // Multipliers are additive (not compounding) to prevent overshooting the model window.
  let bonus = 0;

  // More files → need more context to hold all read results.
  if (estimatedFiles > 20) bonus += 0.2;
  else if (estimatedFiles > 10) bonus += 0.1;

  // Many steps → longer conversation → need more headroom.
  if (estimatedSteps > 15) bonus += 0.15;

  // Cap total bonus at 25% to stay safely within 200K model window.
  const multiplier = 1.0 + Math.min(bonus, 0.25);

  // Cap at model's actual context window (200K for Anthropic models).
  const modelWindow = 200_000;
  return Math.min(Math.round(base.contextBudget * multiplier), modelWindow);
}
