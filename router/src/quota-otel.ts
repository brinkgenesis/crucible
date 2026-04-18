/**
 * OTel metric emission for provider quota state.
 *
 * In the standalone @crucible/router package this is a no-op stub. Host
 * applications that want OTel export can register their own emitter via
 * setQuotaMetricEmitter.
 */

import type { ProviderQuotaState } from "./quota-tracker.js";

export type QuotaMetricEmitter = (
  provider: string,
  state: ProviderQuotaState,
) => void;

let emitter: QuotaMetricEmitter = () => {};

/** Register a custom OTel/Prometheus emitter at boot. */
export function setQuotaMetricEmitter(fn: QuotaMetricEmitter): void {
  emitter = fn;
}

/** Fire the registered emitter (called from QuotaTracker). */
export function emitQuotaMetricToOtel(
  provider: string,
  state: ProviderQuotaState,
): void {
  try {
    emitter(provider, state);
  } catch {
    // never let emitter errors crash the router
  }
}
