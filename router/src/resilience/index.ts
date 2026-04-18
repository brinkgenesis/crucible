/**
 * Resilience module — retry with exponential backoff + circuit breaker.
 *
 * Wraps async functions (primarily provider.send()) with:
 * - Exponential backoff + jitter for transient failures (429, 503, 502)
 * - Per-provider circuit breaker (closed → open → half-open)
 */

// --- Types ---

export interface RetryOptions {
  /** Max retry attempts (default: 3) */
  maxRetries: number;
  /** Base delay in ms (default: 500) */
  baseDelayMs: number;
  /** Max delay cap in ms (default: 30_000) */
  maxDelayMs: number;
  /** Jitter factor 0–1 (default: 0.3) */
  jitterFactor: number;
  /** HTTP status codes to retry on (default: [429, 502, 503, 504]) */
  retryableStatusCodes: number[];
  /** Error message substrings that are retryable */
  retryableErrors: string[];
}

export interface CircuitBreakerOptions {
  /** Failures before opening (default: 5) */
  failureThreshold: number;
  /** Ms to stay open before half-open probe (default: 60_000) */
  resetTimeoutMs: number;
  /** Successes in half-open to close (default: 2) */
  halfOpenSuccesses: number;
}

export type CircuitState = "closed" | "open" | "half-open";

export interface CircuitBreakerStats {
  state: CircuitState;
  failures: number;
  successes: number;
  lastFailureTime: number | null;
  lastStateChange: number;
}

// --- Default configs ---

export const DEFAULT_RETRY: RetryOptions = {
  maxRetries: 3,
  baseDelayMs: 500,
  maxDelayMs: 30_000,
  jitterFactor: 0.3,
  retryableStatusCodes: [429, 502, 503, 504],
  retryableErrors: [
    "ECONNRESET",
    "ETIMEDOUT",
    "ECONNREFUSED",
    "socket hang up",
    "network error",
    "fetch failed",
  ],
};

export const DEFAULT_CIRCUIT_BREAKER: CircuitBreakerOptions = {
  failureThreshold: 5,
  resetTimeoutMs: 60_000,
  halfOpenSuccesses: 2,
};

// --- Retry ---

/**
 * Compute delay with exponential backoff + jitter.
 */
export function computeDelay(attempt: number, opts: RetryOptions): number {
  const exponential = opts.baseDelayMs * Math.pow(2, attempt);
  const capped = Math.min(exponential, opts.maxDelayMs);
  const jitter = capped * opts.jitterFactor * (Math.random() * 2 - 1);
  return Math.max(0, capped + jitter);
}

/**
 * Check if an error is retryable based on status code or message.
 */
export function isRetryable(error: unknown, opts: RetryOptions): boolean {
  if (error instanceof Error) {
    // Check for HTTP status codes in error message (common patterns:
    // "HTTP 429", "status 503", "Error 502", "Request failed: 429",
    // "503 Service Unavailable", "Service Unavailable 503")
    const statusMatch = error.message.match(/\b(?:HTTP|status|Error|failed[:\s])\s*(\d{3})\b/i)
      ?? error.message.match(/\b(\d{3})\s+(?:Too Many|Service Unavailable|Bad Gateway|Gateway Timeout)\b/i)
      ?? error.message.match(/\b(?:Too Many Requests|Service Unavailable|Bad Gateway|Gateway Timeout|Unauthorized|Not Found)\s+(\d{3})\b/i);
    if (statusMatch) {
      const status = parseInt(statusMatch[1], 10);
      if (opts.retryableStatusCodes.includes(status)) return true;
    }
    // Check for retryable error substrings
    const msg = error.message.toLowerCase();
    return opts.retryableErrors.some((e) => msg.includes(e.toLowerCase()));
  }
  return false;
}

/**
 * Retry an async function with exponential backoff + jitter.
 */
export async function withRetry<T>(
  fn: () => Promise<T>,
  opts: Partial<RetryOptions> = {},
): Promise<T> {
  const config = { ...DEFAULT_RETRY, ...opts };
  let lastError: unknown;

  for (let attempt = 0; attempt <= config.maxRetries; attempt++) {
    try {
      return await fn();
    } catch (error) {
      lastError = error;
      if (attempt >= config.maxRetries || !isRetryable(error, config)) {
        throw error;
      }
      const delay = computeDelay(attempt, config);
      await new Promise((resolve) => setTimeout(resolve, delay));
    }
  }

  throw lastError; // unreachable but satisfies TS
}

// --- Circuit Breaker ---

export class CircuitBreaker {
  private state: CircuitState = "closed";
  private failures = 0;
  private halfOpenSuccesses = 0;
  private lastFailureTime: number | null = null;
  private lastStateChange: number = Date.now();
  private opts: CircuitBreakerOptions;

  constructor(
    public readonly name: string,
    opts: Partial<CircuitBreakerOptions> = {},
  ) {
    this.opts = { ...DEFAULT_CIRCUIT_BREAKER, ...opts };
  }

  /**
   * Execute a function through the circuit breaker.
   * Throws CircuitOpenError if the circuit is open.
   */
  async execute<T>(fn: () => Promise<T>): Promise<T> {
    if (this.state === "open") {
      // Check if reset timeout has elapsed → transition to half-open
      if (Date.now() - (this.lastFailureTime ?? 0) >= this.opts.resetTimeoutMs) {
        this.transitionTo("half-open");
      } else {
        throw new CircuitOpenError(this.name, this.stats());
      }
    }

    try {
      const result = await fn();
      this.onSuccess();
      return result;
    } catch (error) {
      this.onFailure();
      throw error;
    }
  }

  private onSuccess(): void {
    if (this.state === "half-open") {
      this.halfOpenSuccesses++;
      if (this.halfOpenSuccesses >= this.opts.halfOpenSuccesses) {
        this.transitionTo("closed");
      }
    } else {
      // In closed state, reset failure count on success
      this.failures = 0;
    }
  }

  private onFailure(): void {
    this.failures++;
    this.lastFailureTime = Date.now();

    if (this.state === "half-open") {
      // Any failure in half-open → back to open
      this.transitionTo("open");
    } else if (this.failures >= this.opts.failureThreshold) {
      this.transitionTo("open");
    }
  }

  private transitionTo(newState: CircuitState): void {
    this.state = newState;
    this.lastStateChange = Date.now();

    if (newState === "closed") {
      this.failures = 0;
      this.halfOpenSuccesses = 0;
    } else if (newState === "half-open") {
      this.halfOpenSuccesses = 0;
    }
  }

  /** Reset circuit to closed state (e.g., manual override). */
  reset(): void {
    this.transitionTo("closed");
    this.lastFailureTime = null;
  }

  stats(): CircuitBreakerStats {
    return {
      state: this.state,
      failures: this.failures,
      successes: this.halfOpenSuccesses,
      lastFailureTime: this.lastFailureTime,
      lastStateChange: this.lastStateChange,
    };
  }
}

export class CircuitOpenError extends Error {
  constructor(
    public readonly providerName: string,
    public readonly circuitStats: CircuitBreakerStats,
  ) {
    super(`Circuit breaker open for provider: ${providerName}`);
    this.name = "CircuitOpenError";
  }
}

// --- Combined: Retry + Circuit Breaker ---

/**
 * Wrap an async function with both circuit breaker and retry logic.
 * Circuit breaker is checked first, then retries happen within it.
 */
export async function withResilience<T>(
  fn: () => Promise<T>,
  breaker: CircuitBreaker,
  retryOpts: Partial<RetryOptions> = {},
): Promise<T> {
  return breaker.execute(() => withRetry(fn, retryOpts));
}
