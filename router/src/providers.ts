// @copyright 2026
/**
 * LLM provider adapters.
 * Each provider implements a common interface for sending requests
 * and tracking costs.
 */

import Anthropic from "@anthropic-ai/sdk";
import { GoogleGenAI } from "@google/genai";
import OpenAI from "openai";
import { estimateCost } from "./cost-table.js";

/** Default per-request timeout in milliseconds (2 minutes). */
export const DEFAULT_REQUEST_TIMEOUT_MS = 120_000;

/** Timeout for health check pings (10 seconds). */
const HEALTH_CHECK_TIMEOUT_MS = 10_000;

/** Shared health check wrapper: run a provider ping with timeout, return true/false. */
async function tryHealthCheck(fn: () => Promise<unknown>, providerName: string): Promise<boolean> {
  try {
    await withTimeout(fn(), HEALTH_CHECK_TIMEOUT_MS, providerName);
    return true;
  } catch {
    return false;
  }
}

export interface LLMRequest {
  prompt: string;
  systemPrompt?: string;
  maxTokens?: number;
  temperature?: number;
  /** Per-request timeout in ms (default: 120_000). */
  timeoutMs?: number;
  /** When true, wraps the system prompt in a cache_control block for Anthropic calls */
  cacheSystem?: boolean;
}

/** Cache-aware token usage fields, shared across LLMResponse and RouterResponse. */
export interface UsageWithCache {
  inputTokens: number;
  outputTokens: number;
  cacheCreationTokens?: number;
  cacheReadTokens?: number;
}

export interface LLMResponse extends UsageWithCache {
  text: string;
  modelId: string;
  provider: string;
  costUsd: number;
  latencyMs: number;
}

export interface LLMProvider {
  name: string;
  send(modelId: string, request: LLMRequest): Promise<LLMResponse>;
  healthCheck(): Promise<boolean>;
}

/**
 * Race a promise against a timeout. Rejects with a clear error on timeout.
 */
function withTimeout<T>(promise: Promise<T>, ms: number, provider: string): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(
      () => reject(new Error(`LLM request to ${provider} timed out after ${ms}ms`)),
      ms,
    );
    promise.then(
      (val) => { clearTimeout(timer); resolve(val); },
      (err) => { clearTimeout(timer); reject(err); },
    );
  });
}

// --- Anthropic Provider ---

export class AnthropicProvider implements LLMProvider {
  name = "anthropic";
  private client: Anthropic;

  constructor(apiKey?: string) {
    this.client = new Anthropic({ apiKey: apiKey ?? process.env.ANTHROPIC_API_KEY });
  }

  async send(modelId: string, request: LLMRequest): Promise<LLMResponse> {
    const start = Date.now();
    const timeoutMs = request.timeoutMs ?? DEFAULT_REQUEST_TIMEOUT_MS;
    const system = request.cacheSystem && request.systemPrompt
      ? [{ type: "text" as const, text: request.systemPrompt, cache_control: { type: "ephemeral" as const } }]
      : (request.systemPrompt ?? "");
    const response = await withTimeout(
      this.client.messages.create({
        model: modelId,
        max_tokens: request.maxTokens ?? 4096,
        temperature: request.temperature,
        system,
        messages: [{ role: "user", content: request.prompt }],
      }),
      timeoutMs,
      this.name,
    );

    const text = response.content
      .filter((block): block is Anthropic.TextBlock => block.type === "text")
      .map((block) => block.text)
      .join("");

    const inputTokens = response.usage.input_tokens;
    const outputTokens = response.usage.output_tokens;
    // Cache fields are present on responses that used cache_control but are
    // omitted from the base Usage type in older SDK versions; widen the shape.
    const usage = response.usage as typeof response.usage & {
      cache_creation_input_tokens?: number;
      cache_read_input_tokens?: number;
    };
    const cacheCreationTokens = usage.cache_creation_input_tokens ?? 0;
    const cacheReadTokens = usage.cache_read_input_tokens ?? 0;

    return {
      text,
      modelId,
      provider: this.name,
      inputTokens,
      outputTokens,
      costUsd: estimateCost(modelId, inputTokens, outputTokens, cacheReadTokens),
      latencyMs: Date.now() - start,
      cacheCreationTokens,
      cacheReadTokens,
    };
  }

  async healthCheck(): Promise<boolean> {
    return tryHealthCheck(
      () => this.client.messages.create({
        model: "claude-haiku-4-5-20251001",
        max_tokens: 1,
        messages: [{ role: "user", content: "ping" }],
      }),
      this.name,
    );
  }
}

// --- Google Gemini Provider ---

export class GoogleProvider implements LLMProvider {
  name = "google";
  private _client: GoogleGenAI | null = null;
  private apiKey: string | undefined;

  constructor(apiKey?: string) {
    this.apiKey = apiKey ?? process.env.GOOGLE_API_KEY;
  }

  /** Lazy-init the client so construction never throws when the key is absent. */
  private get client(): GoogleGenAI {
    if (!this._client) {
      const key = this.apiKey;
      if (!key) throw new Error("GOOGLE_API_KEY is not set");
      this._client = new GoogleGenAI({ apiKey: key });
    }
    return this._client;
  }

  async send(modelId: string, request: LLMRequest): Promise<LLMResponse> {
    const start = Date.now();
    const timeoutMs = request.timeoutMs ?? DEFAULT_REQUEST_TIMEOUT_MS;
    const response = await withTimeout(
      this.client.models.generateContent({
        model: modelId,
        contents: request.prompt,
        config: {
          maxOutputTokens: request.maxTokens ?? 4096,
          temperature: request.temperature,
          systemInstruction: request.systemPrompt,
        },
      }),
      timeoutMs,
      this.name,
    );

    const text = response.text ?? "";
    const inputTokens = response.usageMetadata?.promptTokenCount ?? 0;
    const outputTokens = response.usageMetadata?.candidatesTokenCount ?? 0;

    return {
      text,
      modelId,
      provider: this.name,
      inputTokens,
      outputTokens,
      costUsd: estimateCost(modelId, inputTokens, outputTokens),
      latencyMs: Date.now() - start,
    };
  }

  async healthCheck(): Promise<boolean> {
    return tryHealthCheck(
      () => this.client.models.generateContent({
        model: "gemini-2.5-flash",
        contents: "ping",
        config: { maxOutputTokens: 1 },
      }),
      this.name,
    );
  }
}

// --- MiniMax Provider (OpenAI-compatible API) ---

export class MiniMaxProvider implements LLMProvider {
  name = "minimax";
  private _client: OpenAI | null = null;
  private apiKey: string | undefined;
  private baseUrl: string;
  private healthCheckModelName: string;

  constructor(apiKey?: string, baseUrl?: string, healthCheckModel?: string) {
    this.apiKey = apiKey ?? process.env.MINIMAX_API_KEY;
    this.baseUrl = baseUrl ?? process.env.MINIMAX_BASE_URL ?? "https://api.minimax.io/v1";
    this.healthCheckModelName = healthCheckModel ?? process.env.MINIMAX_MODEL ?? "MiniMax-M2";
  }

  /** Lazy-init the OpenAI client so construction never throws when the key is absent. */
  private get client(): OpenAI {
    if (!this._client) {
      const key = this.apiKey;
      if (!key) throw new Error("MINIMAX_API_KEY is not set");
      this._client = new OpenAI({ apiKey: key, baseURL: this.baseUrl });
    }
    return this._client;
  }

  async send(modelId: string, request: LLMRequest): Promise<LLMResponse> {
    const start = Date.now();
    const timeoutMs = request.timeoutMs ?? DEFAULT_REQUEST_TIMEOUT_MS;
    const messages: OpenAI.ChatCompletionMessageParam[] = [];

    if (request.systemPrompt) {
      messages.push({ role: "system", content: request.systemPrompt });
    }
    messages.push({ role: "user", content: request.prompt });

    const response = await withTimeout(
      this.client.chat.completions.create({
        model: modelId,
        messages,
        max_tokens: request.maxTokens ?? 4096,
        temperature: request.temperature,
      }),
      timeoutMs,
      this.name,
    );

    const text = response.choices[0]?.message?.content ?? "";
    const inputTokens = response.usage?.prompt_tokens ?? 0;
    const outputTokens = response.usage?.completion_tokens ?? 0;

    return {
      text,
      modelId,
      provider: this.name,
      inputTokens,
      outputTokens,
      costUsd: estimateCost(modelId, inputTokens, outputTokens),
      latencyMs: Date.now() - start,
    };
  }

  async healthCheck(): Promise<boolean> {
    return tryHealthCheck(
      () => this.client.chat.completions.create({
        model: this.healthCheckModelName,
        messages: [{ role: "user", content: "ping" }],
        max_tokens: 1,
      }),
      this.name,
    );
  }
}

// --- Ollama Provider (local, OpenAI-compatible) ---

export class OllamaProvider implements LLMProvider {
  name = "ollama";
  private client: OpenAI;

  constructor(baseUrl?: string) {
    this.client = new OpenAI({
      apiKey: "ollama", // Ollama doesn't require a real key
      baseURL: baseUrl ?? "http://localhost:11434/v1",
    });
  }

  async send(modelId: string, request: LLMRequest): Promise<LLMResponse> {
    const start = Date.now();
    const timeoutMs = request.timeoutMs ?? DEFAULT_REQUEST_TIMEOUT_MS;
    const messages: OpenAI.ChatCompletionMessageParam[] = [];

    if (request.systemPrompt) {
      messages.push({ role: "system", content: request.systemPrompt });
    }
    messages.push({ role: "user", content: request.prompt });

    // Use a default local model name
    const localModel = modelId === "local-ollama" ? "llama3.2" : modelId;

    const response = await withTimeout(
      this.client.chat.completions.create({
        model: localModel,
        messages,
        max_tokens: request.maxTokens ?? 4096,
        temperature: request.temperature,
      }),
      timeoutMs,
      this.name,
    );

    const text = response.choices[0]?.message?.content ?? "";
    const inputTokens = response.usage?.prompt_tokens ?? 0;
    const outputTokens = response.usage?.completion_tokens ?? 0;

    return {
      text,
      modelId,
      provider: this.name,
      inputTokens,
      outputTokens,
      costUsd: 0, // Local models are free
      latencyMs: Date.now() - start,
    };
  }

  async healthCheck(): Promise<boolean> {
    try {
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), HEALTH_CHECK_TIMEOUT_MS);
      const response = await fetch("http://localhost:11434/api/tags", { signal: controller.signal });
      clearTimeout(timer);
      return response.ok;
    } catch {
      return false;
    }
  }
}

// --- Provider Registry ---

export function createProviders(): Record<string, LLMProvider> {
  return {
    anthropic: new AnthropicProvider(),
    google: new GoogleProvider(),
    minimax: new MiniMaxProvider(),
    ollama: new OllamaProvider(),
  };
}
