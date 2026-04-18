/**
 * Model Router - Entry point
 *
 * Routes LLM requests to the optimal provider based on task complexity,
 * cost constraints, and routing strategy.
 *
 * Resilience features:
 * - Per-provider circuit breakers (auto-skip failing providers)
 * - Retry with exponential backoff + jitter for transient failures
 * - Graceful degradation: falls back to next-tier provider on failure
 */

import { classifyTask, type ClassificationResult } from "./classifier.js";
import { estimateCost, MODELS } from "./cost-table.js";
import { createProviders, type LLMProvider, type LLMRequest, type LLMResponse, type UsageWithCache } from "./providers.js";
import { selectRoute, resolveProfileStrategy, type RoutingStrategy, type RoutingProfile, type RouteDecision } from "./strategy.js";
import {
  CircuitBreaker,
  withRetry,
  type RetryOptions,
} from "./resilience/index.js";
import { checkLlmOutput, type ThreatDetection } from "./safety/index.js";
import { QuotaTracker, type QuotaSnapshot, type ProviderQuotaState } from "./quota-tracker.js";
import { createLogger } from "./utils/logger.js";
import { extractErrorMessage } from "./utils/error.js";

const log = createLogger("router");

export interface RouterRequest {
  prompt: string;
  systemPrompt?: string;
  maxTokens?: number;
  temperature?: number;
  complexityHint?: number;
  strategy?: RoutingStrategy;
  /** Phase-aware routing profile — overrides strategy when set. */
  routingProfile?: RoutingProfile;
  forceModel?: string;
  forceProvider?: string;
  /** When true, wraps the system prompt in a cache_control block for Anthropic calls */
  cacheSystem?: boolean;
}

export interface RouterResponse extends LLMResponse {
  classification: ClassificationResult;
  route: RouteDecision;
  /** True if the response came from a fallback provider */
  degraded?: boolean;
  /** The routing profile that was applied, if any. */
  routingProfile?: RoutingProfile;
  /** Non-empty if the LLM output contains signs of successful injection */
  outputSafetyThreats?: ThreatDetection[];
}

/** Provider fallback order — cheapest to most expensive */
const FALLBACK_ORDER = ["ollama", "google", "minimax", "anthropic"];

export class ModelRouter {
  private providers: Record<string, LLMProvider>;
  private breakers: Map<string, CircuitBreaker> = new Map();
  private retryOpts: Partial<RetryOptions>;
  private quotaTracker: QuotaTracker;

  constructor(
    providers?: Record<string, LLMProvider>,
    retryOpts?: Partial<RetryOptions>,
    opts?: { quotaPollIntervalMs?: number },
  ) {
    this.providers = providers ?? createProviders();
    this.retryOpts = retryOpts ?? {};
    this.quotaTracker = new QuotaTracker(opts?.quotaPollIntervalMs);

    // Create a circuit breaker per provider
    for (const name of Object.keys(this.providers)) {
      this.breakers.set(name, new CircuitBreaker(name));
    }
  }

  async route(request: RouterRequest): Promise<RouterResponse> {
    // Step 1: Classify task complexity
    const classification = classifyTask(request.prompt, request.complexityHint);

    // Step 2: Select route based on strategy
    let route: RouteDecision;
    if (request.forceModel) {
      const model = MODELS[request.forceModel];
      route = {
        modelId: request.forceModel,
        provider: model?.provider ?? request.forceProvider ?? "anthropic",
        reason: `Forced to model: ${request.forceModel}`,
      };
    } else {
      // Phase-aware routing profile takes precedence over explicit strategy
      const effectiveStrategy = request.routingProfile
        ? resolveProfileStrategy(request.routingProfile)
        : (request.strategy ?? "cost");
      route = selectRoute(classification.complexity, effectiveStrategy);
    }

    log.info(
      { complexity: classification.complexity, model: route.modelId, provider: route.provider, strategy: request.strategy ?? "cost" },
      "Route selected",
    );

    const llmRequest: LLMRequest = {
      prompt: request.prompt,
      systemPrompt: request.systemPrompt,
      maxTokens: request.maxTokens,
      temperature: request.temperature,
      cacheSystem: request.cacheSystem,
    };

    // Step 3: Check if primary provider quota is exhausted
    const quotaExhausted = this.quotaTracker.isProviderExhausted(route.provider);

    // Step 3a: Try primary provider with resilience (skip if quota-exhausted)
    if (!quotaExhausted) {
      const primaryResult = await this.tryProvider(
        route.provider, route.modelId, llmRequest,
      );
      if (primaryResult) {
        return this.withOutputSafetyCheck({
          ...primaryResult, classification, route,
          ...(request.routingProfile ? { routingProfile: request.routingProfile } : {}),
        });
      }
    }

    // Step 4: Graceful degradation — try fallback providers (skip quota-exhausted)
    for (const fallbackProvider of FALLBACK_ORDER) {
      if (fallbackProvider === route.provider) continue;
      if (!this.providers[fallbackProvider]) continue;
      if (this.quotaTracker.isProviderExhausted(fallbackProvider)) continue;

      const fallbackModel = this.pickModelForProvider(fallbackProvider);
      if (!fallbackModel) continue;

      log.info({ fallbackProvider, fallbackModel, originalProvider: route.provider, originalModel: route.modelId }, "Trying fallback provider");
      const result = await this.tryProvider(
        fallbackProvider, fallbackModel, llmRequest,
      );
      if (result) {
        const reason = quotaExhausted
          ? `Quota exhausted: ${route.provider} → ${fallbackProvider}`
          : `Degraded: ${route.provider} unavailable → ${fallbackProvider}`;
        return this.withOutputSafetyCheck({
          ...result,
          classification,
          route: {
            modelId: fallbackModel,
            provider: fallbackProvider,
            reason,
          },
          degraded: true,
          ...(request.routingProfile ? { routingProfile: request.routingProfile } : {}),
        });
      }
    }

    throw new Error(
      `All providers failed. Primary: ${route.provider}. ` +
      `Circuits: ${this.circuitSummary()}`,
    );
  }

  /** Try a provider with circuit breaker + retry. Returns null on failure. */
  private async tryProvider(
    providerName: string,
    modelId: string,
    request: LLMRequest,
  ): Promise<LLMResponse | null> {
    const provider = this.providers[providerName];
    const breaker = this.breakers.get(providerName);
    if (!provider || !breaker) return null;

    try {
      return await breaker.execute(() =>
        withRetry(() => provider.send(modelId, request), this.retryOpts),
      );
    } catch (err) {
      log.debug(
        { provider: providerName, modelId, err: extractErrorMessage(err) },
        "Provider call failed — falling back",
      );
      return null;
    }
  }

  /** Scan LLM output for signs of successful prompt injection. */
  private withOutputSafetyCheck(response: RouterResponse): RouterResponse {
    if (response.text) {
      const threats = checkLlmOutput(response.text);
      if (threats.length > 0) {
        response.outputSafetyThreats = threats;
      }
    }
    return response;
  }

  /**
   * Pick the cheapest model for a given provider (used in fallback scenarios).
   * Sorts by input pricing to avoid accidentally escalating to Opus on fallback.
   */
  private pickModelForProvider(provider: string): string | null {
    const candidates = Object.entries(MODELS)
      .filter(([, m]) => m.provider === provider)
      .sort(([, a], [, b]) => a.pricing.inputPerMillion - b.pricing.inputPerMillion);
    return candidates.length > 0 ? candidates[0][0] : null;
  }

  private circuitSummary(): string {
    return Array.from(this.breakers)
      .map(([n, b]) => `${n}=${b.stats().state}`)
      .join(", ");
  }

  async healthCheck(): Promise<Record<string, boolean>> {
    const results: Record<string, boolean> = {};
    const checks = Object.entries(this.providers).map(async ([name, provider]) => {
      results[name] = await provider.healthCheck();
    });
    await Promise.all(checks);
    return results;
  }

  /** Get circuit breaker stats for all providers. */
  circuitStats(): Record<string, { state: string; failures: number }> {
    const stats: Record<string, { state: string; failures: number }> = {};
    for (const [name, breaker] of this.breakers) {
      const s = breaker.stats();
      stats[name] = { state: s.state, failures: s.failures };
    }
    return stats;
  }

  /** Reset a specific provider's circuit breaker. */
  resetCircuit(providerName: string): void {
    this.breakers.get(providerName)?.reset();
  }

  getAvailableModels() {
    return MODELS;
  }

  /** Get quota health state for all providers. */
  getProviderHealth(): Record<string, ProviderQuotaState> {
    return this.quotaTracker.snapshot().providers;
  }

  /** Start periodic quota polling. */
  startQuotaPolling(): void {
    this.quotaTracker.start();
  }

  /** Stop quota polling. */
  stopQuotaPolling(): void {
    this.quotaTracker.stop();
  }

  /** Get current quota snapshot for all providers. */
  quotaSnapshot(): QuotaSnapshot {
    return this.quotaTracker.snapshot();
  }

  /** Force an immediate quota poll. */
  async pollQuotas(): Promise<QuotaSnapshot> {
    return this.quotaTracker.pollAll();
  }
}

export { classifyTask, estimateCost, selectRoute, resolveProfileStrategy, createProviders };
export type { ClassificationResult, LLMProvider, LLMRequest, LLMResponse, UsageWithCache, RoutingStrategy, RoutingProfile, RouteDecision };

// Quota tracking
export { QuotaTracker, getQuotaMetrics } from "./quota-tracker.js";
export type { QuotaSnapshot, ProviderQuotaState, QuotaHealth, QuotaMetrics } from "./quota-tracker.js";

// Media router (image generation) is out-of-scope for the core router package.
