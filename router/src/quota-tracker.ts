/**
 * Provider quota polling module.
 *
 * Periodically checks remaining usage for each configured provider,
 * tracks quota state (remaining capacity, reset windows), and emits
 * OTel metrics for Prometheus/Grafana alerting.
 */

import { emitQuotaMetricToOtel } from "./quota-otel.js";
import { extractErrorMessage } from "./utils/error.js";

// ─── Types ───────────────────────────────────────────────────────────────────

export type QuotaHealth = "healthy" | "warning" | "critical" | "exhausted" | "unknown";

export interface ProviderQuotaState {
  provider: string;
  /** Remaining requests in the current window, or null if unknown. */
  remainingRequests: number | null;
  /** Remaining tokens in the current window, or null if unknown. */
  remainingTokens: number | null;
  /** ISO timestamp when the current rate limit window resets. */
  resetAt: string | null;
  /** Seconds until rate-limit window resets. */
  resetInSeconds: number | null;
  /** Overall quota health for this provider. */
  health: QuotaHealth;
  /** When this state was last refreshed. */
  lastCheckedAt: string;
  /** Error message if the last poll failed. */
  lastError: string | null;
}

export interface QuotaSnapshot {
  providers: Record<string, ProviderQuotaState>;
  updatedAt: string;
}

// ─── Provider-specific adapters ──────────────────────────────────────────────

/**
 * Adapter that fetches quota/rate-limit headers from a provider.
 * Each returns partial state — unknown fields are null.
 */
type QuotaAdapter = () => Promise<Omit<ProviderQuotaState, "provider" | "lastCheckedAt" | "lastError">>;

async function pollAnthropic(): ReturnType<QuotaAdapter> {
  const key = process.env.ANTHROPIC_API_KEY;
  if (!key) return unknownState();

  const res = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "x-api-key": key,
      "anthropic-version": "2023-06-01",
      "content-type": "application/json",
    },
    body: JSON.stringify({
      model: "claude-haiku-4-5-20251001",
      max_tokens: 1,
      messages: [{ role: "user", content: "." }],
    }),
  });

  return parseRateLimitHeaders(res.headers, "anthropic");
}

async function pollGoogle(): ReturnType<QuotaAdapter> {
  const key = process.env.GOOGLE_API_KEY;
  if (!key) return unknownState();

  const url = `https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=${key}`;
  const res = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ contents: [{ parts: [{ text: "." }] }], generationConfig: { maxOutputTokens: 1 } }),
  });

  return parseRateLimitHeaders(res.headers, "google");
}

async function pollMinimax(): ReturnType<QuotaAdapter> {
  const key = process.env.MINIMAX_API_KEY;
  if (!key) return unknownState();

  const baseUrl = process.env.MINIMAX_BASE_URL ?? "https://api.minimax.io/v1";
  const res = await fetch(`${baseUrl}/chat/completions`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${key}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({
      model: process.env.MINIMAX_MODEL ?? "MiniMax-M2",
      messages: [{ role: "user", content: "." }],
      max_tokens: 1,
    }),
  });

  return parseRateLimitHeaders(res.headers, "minimax");
}

async function pollOllama(): ReturnType<QuotaAdapter> {
  try {
    const res = await fetch("http://localhost:11434/api/tags");
    return {
      remainingRequests: null,
      remainingTokens: null,
      resetAt: null,
      resetInSeconds: null,
      health: res.ok ? "healthy" : "critical",
    };
  } catch {
    return { ...unknownState(), health: "critical" };
  }
}

// ─── Header parsing ──────────────────────────────────────────────────────────

function parseRateLimitHeaders(
  headers: Headers,
  _provider: string,
): Omit<ProviderQuotaState, "provider" | "lastCheckedAt" | "lastError"> {
  // Standard rate-limit headers (Anthropic, OpenAI-compatible)
  const remaining = parseIntHeader(headers, "x-ratelimit-remaining-requests")
    ?? parseIntHeader(headers, "x-ratelimit-remaining");
  const remainingTokens = parseIntHeader(headers, "x-ratelimit-remaining-tokens");
  const resetHeader = headers.get("x-ratelimit-reset-requests")
    ?? headers.get("x-ratelimit-reset")
    ?? headers.get("retry-after");

  let resetAt: string | null = null;
  let resetInSeconds: number | null = null;

  if (resetHeader) {
    const asNumber = Number(resetHeader);
    if (!Number.isNaN(asNumber)) {
      resetInSeconds = asNumber;
      resetAt = new Date(Date.now() + asNumber * 1000).toISOString();
    } else {
      const d = new Date(resetHeader);
      if (!Number.isNaN(d.getTime())) {
        resetAt = d.toISOString();
        resetInSeconds = Math.max(0, Math.round((d.getTime() - Date.now()) / 1000));
      }
    }
  }

  return {
    remainingRequests: remaining,
    remainingTokens: remainingTokens,
    resetAt,
    resetInSeconds,
    health: computeHealth(remaining, remainingTokens),
  };
}

function parseIntHeader(headers: Headers, name: string): number | null {
  const raw = headers.get(name);
  if (!raw) return null;
  const n = parseInt(raw, 10);
  return Number.isNaN(n) ? null : n;
}

function computeHealth(
  remainingRequests: number | null,
  remainingTokens: number | null,
): QuotaHealth {
  if (remainingRequests === null && remainingTokens === null) return "unknown";
  if (remainingRequests === 0 || remainingTokens === 0) return "exhausted";
  if ((remainingRequests !== null && remainingRequests < 10)
    || (remainingTokens !== null && remainingTokens < 1000)) return "critical";
  if ((remainingRequests !== null && remainingRequests < 50)
    || (remainingTokens !== null && remainingTokens < 10_000)) return "warning";
  return "healthy";
}

function unknownState(): Omit<ProviderQuotaState, "provider" | "lastCheckedAt" | "lastError"> {
  return {
    remainingRequests: null,
    remainingTokens: null,
    resetAt: null,
    resetInSeconds: null,
    health: "unknown",
  };
}

// ─── Adapter registry ────────────────────────────────────────────────────────

const ADAPTERS: Record<string, QuotaAdapter> = {
  anthropic: pollAnthropic,
  google: pollGoogle,
  minimax: pollMinimax,
  ollama: pollOllama,
};

// ─── QuotaTracker class ──────────────────────────────────────────────────────

const DEFAULT_POLL_INTERVAL_MS = 60_000;
const POLL_TIMEOUT_MS = 15_000;

export class QuotaTracker {
  private state: Record<string, ProviderQuotaState> = {};
  private timer: NodeJS.Timeout | null = null;
  private pollIntervalMs: number;

  constructor(pollIntervalMs = DEFAULT_POLL_INTERVAL_MS) {
    this.pollIntervalMs = pollIntervalMs;
    for (const provider of Object.keys(ADAPTERS)) {
      this.state[provider] = {
        provider,
        remainingRequests: null,
        remainingTokens: null,
        resetAt: null,
        resetInSeconds: null,
        health: "unknown",
        lastCheckedAt: new Date().toISOString(),
        lastError: null,
      };
    }
  }

  /** Start periodic polling. Safe to call multiple times. */
  start(): void {
    if (this.timer) return;
    void this.pollAll();
    this.timer = setInterval(() => void this.pollAll(), this.pollIntervalMs);
    this.timer.unref();
  }

  stop(): void {
    if (this.timer) {
      clearInterval(this.timer);
      this.timer = null;
    }
  }

  /** Force an immediate poll of all providers. */
  async pollAll(): Promise<QuotaSnapshot> {
    const polls = Object.entries(ADAPTERS).map(([name, adapter]) =>
      this.pollOne(name, adapter),
    );
    await Promise.allSettled(polls);
    return this.snapshot();
  }

  /** Get the latest cached snapshot without triggering a poll. */
  snapshot(): QuotaSnapshot {
    return {
      providers: { ...this.state },
      updatedAt: new Date().toISOString(),
    };
  }

  /** Get quota state for a single provider. */
  getProviderQuota(provider: string): ProviderQuotaState | undefined {
    return this.state[provider];
  }

  /** Returns true if the provider is near/at exhaustion. */
  isProviderExhausted(provider: string): boolean {
    const q = this.state[provider];
    if (!q) return false;
    return q.health === "exhausted" || q.health === "critical";
  }

  private async pollOne(name: string, adapter: QuotaAdapter): Promise<void> {
    const now = new Date().toISOString();
    try {
      const controller = new AbortController();
      const timeout = setTimeout(() => controller.abort(), POLL_TIMEOUT_MS);
      const result = await Promise.race([
        adapter(),
        new Promise<never>((_, reject) => {
          controller.signal.addEventListener("abort", () =>
            reject(new Error("Quota poll timeout")),
          );
        }),
      ]);
      clearTimeout(timeout);

      this.state[name] = { ...result, provider: name, lastCheckedAt: now, lastError: null };
    } catch (err) {
      this.state[name] = {
        ...this.state[name],
        lastCheckedAt: now,
        lastError: extractErrorMessage(err),
      };
    }

    emitQuotaMetricToOtel(name, this.state[name]);
  }
}

/** OTel-friendly metrics from the current quota state. */
export interface QuotaMetrics {
  provider: string;
  /** Gauge: remaining requests, -1 if unknown */
  remaining: number;
  /** Gauge: 0=exhausted, 1=critical, 2=warning, 3=healthy, -1=unknown */
  healthScore: number;
  /** Gauge: seconds until rate-limit window resets, -1 if unknown */
  resetSeconds: number;
}

const HEALTH_SCORE: Record<QuotaHealth, number> = {
  exhausted: 0,
  critical: 1,
  warning: 2,
  healthy: 3,
  unknown: -1,
};

/** Get OTel-ready metrics for all providers from a QuotaTracker instance. */
export function getQuotaMetrics(tracker: QuotaTracker): QuotaMetrics[] {
  const snap = tracker.snapshot();
  return Object.values(snap.providers).map((p) => ({
    provider: p.provider,
    remaining: p.remainingRequests ?? -1,
    healthScore: HEALTH_SCORE[p.health] ?? -1,
    resetSeconds: p.resetInSeconds ?? -1,
  }));
}
